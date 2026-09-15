"""Audit repeated Go comparisons, including upload queues and GET failure accounting."""

import argparse
import collections
import hashlib
import json
from pathlib import Path
import statistics
import zlib

from overload import cpu_list
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
    parser.add_argument('--plan', type=Path, action='append', required=True)
    args = parser.parse_args()
    folder = args.folder.resolve()
    receipts = {}
    for path in (ROOT / 'docs/nginx-implementation').glob('*/build.json'):
        receipt = read(path)
        for binary, expected in receipt.get('binaries', {}).items():
            receipts[str((ROOT / binary).resolve())] = (expected, str(path.relative_to(ROOT)))
    for row in read(ROOT / 'docs/go-after-nginx/build.json')['builds']:
        receipts[row['binary']] = (row['binary_sha256'], 'docs/go-after-nginx/build.json')
    legacy_client = read(ROOT / 'docs/go-after-nginx/build.json')['client']
    clients = {legacy_client['path']: (legacy_client['sha256'], {})}
    for client_build in (ROOT / 'docs/go-performance-followup').glob('*/client-build.json'):
        receipt = read(client_build)
        if not receipt.get('build_settings_match_original', False):
            continue
        assert receipt['build_exit'] == receipt['test_exit'] == 0
        assert digest(client_build.parent / 'source.tar.gz') == receipt['source_archive_sha256']
        clients[receipt['binary']] = (receipt['binary_sha256'], receipt['sources'])
    harness_sources = collections.defaultdict(set)
    for harness in folder.glob('harness-*/sources.json'):
        for source, checksum in read(harness).items():
            assert digest(harness.parent / source) == checksum
            harness_sources[source].add(checksum)
    expected_failures = {}
    rows, failures, get_rows, get_checked = [], [], [], []
    for path in sorted(folder.glob('*/*/run.json')):
        relative = str(path.relative_to(folder))
        run = read(path)
        if run['outcome'] != 'measured':
            assert expected_failures[relative] in run['error'], relative
            failures.append(dict(path=relative, error=run['error'], server_exit=run['server_exit']))
            continue
        group = path.parent.parent
        if 'body_bytes' not in run:
            assert run['variant'] in ('go', 'zig', 'before')
            command = run['command']
            binary = command[3] if command[0] == 'taskset' else command[0]
            expected, receipt = receipts[binary]
            assert digest(Path(binary)) == expected == run['binary_sha256'] == run['running_binary_sha256']
            assert run['remote_identity']['boot_id'] != run['server_identity']['boot_id']
            expected_client_cpus = sorted(cpu_list(run['options'].get('client_cpus', '0-7')))
            assert run['remote_started']['cpus'] == expected_client_cpus
            local_client = str(Path(run['options'].get('local_client_binary', legacy_client['path'])).resolve())
            client_checksum, client_sources = clients[local_client]
            assert run['remote_started']['binary_sha256'] == digest(Path(local_client)) == client_checksum
            assert run['server_exit'] == (-15 if run['variant'] == 'go' else 0)
            if run['variant'] == 'go':
                assert run['go_runtime']['gomaxprocs'] == 32
            manifest = read(group / 'manifest.json')
            assert str(path) in manifest['runs']
            zig_binary = str(Path(run['options']['zig_binary']).resolve())
            zig_receipt = read(ROOT / receipts[zig_binary][1])
            for source, checksum in manifest['sources'].items():
                if source.startswith('src/'):
                    assert zig_receipt['sources'][source] == checksum, source
                else:
                    assert (checksum == zig_receipt['sources'].get(source) or
                            checksum == client_sources.get(source) or
                            checksum in harness_sources[source] or digest(ROOT / source) == checksum), source
            load = run['load']
            derived = summarize(path)
            (path.parent / 'summary.json').write_text(json.dumps(derived, indent=2) + '\n')
            if 'phases' not in load:
                count = run['options']['connections']
                assert load['attempts'] == load['successes'] + load['errors']
                assert sum((load['failures'] or {}).values()) == load['errors']
                assert load['window_successes_per_second'] == load['window_successes'] / load['measurement_seconds']
                assert load['connections_ready'] + load['setup_errors'] == count
                assert load['connections_measured'] == load['connections_ready'] == count
                get_rows.append(dict(group=group.name, path=relative, variant=run['variant'],
                                     connections=count, rate=0, goodput=load['window_successes_per_second'],
                                     p50_ms=load['latency_us']['p50'] / 1000,
                                     p99_ms=load['latency_us']['p99'] / 1000,
                                     rss_end_mib=derived['rss_mib'],
                                     process_cpu_seconds_including_setup_warmup_drain=derived['process_cpu_seconds'],
                                     failures=load['errors'], failure_types=load['failures'],
                                     window_failures=load['window_failures'],
                                     warmup_errors=load['warmup_errors'], setup_errors=load['setup_errors']))
                get_rows[-1]['rss_peak_mib'] = max(
                    [run['server_before']['VmHWM'], run['server_after']['VmHWM']] +
                    [sample['server']['VmHWM'] for sample in run['samples']]) / 2**20
                if 'measurement_start_unix_ns' in load:
                    assert load['measurement_end_unix_ns'] - load['measurement_start_unix_ns'] == round(load['measurement_seconds'] * 1e9)
                    start = load['measurement_start_unix_ns'] + run['clock_offset_ns']
                    end = load['measurement_end_unix_ns'] + run['clock_offset_ns']
                    samples = [sample for sample in run['samples']
                               if start + 500000000 <= sample['unix_ns'] < end - 200000000]
                    assert len(samples) >= 3
                    first, last = samples[0], samples[-1]
                    seconds = (last['unix_ns'] - first['unix_ns']) / 1e9
                    assert seconds >= load['measurement_seconds'] * .6
                    cpu_rate = (last['server']['cpu_seconds'] - first['server']['cpu_seconds']) / seconds
                    get_rows[-1].update(
                        rss_mib=statistics.median(sample['server']['VmRSS'] for sample in samples) / 2**20,
                        cpu_us=cpu_rate * 1e6 / load['window_successes_per_second'],
                        cpu_interval_seconds=seconds,
                        cpu_interval_start_unix_ns=first['unix_ns'],
                        cpu_interval_end_unix_ns=last['unix_ns'])
                get_checked.append(relative)
                continue
            assert load['gomaxprocs'] == len(expected_client_cpus)
            for phase_index, (phase, result) in enumerate(zip(load['phases'], derived['phases'], strict=True)):
                failed = phase['failure_latency']['count'] + phase['rejection_latency']['count']
                assert failed == sum((phase['failures'] or {}).values())
                assert phase['offered'] == phase['successes'] + failed + phase['generator_expired'] + phase['generator_queue_drops']
                assert phase['response_bytes_validated'] == phase['successes'] * 6
                if phase_index == 0 and len(load['phases']) > 1:
                    continue
                start = phase['start_unix_ns'] + run['clock_offset_ns']
                end = phase['end_unix_ns'] + run['clock_offset_ns']
                samples = [sample for sample in run['samples'] if start + 500000000 <= sample['unix_ns'] < end - 200000000]
                get_rows.append(dict(group=group.name, path=relative, variant=run['variant'],
                                     connections=run['options']['connections'], rate=phase['offered_rate'],
                                     goodput=result['goodput'], p99_ms=result['service_p99_us'] / 1000,
                                     p50_ms=phase['success_service_latency']['p50_us'] / 1000,
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
    planned = set()
    for plan in args.plan:
        for item in read(plan):
            command = item['command']
            repeats = int(command[command.index('--repeats') + 1])
            sizes = 1
            body_sizes = []
            if '--body-bytes' in command:
                sizes = 0
                for argument in command[command.index('--body-bytes') + 1:]:
                    if argument.startswith('--'):
                        break
                    sizes += 1
                    body_sizes.append(int(argument))
            paths = list((folder / item['label']).glob('*/run.json'))
            variants = []
            if '--variants' in command:
                for argument in command[command.index('--variants') + 1:]:
                    if argument.startswith('--'):
                        break
                    variants.append(argument)
                assert variants and len(set(variants)) == len(variants), item['label']
            elif body_sizes:
                variants = ['streaming']
                if '--before' in command:
                    variants.append(command[command.index('--before-label') + 1]
                                    if '--before-label' in command else 'buffered')
                if '--go-binary' in command:
                    variants.append('go')
                assert len(variants) >= 2 and len(set(variants)) == len(variants), item['label']
            assert len(paths) == repeats * (len(variants) if variants else 2) * sizes, (
                item['label'], len(paths))
            if body_sizes:
                expected_paths = {f'n{size}-{variant}-{repeat}'
                                  for size in body_sizes for variant in variants
                                  for repeat in range(1, repeats + 1)}
                assert {path.parent.name for path in paths} == expected_paths, item['label']
                for path in paths:
                    run = read(path)
                    repeat = int(path.parent.name.rsplit('-', 1)[1])
                    assert path.parent.name == f"n{run['body_bytes']}-{run['variant']}-{repeat}"
                    assert run.get('repeat', repeat) == repeat
            elif variants:
                actual = collections.Counter((run['variant'], run['repeat'])
                                             for run in map(read, paths))
                expected = collections.Counter((variant, repeat)
                                               for variant in variants
                                               for repeat in range(1, repeats + 1))
                assert actual == expected, (item['label'], actual, expected)
            planned.update(str(path.relative_to(folder)) for path in paths)
    assert planned == {row['path'] for row in rows} | set(get_checked)
    get_groups = collections.defaultdict(list)
    for row in get_rows:
        get_groups[(row['group'], row['variant'], row['rate'])].append(row)
    get_aggregate = []
    for (group, variant, rate), trials in get_groups.items():
        fields = [key for key in ('goodput', 'p50_ms', 'p99_ms', 'rss_mib', 'cpu_us', 'rss_end_mib', 'rss_peak_mib')
                  if key in trials[0]]
        get_aggregate.append(dict(group=group, variant=variant, rate=rate, repeats=len(trials),
                                  medians={key: statistics.median(t[key] for t in trials) for key in fields},
                                  trials={key: [t[key] for t in trials] for key in fields},
                                  failures=sum(t['failures'] for t in trials),
                                  generator_drops=sum(t.get('generator_drops', 0) for t in trials),
                                  setup_errors=sum(t.get('setup_errors', 0) for t in trials),
                                  warmup_errors=sum(t.get('warmup_errors', 0) for t in trials)))
    (folder / 'get-aggregate.json').write_text(json.dumps(get_aggregate, indent=2) + '\n')
    (folder / 'get-trials.json').write_text(json.dumps(get_rows, indent=2) + '\n')
    (folder / 'trials.json').write_text(json.dumps(rows, indent=2) + '\n')
    (folder / 'aggregate.json').write_text(json.dumps(aggregate, indent=2) + '\n')
    (folder / 'audit.json').write_text(json.dumps(dict(
        outcome='passed', measured_runs=len(rows), get_control_runs=len(get_checked), failed_excluded=failures,
        checked=[r['path'] for r in rows] + get_checked, final_build=str(args.final_build) if args.final_build else None,
    ), indent=2) + '\n')
    print(f'Audited {len(rows)} upload runs and {len(get_checked)} GET runs.')
    for row in get_aggregate:
        print(row['group'], row['variant'], row['rate'], row['medians'], 'failures', row['failures'])
    for row in aggregate:
        print(row['group'], row['variant'], row['body_bytes'], row['repeats'], row['medians'])


if __name__ == '__main__':
    main()
