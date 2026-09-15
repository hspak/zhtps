"""Audit and summarize the separate HTTP/2 failure investigation, retaining every trial."""

import argparse
import base64
from collections import Counter
import gzip
import importlib.util
import json
from pathlib import Path
import statistics

from audit_http2_lan import audit


CASES = ('baseline', 'client7', 'paired', 'nic-busy7', 'nic-free7',
         'loopback', 'nic-samples', 'nic-samples-free')


def nic_samples(path, nic, start, end, speed):
    all_rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert all('error' not in row for row in all_rows)
    rows = [row for row in all_rows if start <= row['started_ns'] and row['finished_ns'] <= end]
    assert len(rows) > 1
    # Use a conservative 64-byte minimum frame, omitting preamble/interpacket overhead.
    max_gap_ns = 65536 * 64 * 8 * 1e9 / (speed * 1e6)
    pairs = list(zip(rows, rows[1:]))
    assert all(0 <= row['counters'][nic] < 65536 for row in rows)
    gaps = [b['finished_ns'] - a['started_ns'] for a, b in pairs]
    return {'samples': len(rows), 'first_ns': rows[0]['started_ns'], 'last_ns': rows[-1]['finished_ns'],
            'modulo_increment': sum((b['counters'][nic] - a['counters'][nic]) % 65536 for a, b in pairs),
            'observed_wraps': sum(b['counters'][nic] < a['counters'][nic] for a, b in pairs),
            'positive_intervals': sum(b['counters'][nic] != a['counters'][nic] for a, b in pairs),
            'max_gap_ms': max(gaps) / 1e6, 'ambiguous_wrap_intervals': sum(gap >= max_gap_ns for gap in gaps),
            'assumption': 'No counter reset. Extra wraps cannot be excluded in intervals exceeding the conservative line-rate bound.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-root', type=Path, default=Path('/tmp'))
    parser.add_argument('--output', type=Path, default=Path('docs/http2-diagnosis/summary.json'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('observer', root / 'docs/server-timeout-correlation/socket_observer.py')
    observer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(observer)
    groups, paired, audited = [], [], {}
    expected_server = json.loads((root / 'docs/http2-lan/summary.json').read_text())['binary_sha256']['zhtps']
    expected_client = json.loads((root / 'docs/http2-lan/summary.json').read_text())['binary_sha256']['client']
    for case in CASES:
        folder = args.input_root / ('zhtps-http2-diagnose-' + case)
        report = json.loads((folder / 'results.json').read_text())
        assert report['binary_sha256']['zhtps'] == expected_server
        if case != 'loopback':
            audited[case] = audit(folder)
            runs = report['runs']
        else:
            runs = [item['summary'] for item in report['runs']]
            for i, item in enumerate(report['runs']):
                assert item == json.loads((folder / f'r{i + 1}/run.json').read_text())
                assert item['server_exit_before_shutdown'] is None
                assert sum(s['measurement']['succeeded'] for s in item['result']['shards']) == item['summary']['measurement']['succeeded']
                for receipt in item['result']['failure_logs']:
                    raw = gzip.decompress((folder / f'r{i + 1}/client' / receipt['path']).read_bytes())
                    assert raw == b'' and receipt['entries'] == 0
            audited[case] = {'passed': True, 'trials': len(runs), 'failure_records': 0}
        for run in runs:
            assert run['ready_connections'] == run['alive_connections'] == 16384
            assert run['full_population']
        instrumented = case in ('paired', 'nic-samples', 'nic-samples-free')
        if not instrumented:
            assert report['binary_sha256']['client'] == expected_client
        groups.append({'case': case, 'trials': len(runs), 'instrumented_client': instrumented,
                       'client_sha256': report['binary_sha256']['client'],
                       'arguments': report.get('arguments'),
                       'median_rps': statistics.median(r['requests_per_second'] for r in runs),
                       'rps_range': [min(r['requests_per_second'] for r in runs), max(r['requests_per_second'] for r in runs)],
                       'median_p99_ms': statistics.median(r['p99_ms'] for r in runs),
                       'measured_successes': sum(r['measurement']['succeeded'] for r in runs),
                       'failures': {phase: sum(r[phase]['failed'] for r in runs) for phase in ('setup', 'holding', 'warmup', 'measurement')},
                       'measured_failures_by_trial': [r['measurement']['failed'] for r in runs]})
        if not instrumented:
            continue
        for run in runs:
            path = folder / f"w8-c16384-zhtps-r{run['repeat'] + 1}"
            server_rows = [json.loads(line) for line in (path / 'server-sockets.jsonl').read_text().splitlines()]
            servers = {(r['request']['client'], r['request']['failed_unix_ns']): r for r in server_rows}
            clients = []
            for failure_path in sorted((path / 'client').glob('*.failures.jsonl.gz')):
                rows = [json.loads(line) for line in gzip.open(failure_path, 'rt')]
                captured = [r for r in rows if 'diagnostic' in r]
                assert len(captured) <= 32
                assert len({r['connection'] for r in captured}) == len(captured)
                clients.extend(captured)
            assert set(servers) <= {(d['diagnostic']['client'], d['diagnostic']['failed_unix_ns']) for d in clients}
            counts, observations = Counter(), []
            unpaired = []
            delays, lateness, writes = [], [], []
            for failure in clients:
                d = failure['diagnostic']
                assert failure['phase'] == 'measurement' and failure['kind'] == 'timeout'
                assert 'probe_error' not in d
                # Lost UDP acknowledgments do not erase an independently retained server snapshot.
                if 'observer_error' in d:
                    assert d['observer_error'].endswith('i/o timeout')
                else:
                    assert d['observer_reply']['captured']
                row = servers.get((d['client'], d['failed_unix_ns']))
                if row is None:
                    assert 'observer_error' in d
                    unpaired.append(d)
                    continue
                assert 'probe_error' not in row
                s = row['server']
                assert s['state'] == 1 and s['remote'] == d['client'] and s['local'] == d['server']
                t, c = s['tcp_info'], observer.tcpInfo(base64.b64decode(d['client_tcp_info_raw']))
                predicates = {'waiting_headers': d['stage'] == 'headers',
                              'observer_ack_timeout': 'observer_error' in d,
                              'server_output_outstanding': s['outstanding_response_bytes'] > 0,
                              'server_unread_zero': s['unread_request_bytes'] == 0,
                              'server_unsent_zero': t['notsent_bytes'] == 0,
                              'server_timeout_retries_7plus': t['retransmits'] >= 7,
                              'client_unacked_zero': c['unacked'] == 0}
                counts.update({key: int(value) for key, value in predicates.items()})
                delays.append((s['started_unix_ns'] + run['clock']['offset_ns'] - d['failed_unix_ns']) / 1e6)
                lateness.append(failure['elapsed_ns'] / 1e6 - 2000)
                writes.append((d['wrote_request_ns'] - failure['started_unix_ns']) / 1e6)
                observations.append({'client': d['client'], 'failed_unix_ns': d['failed_unix_ns'],
                                     'server_tcp': t, 'client_tcp': c, 'server_outstanding': s['outstanding_response_bytes'],
                                     'server_unread': s['unread_request_bytes'], **predicates})
            result = {'case': case, 'captured': len(servers), 'client_captured': len(clients),
                      'unpaired': unpaired, 'counts': dict(counts), 'observations': observations,
                      'query_delay_ms': [min(delays), statistics.median(delays), max(delays)],
                      'deadline_lateness_ms': [min(lateness), statistics.median(lateness), max(lateness)],
                      'request_written_ms': [min(writes), statistics.median(writes), max(writes)], 'nic': {}}
            for host, nic, file in [('server', 'server_eth0', path / 'server-nic-missed.jsonl'),
                                    ('client', 'client_eth0', path / 'client/nic-missed.jsonl')]:
                if file.exists():
                    offset = run['clock']['offset_ns'] if host == 'client' else 0
                    result['nic'][host] = nic_samples(file, nic, run['server_network_before']['unix_ns'] + offset,
                                                      run['server_network_after']['unix_ns'] + offset, 2500)
            paired.append(result)
    args.output.write_text(json.dumps({'server_sha256': expected_server, 'groups': groups, 'paired': paired,
                                      'audit': audited, 'total_trials': sum(g['trials'] for g in groups)}, indent=2) + '\n')
    print(json.dumps({'trials': sum(g['trials'] for g in groups), 'paired_connections': sum(p['captured'] for p in paired),
                      'groups': [{k: g[k] for k in ('case', 'median_rps', 'failures')} for g in groups],
                      'nic_samples': [{'case': p['case'], 'nic': p['nic']} for p in paired if p['nic']]}, indent=2))


if __name__ == '__main__':
    main()
