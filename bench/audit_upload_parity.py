"""Audit upload experiment provenance, queue controls, and request accounting."""

import argparse
import collections
import hashlib
import json
from pathlib import Path
import statistics
import zlib

from summarize_architecture import host_delta, summarize


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--final-build', type=Path)
    args = parser.parse_args()
    folder = args.folder.resolve()
    receipts = {}
    for path in (ROOT / 'docs/nginx-implementation').glob('*/build.json'):
        receipt = read(path)
        for binary, expected in receipt.get('binaries', {}).items():
            receipts[str((ROOT / binary).resolve())] = (expected, str(path.relative_to(ROOT)))
    for row in read(ROOT / 'docs/go-after-nginx/build.json')['builds']:
        receipts[row['binary']] = (row['binary_sha256'], 'docs/go-after-nginx/build.json')
    expected_failures = {
        'assigned-saturated/n65536-streaming-1/run.json': 'AssertionError()',
        'body-read-pairs/n65536-before-1/run.json': 'could not prepare a confirmed client queue bucket',
    }
    rows, failures, get_rows, get_checked = [], [], [], []
    for path in sorted(folder.glob('*/*/run.json')):
        relative = str(path.relative_to(folder))
        run = read(path)
        if run['outcome'] != 'measured':
            assert expected_failures[relative] in run['error'], relative
            failures.append(dict(path=relative, error=run['error'], server_exit=run['server_exit']))
            continue
        group = path.parent.parent
        if group.name.startswith('final-get-'):
            assert run['variant'] in ('go', 'zig')
            binary = run['command'][0]
            expected, receipt = receipts[binary]
            assert digest(Path(binary)) == expected == run['binary_sha256'] == run['running_binary_sha256']
            assert run['remote_identity']['boot_id'] != run['server_identity']['boot_id']
            assert run['remote_started']['cpus'] == list(range(8))
            assert run['remote_started']['binary_sha256'] == digest(ROOT / 'zig-out/bench/load')
            assert run['server_exit'] == (-15 if run['variant'] == 'go' else 0)
            if run['variant'] == 'go':
                assert run['go_runtime']['gomaxprocs'] == 32
            else:
                assert run['metrics_after']['counters']['connections_reclaimed_total'] == 0
            manifest = read(group / 'manifest.json')
            assert str(path) in manifest['runs']
            for source, checksum in manifest['sources'].items():
                assert digest(ROOT / source) == checksum, source
            load = run['load']
            assert load['gomaxprocs'] == 8
            derived = summarize(path)
            (path.parent / 'summary.json').write_text(json.dumps(derived, indent=2) + '\n')
            for phase, result in zip(load['phases'], derived['phases'], strict=True):
                failed = phase['failure_latency']['count'] + phase['rejection_latency']['count']
                assert failed == sum((phase['failures'] or {}).values())
                assert phase['offered'] == phase['successes'] + failed + phase['generator_expired'] + phase['generator_queue_drops']
                assert phase['response_bytes_validated'] == phase['successes'] * 6
                if phase['offered_rate'] < 100000:
                    continue
                start = phase['start_unix_ns'] + run['clock_offset_ns']
                end = phase['end_unix_ns'] + run['clock_offset_ns']
                samples = [sample for sample in run['samples'] if start + 500000000 <= sample['unix_ns'] < end - 200000000]
                get_rows.append(dict(group=group.name, path=relative, variant=run['variant'],
                                     connections=run['options']['connections'], rate=phase['offered_rate'],
                                     goodput=result['goodput'], p99_ms=result['service_p99_us'] / 1000,
                                     cpu_us=result['cpu_us_per_success_estimate'],
                                     rss_mib=statistics.median(sample['server']['VmRSS'] / 2**20 for sample in samples),
                                     failures=failed, failure_types=phase['failures'],
                                     generator_drops=result['generator_drops']))
            get_checked.append(relative)
            continue
        variants = read(group / 'variants.json')
        binary = variants['binaries'][run['variant']]
        expected, receipt = receipts[binary]
        assert digest(Path(binary)) == expected == variants['sha256'][run['variant']]
        assert run['running_binary_sha256'] == run['binary_sha256'] == expected
        assert digest(group / 'upload_client.py') == variants['client_source_sha256']
        command = run['remote_started']['command']
        assert command[command.index('-c') + 1] == (group / 'upload_client.py').read_text()
        assert run['remote_identity']['boot_id'] != run['server_identity']['boot_id']
        assert run['remote_started']['cpus'] == list(range(8))
        if run['variant'] == 'go':
            assert run['go_runtime']['gomaxprocs'] == 32
            assert run['server_exit'] == -15
        else:
            assert run['server_exit'] == 0
        load = run['load']
        size = run['body_bytes']
        body = (group / f'body-{size}.bin').read_bytes()
        response = f'{len(body)}:{zlib.crc32(body):08x}\n'.encode()
        assert len(body) == size == load['request_body_bytes']
        assert hashlib.sha256(body).hexdigest() == load['request_body_sha256']
        assert hashlib.sha256(response).hexdigest() == load['expected_body_sha256']
        for flag, content in (('-request-body', body), ('-expect-body', response)):
            assert run['remote_started']['files'][flag] == dict(
                bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
        assert not load['failures']
        assert len(load['workers']) == load['connections'] == run['connections']
        latencies = sorted(value for worker in load['workers'] for value in worker['latencies_ns'])
        assert len(latencies) == load['window_successes'] > 0
        assert load['validated_body_bytes'] == len(latencies) * size
        assert load['goodput_bytes_per_second'] == len(latencies) * size / load['duration_seconds']
        assert all(w['attempts'] == w['successes'] and not w['failures'] for w in load['workers'])
        assert load['service_p99_ms'] == latencies[min(len(latencies) - 1, int(.99 * len(latencies)))] / 1e6
        if load.get('unique_queues'):
            assert len({w['queue_bucket'] for w in load['workers']}) == load['connections']
        for worker in load['workers']:
            if load.get('freeze_hash') or load.get('unique_queues'):
                if 'tx_rehash' in worker:
                    assert worker['tx_rehash'] == 0
            if load.get('calibrate_body'):
                assert worker['calibration_bytes'] == 8388608
            if 'queue_bucket' in worker:
                assert worker['queue_bucket'] == worker['queue_probes'][-1]['bucket']
                weights = worker['queue_probes'][-1]['weights']
                assert weights[worker['queue_bucket']] >= sum(weights.values()) * .9
        summary = read(path.parent / 'summary.json')
        start = load['measure_start_unix_ns'] + run['clock_offset_ns']
        end = load['measure_end_unix_ns'] + run['clock_offset_ns']
        samples = [s for s in run['samples'] if start + 250_000_000 <= s['unix_ns'] < end - 250_000_000]
        first, last = samples[0], samples[-1]
        seconds = (last['unix_ns'] - first['unix_ns']) / 1e9
        cpu = (last['server']['cpu_seconds'] - first['server']['cpu_seconds']) / seconds
        goodput = load['goodput_bytes_per_second'] / 2**20
        rss = statistics.median(s['server']['VmRSS'] / 2**20 for s in samples)
        assert summary['cpu_cores'] == cpu
        assert summary['cpu_us_per_mib'] == cpu / goodput * 1e6
        assert summary['rss_median_mib'] == rss
        client_delta = host_delta(run['remote_samples'][0]['host'], run['remote_samples'][-1]['host'])
        rows.append(dict(group=group.name, path=relative, variant=run['variant'], body_bytes=size,
                         receipt=receipt, connections=load['connections'], rate=load['rate_cap'],
                         profiled='profile_command' in run, unique_queues=load.get('unique_queues', False),
                         freeze_hash=load.get('freeze_hash', False), calibrate_body=load.get('calibrate_body', False),
                         goodput_mib_per_second=goodput, p50_ms=statistics.median(latencies) / 1e6,
                         p99_ms=load['service_p99_ms'], rss_mib=rss, cpu_us_per_mib=cpu / goodput * 1e6,
                         client_retransmissions=client_delta['tcp']['RetransSegs'],
                         successes=load['window_successes'],
                         minor_faults=last['server']['minor_faults'] - first['server']['minor_faults'],
                         buffer_allocations=(last['metrics']['counters']['buffer_allocations_total'] -
                                             first['metrics']['counters']['buffer_allocations_total'])
                         if first.get('metrics') else None,
                         user_cpu_us_per_mib=(last['server']['user_seconds'] - first['server']['user_seconds']) / seconds / goodput * 1e6,
                         system_cpu_us_per_mib=(last['server']['system_seconds'] - first['server']['system_seconds']) / seconds / goodput * 1e6))
    groups = collections.defaultdict(list)
    for row in rows:
        groups[(row['group'], row['variant'], row['body_bytes'])].append(row)
    aggregate = []
    for (group, variant, size), trials in groups.items():
        fields = ('goodput_mib_per_second', 'p50_ms', 'p99_ms', 'rss_mib', 'cpu_us_per_mib')
        aggregate.append(dict(group=group, variant=variant, body_bytes=size, repeats=len(trials),
                              medians={k: statistics.median(t[k] for t in trials) for k in fields},
                              trials={k: [t[k] for t in trials] for k in fields}))
    if args.final_build:
        final = read(args.final_build)
        for path, expected in final['sources'].items():
            if path.startswith(('src/', 'tests/')) or path in ('build.zig', 'bench/upload.zig', 'bench/Crc32.zig'):
                assert digest(ROOT / path) == expected, path
    if args.final_build and (folder / 'final-plan.json').exists():
        for item in read(folder / 'final-plan.json'):
            command = item['command']
            repeats = int(command[command.index('--repeats') + 1])
            assert len(list((folder / item['label']).glob('*/run.json'))) == repeats * 2, item['label']
    (folder / 'get-controls.json').write_text(json.dumps(get_rows, indent=2) + '\n')
    (folder / 'trials.json').write_text(json.dumps(rows, indent=2) + '\n')
    (folder / 'aggregate.json').write_text(json.dumps(aggregate, indent=2) + '\n')
    (folder / 'audit.json').write_text(json.dumps(dict(
        outcome='passed', measured_runs=len(rows), get_control_runs=len(get_checked), failed_excluded=failures,
        checked=[r['path'] for r in rows] + get_checked, final_build=str(args.final_build) if args.final_build else None,
    ), indent=2) + '\n')
    print(f'Audited {len(rows)} measured runs; {len(failures)} failed setup runs retained separately.')
    for row in aggregate:
        print(row['group'], row['variant'], row['body_bytes'], row['repeats'], row['medians'])


if __name__ == '__main__':
    main()
