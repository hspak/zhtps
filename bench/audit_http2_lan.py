"""Independently audit LAN trials against every retained client failure record."""

from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import sys


PHASES = ('setup', 'holding', 'warmup', 'measurement')


def percentile(histogram, percent):
    total = sum(histogram.values())
    if not total:
        return None
    target = (total - 1) * percent // 100 + 1
    cumulative = 0
    for boundary in sorted(histogram):
        cumulative += histogram[boundary]
        if cumulative >= target:
            return boundary / 1000
    raise AssertionError('missing percentile')


def audit(folder):
    folder = Path(folder)
    report = json.loads((folder / 'results.json').read_text())
    assert report['complete'], 'incomplete benchmark'
    args = report['arguments']
    variants = report.get('variants')
    servers = list(variants) if variants else args['servers'].split(',')
    expected = set()
    skipped = set()
    for workers in map(int, args['workers'].split(',')):
        for connections in map(int, args['connections'].split(',')):
            if variants and connections > workers * 8176:
                skipped.add((workers, connections))
                continue
            for server in servers:
                if not variants and workers > 1 and server in ('node', 'bun'):
                    continue
                for repeat in range(args['repeats']):
                    expected.add((workers, connections, server, repeat))
    if variants:
        assert skipped == {(row['workers'], row['connections']) for row in report['skipped']}
    actual = [(r['workers'], r['connections'], r.get('variant', r['server']), r['repeat']) for r in report['runs']]
    assert len(actual) == len(set(actual)) and set(actual) == expected
    failures = {phase: Counter() for phase in PHASES}
    successes = 0
    for run in report['runs']:
        assert run['valid'], run.get('error')
        workers, connections, server, repeat = (run[k] for k in
                                               ('workers', 'connections', 'server', 'repeat'))
        label = run.get('variant', server)
        path = folder / f'w{workers}-c{connections}-{label}-r{repeat + 1}'
        assert json.loads((path / 'run.json').read_text()) == run
        same_host = run['client_identity']['boot_id'] == run['server_identity']['boot_id']
        assert same_host == (args.get('location') == 'loopback')
        if variants:
            assert run['server_binary_sha256'] == report['binary_sha256'][label]
            assert run['server_command'][3] == variants[label]
        assert run['server_identity']['boot_id'] == report['server_identity']['boot_id']
        assert run['client_launch']['binary_sha256'] == report['binary_sha256']['client']
        assert run['streams'] == args['streams']
        cpus = set(run['server_cpus'])
        cores = {tuple(run['server_identity']['topology'][str(cpu)]) for cpu in cpus}
        assert len(cores) == workers == len(cpus)
        for snapshot in (run['server_before'], run['server_after']):
            if snapshot:
                assert all(set(thread['cpus']) <= cpus for thread in snapshot['threads'])
        placements = run['client_launch']['placements']
        if same_host:
            client_cores = {tuple(run['client_identity']['topology'][str(cpu)])
                            for placement in placements for cpu in placement}
            assert not cores & client_cores
        assert len(placements) == args['client_processes']
        assert len({cpu for placement in placements for cpu in placement}) == sum(map(len, placements))
        totals = {phase: Counter() for phase in PHASES}
        kinds = {phase: Counter() for phase in PHASES}
        histograms = {'latency_us': Counter(), 'failure_latency_us': Counter()}
        shards = run['client_result']['shards']
        assert len(shards) == args['client_processes']
        assert all(code == 0 for code in run['client_result']['exit_codes'].values())
        for i, shard in enumerate(shards):
            assert json.loads((path / 'client' / f'client-{i}.json').read_text()) == shard
            assert shard['streams'] == args['streams'] and shard['reconnections'] == 0
            assert shard['setup']['attempted'] + shard['setup_unattempted'] == shard['requested_connections']
            assert shard['setup']['succeeded'] == shard['established_connections']
            assert 0 <= shard['successful_connections'] <= shard['participating_connections'] <= shard['established_connections']
            assert 0 <= shard['alive_connections'] <= shard['established_connections']
            assert shard['seconds'] >= args['duration']
            observed = {phase: Counter() for phase in PHASES}
            receipt = run['client_result']['failure_logs'][i]
            assert receipt['path'] == f'client-{i}.failures.jsonl.gz'
            digest = hashlib.sha256()
            entries = 0
            with gzip.open(path / 'client' / receipt['path'], 'rb') as stream:
                for line in stream:
                    digest.update(line)
                    event = json.loads(line)
                    assert event['phase'] in PHASES
                    assert 0 <= event['connection'] < shard['requested_connections']
                    assert -1 <= event['stream_slot'] < args['streams']
                    assert event['started_unix_ns'] > 0 and event['elapsed_ns'] >= 0
                    assert event['error']
                    observed[event['phase']][event['kind']] += 1
                    entries += 1
            assert digest.hexdigest() == receipt['sha256_uncompressed']
            assert entries == receipt['entries'] == shard['failure_log_entries']
            for phase in PHASES:
                stats = shard[phase]
                assert stats['attempted'] == stats['succeeded'] + stats['failed']
                assert sum(observed[phase].values()) == stats['failed']
                assert observed[phase] == Counter(stats['failure_kinds'] or {})
                totals[phase].update({key: stats[key] for key in ('attempted', 'succeeded', 'failed')})
                kinds[phase].update(observed[phase])
            for key, count in (('latency_us', 'succeeded'), ('failure_latency_us', 'failed')):
                assert sum(shard[key].values()) == shard['measurement'][count]
                histograms[key].update({int(boundary): n for boundary, n in shard[key].items()})
        for phase in PHASES:
            for key in ('attempted', 'succeeded', 'failed'):
                assert run[phase][key] == totals[phase][key]
            assert Counter(run[phase]['failure_kinds']) == kinds[phase]
            failures[phase].update(kinds[phase])
        for key in ('requested_connections', 'established_connections', 'ready_connections',
                    'participating_connections', 'successful_connections', 'alive_connections',
                    'setup_unattempted', 'reconnections', 'failure_log_entries'):
            assert run[key] == sum(shard[key] for shard in shards)
        assert run['requested_connections'] == connections
        assert run['full_population'] == (run['ready_connections'] == connections and
                                          run['participating_connections'] == connections)
        elapsed = max(args['duration'], (max(s['end_ns'] for s in shards) - min(s['start_ns'] for s in shards)) / 1e9)
        assert run['seconds'] == elapsed
        assert run['requests_per_second'] == run['measurement']['succeeded'] / elapsed
        for percent in (50, 99):
            assert run[f'p{percent}_ms'] == percentile(histograms['latency_us'], percent)
        assert run['failure_p99_ms'] == percentile(histograms['failure_latency_us'], 99)
        successes += run['measurement']['succeeded']
    return {'passed': True, 'trials': len(actual), 'measured_successes': successes,
            'failures_by_phase_and_kind': failures,
            'failure_records': sum(sum(counts.values()) for counts in failures.values()),
            'setup_unattempted': sum(r['setup_unattempted'] for r in report['runs']),
            'partial_population_trials': sum(not r['full_population'] for r in report['runs']),
            'unexpected_server_exits': sum(r['server_exit_before_shutdown'] is not None for r in report['runs'])}


if __name__ == '__main__':
    print(json.dumps(audit(sys.argv[1]), indent=2))
