"""Audit and summarize the Go comparison after the retained architecture changes."""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import zlib

from summarize_architecture import summarize


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    folder = args.folder.resolve()
    receipt = read(folder / 'build.json')
    binaries = {row['binary']: row['binary_sha256'] for row in receipt['builds']}
    binaries.update({receipt[key]['path']: receipt[key]['sha256'] for key in ('zhtps', 'zhtps_upload')})
    for path, expected in binaries.items():
        assert digest(Path(path)) == expected, path
    assert digest(Path(receipt['client']['path'])) == receipt['client']['sha256']
    for row in receipt['builds']:
        assert digest(ROOT / row['source']) == row['source_sha256']
    plan = read(folder / 'plan.json')
    for path, expected in plan['source_sha256'].items():
        assert digest(ROOT / path) == digest(folder / 'sources' / path) == expected, path
    zhtps_receipt = read(ROOT / 'docs/nginx-implementation/final/build.json')
    for path, expected in zhtps_receipt['sources'].items():
        if path.startswith('src/') or path in ('build.zig', 'bench/upload.zig'):
            assert digest(ROOT / path) == expected, path

    rows, checked = [], []
    for item in plan['runs']:
        group = item['label']
        files = sorted((folder / group).glob('*/run.json'))
        assert len(files) == (12 if group == 'uploads' else 6), (group, len(files))
        for path in files:
            run = read(path)
            assert run['outcome'] == 'measured', path
            assert run['binary_sha256'] == run['running_binary_sha256'] == binaries[run['command'][0]], path
            assert run['server_identity']['boot_id'] != run['remote_identity']['boot_id']
            assert run['remote_started']['cpus'] == list(range(8))
            if run['variant'] == 'go':
                assert run['go_runtime']['gomaxprocs'] == 32
                assert run['server_exit'] == -15
            else:
                assert run['server_exit'] == 0
            load = run['load']
            base = dict(group=group, trial=path.parent.name, path=str(path.relative_to(folder)), variant=run['variant'])
            if group.startswith('uploads'):
                size = run['body_bytes']
                body = (folder / group / f'body-{size}.bin').read_bytes()
                expected = f'{len(body)}:{zlib.crc32(body):08x}\n'.encode()
                assert len(body) == size == load['request_body_bytes']
                assert load['request_body_sha256'] == hashlib.sha256(body).hexdigest()
                assert load['expected_body_sha256'] == hashlib.sha256(expected).hexdigest()
                assert not load['failures']
                assert len(load['workers']) == load['connections'] == run['connections'] == 32
                assert all(w['successes'] == w['attempts'] and not w['failures'] for w in load['workers'])
                assert sum(len(w['latencies_ns']) for w in load['workers']) == load['window_successes'] > 0
                assert load['validated_body_bytes'] == load['window_successes'] * size
                assert load['goodput_bytes_per_second'] == load['validated_body_bytes'] / 20
                for flag, content in (('-request-body', body), ('-expect-body', expected)):
                    assert run['remote_started']['files'][flag] == dict(bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
                result = read(path.parent / 'summary.json')
                rows.append(dict(base, body_bytes=size, goodput=result['goodput_mib_per_second'],
                                 p99_ms=result['service_p99_ms'], rss_mib=result['rss_median_mib'],
                                 cpu_us_per_mib=result['cpu_us_per_mib'], cpu_cores=result['cpu_cores'],
                                 failures=0, retrans_server=result['server_host']['tcp']['RetransSegs']))
            else:
                assert run['remote_started']['binary_sha256'] == receipt['client']['sha256']
                count = run['options']['connections']
                if run['variant'] == 'zig':
                    assert run['metrics_after']['counters']['connections_reclaimed_total'] == 0
                result = summarize(path)
                (path.parent / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
                if group.startswith('rates'):
                    assert load['gomaxprocs'] == 8
                    for phase, result_phase in zip(load['phases'], result['phases'], strict=True):
                        failures = phase['failure_latency']['count'] + phase['rejection_latency']['count']
                        assert failures == sum((phase['failures'] or {}).values())
                        assert phase['offered'] == phase['successes'] + failures + phase['generator_expired'] + phase['generator_queue_drops']
                        assert phase['response_bytes_validated'] == phase['successes'] * 6
                        if phase['offered_rate'] < 100000:
                            continue
                        start = phase['start_unix_ns'] + run['clock_offset_ns']
                        end = phase['end_unix_ns'] + run['clock_offset_ns']
                        samples = [s for s in run['samples'] if start + 500_000_000 <= s['unix_ns'] < end - 200_000_000]
                        rows.append(dict(base, connections=count, rate=phase['offered_rate'],
                                         goodput=result_phase['goodput'], p99_ms=result_phase['service_p99_us'] / 1000,
                                         rss_mib=statistics.median(s['server']['VmRSS'] / 2**20 for s in samples),
                                         cpu_us=result_phase['cpu_us_per_success_estimate'],
                                         cpu_cores=result_phase['process_cpu_cores'], failures=failures,
                                         failure_types=phase['failures'], generator_drops=result_phase['generator_drops'],
                                         retrans_server=result_phase['server_host']['tcp']['RetransSegs'],
                                         retrans_client=result_phase.get('client_host', {}).get('tcp', {}).get('RetransSegs')))
                else:
                    assert load['attempts'] == load['successes'] + load['errors']
                    assert sum((load['failures'] or {}).values()) == load['errors']
                    assert load['window_successes_per_second'] == load['window_successes'] / 10
                    assert load['connections_ready'] + load['setup_errors'] == count
                    assert load['connections_measured'] == load['connections_ready'] == count
                    rows.append(dict(base, connections=count, goodput=load['window_successes_per_second'],
                                     p99_ms=load['latency_us']['p99'] / 1000,
                                     failures=load['errors'], warmup_errors=load['warmup_errors'], setup_errors=load['setup_errors'],
                                     failure_types=load['failures'], connections_measured=load['connections_measured'],
                                     connections_opened=load['connections_opened'],
                                     retrans_server=result['server_network']['tcp']['RetransSegs']))
            checked.append(str(path.relative_to(folder)))

    aggregate = []
    groups = sorted({(row['group'], row['variant'], row.get('rate', 0), row.get('body_bytes', 0)) for row in rows})
    for group, variant, rate, size in groups:
        trials = [row for row in rows if (row['group'], row['variant'], row.get('rate', 0), row.get('body_bytes', 0)) == (group, variant, rate, size)]
        assert len(trials) == 3
        fields = ('goodput', 'p99_ms', 'rss_mib', 'cpu_us', 'cpu_us_per_mib', 'cpu_cores')
        aggregate.append(dict(group=group, variant=variant, rate=rate, body_bytes=size,
                              medians={key: statistics.median(row[key] for row in trials) for key in fields if key in trials[0]},
                              trials={key: [row[key] for row in trials] for key in fields if key in trials[0]},
                              failures=sum(row['failures'] for row in trials),
                              warmup_errors=sum(row.get('warmup_errors', 0) for row in trials),
                              setup_errors=sum(row.get('setup_errors', 0) for row in trials),
                              retrans_server=[row['retrans_server'] for row in trials]))
    checksum = read(folder / 'checksum/results.json')
    for path, expected in checksum['sources'].items():
        assert digest(ROOT / path) == expected, path
    for variant, expected in checksum['binaries'].items():
        assert digest(ROOT / f'zig-out/go-after-nginx/checksum-{variant}') == expected
    body = bytearray(bytes(range(256)) * (8 * 1024 * 1024 // 256))
    warm_checksum = zlib.crc32(body)
    checksum_sum = 0
    for _ in range(64):
        body[0] = (body[0] + 1) % 256
        checksum_sum += zlib.crc32(body)
    assert len(checksum['trials']) == 6
    for trial in checksum['trials']:
        assert trial['bytes'] == len(body) and trial['iterations'] == 64
        assert trial['chunk_bytes'] == 65536
        assert trial['warm_checksum'] == warm_checksum
        assert trial['checksum_sum'] == checksum_sum
        assert trial['cpu_us_per_mib'] == trial['cpu_ns'] / 1000 / 512
    for variant in ('zig', 'go'):
        costs = [t['cpu_us_per_mib'] for t in checksum['trials'] if t['variant'] == variant]
        assert len(costs) == 3
        assert checksum['medians'][variant] == statistics.median(costs)
    (folder / 'trials.json').write_text(json.dumps(rows, indent=2) + '\n')
    (folder / 'aggregate.json').write_text(json.dumps(aggregate, indent=2) + '\n')
    (folder / 'audit.json').write_text(json.dumps(dict(outcome='passed', runs=len(checked), checked=checked,
                                                      production_source_unchanged=True, go_gomaxprocs=32,
                                                      offered_client_gomaxprocs=8, checksum_trials=6,
                                                      all_closed_loop_connections_participated=True,
                                                      get_idle_connections_reclaimed=0,
                                                      excluded=['upload-smoke']), indent=2) + '\n')
    print('Audited', len(checked), 'two-host trials and six checksum-only trials.')
    for row in aggregate:
        print(row['group'], row['variant'], row['rate'], row['body_bytes'], row['medians'], 'failures', row['failures'])


if __name__ == '__main__':
    main()
