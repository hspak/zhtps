"""Summarize completed LAN measurements without dropping trials with failures."""

import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import statistics

from audit_http2_lan import audit, PHASES


NAMES = {'zhtps': 'ZHTPS', 'go': 'Go', 'node': 'Node', 'bun': 'Bun'}


def retransmissions(run):
    if 'server_network_before' not in run:
        return None, None
    def counter(sample):
        lines = sample['tcp'].splitlines()
        for i in range(0, len(lines), 2):
            if lines[i].startswith('Tcp:'):
                return dict(zip(lines[i].split()[1:], map(int, lines[i + 1].split()[1:])))['RetransSegs']
        raise ValueError('missing TCP counters')
    before, after = run['server_network_before'], run['server_network_after']
    count = counter(after) - counter(before)
    assert count >= 0, 'TCP counter decreased'
    elapsed = (after['unix_ns'] - before['unix_ns']) / 1e9
    return count, count / elapsed


def summarize(folder):
    folder = Path(folder)
    receipt = audit(folder)
    report = json.loads((folder / 'results.json').read_text())
    groups = {}
    for run in report['runs']:
        key = (run['workers'], run['connections'], run['server'])
        groups.setdefault(key, []).append(run)
    rows = []
    for (workers, connections, server), runs in groups.items():
        row = {'workers': workers, 'connections': connections, 'server': server,
               'streams': report['arguments']['streams'], 'trials': len(runs),
               'full_population_trials': sum(r['full_population'] for r in runs),
               'unexpected_server_exits': sum(r['server_exit_before_shutdown'] is not None for r in runs)}
        for key in ('requests_per_second', 'p50_ms', 'p99_ms', 'failure_p99_ms',
                    'server_cpu_cores', 'server_cpu_us_per_request', 'client_cpu_cores',
                    'seconds', 'start_skew_ms'):
            values = [run[key] for run in runs if run[key] is not None]
            row[key] = statistics.median(values) if values else None
            row['min_' + key] = min(values) if values else None
            row['max_' + key] = max(values) if values else None
        for key in ('established_connections', 'ready_connections', 'participating_connections',
                    'successful_connections', 'alive_connections'):
            row['min_' + key] = min(r[key] for r in runs)
            row['max_' + key] = max(r[key] for r in runs)
        for key in ('setup_unattempted', 'reconnections', 'failure_log_entries'):
            row[key] = sum(r[key] for r in runs)
        for index, key in enumerate(('server_tcp_retransmitted_segments', 'server_tcp_retransmits_per_second')):
            values = [retransmissions(run)[index] for run in runs]
            values = [value for value in values if value is not None]
            row[key] = statistics.median(values) if values else None
            row['min_' + key] = min(values) if values else None
            row['max_' + key] = max(values) if values else None
        for phase in PHASES:
            for key in ('attempted', 'succeeded', 'failed'):
                row[f'{phase}_{key}'] = sum(r[phase][key] for r in runs)
            kinds = Counter()
            for run in runs:
                kinds.update(run[phase]['failure_kinds'])
            row[f'{phase}_failure_kinds'] = dict(kinds)
        row['measurement_failure_percent'] = (100 * row['measurement_failed'] / row['measurement_attempted']
                                               if row['measurement_attempted'] else None)
        rows.append(row)
    rows.sort(key=lambda r: (r['workers'], r['connections'], list(NAMES).index(r['server'])))
    totals = []
    for server in NAMES:
        selected = [row for row in rows if row['server'] == server]
        if not selected:
            continue
        total = {'server': server, 'trials': sum(row['trials'] for row in selected)}
        for key in ('setup_unattempted', 'measurement_attempted', 'measurement_succeeded',
                    'measurement_failed', 'setup_failed', 'holding_failed', 'warmup_failed',
                    'failure_log_entries', 'unexpected_server_exits'):
            total[key] = sum(row[key] for row in selected)
        totals.append(total)
    return {'started_utc': report['started_utc'], 'finished_utc': report['finished_utc'],
            'generated_utc': datetime.now(timezone.utc).isoformat(),
            'arguments': report['arguments'], 'server_identity': report['server_identity'],
            'client_identity': report['runs'][0]['client_identity'], 'versions': report['versions'],
            'binary_sha256': report['binary_sha256'], 'audit': receipt, 'rows': rows, 'totals': totals}


def number(value, precision=0):
    return '—' if value is None else f'{value:,.{precision}f}'


def extent(row, key):
    low, high = row['min_' + key], row['max_' + key]
    return number(low) if low == high else f'{number(low)}–{number(high)}'


def findings(summary):
    indexed = {(r['workers'], r['connections'], r['server']): r for r in summary['rows']}
    pairs = []
    for row in summary['rows']:
        if row['workers'] == 1 or row['server'] != 'zhtps':
            continue
        other = indexed[row['workers'], row['connections'], 'go']
        if all(r['full_population_trials'] == r['trials'] for r in (row, other)):
            pairs.append((row, other))
    text = []
    for connections in (64, 1024):
        group = [r for r in summary['rows'] if r['workers'] == 1 and r['connections'] == connections]
        if group and all(r['full_population_trials'] == r['trials'] for r in group):
            leader = max(group, key=lambda r: r['requests_per_second'])
            text.append(f"At one CPU and {connections:,} connections, {NAMES[leader['server']]} has the highest "
                        f"median verified throughput: {number(leader['requests_per_second'])} responses/s.")
    if pairs:
        faster = sum(z['requests_per_second'] > g['requests_per_second'] for z, g in pairs)
        slower_tail = [(z['workers'], z['connections']) for z, g in pairs
                       if z['p99_ms'] is not None and g['p99_ms'] is not None and z['p99_ms'] > g['p99_ms']]
        text.append(f'Among the {len(pairs)} multi-worker workload pairs where both servers reached the '
                    f'full population in every trial, ZHTPS has higher median throughput in {faster}.')
        if slower_tail:
            labels = ', '.join(f'{w} CPUs / {c:,} connections' for w, c in slower_tail)
            text.append(f'Its median successful-response p99 is higher than Go at {labels}.')
    text.append('Throughput, latency, connection capacity, and failures must be considered together; '
                'partial-population trials are excluded from that count of full-population comparisons.')
    return '\n\n'.join(text)


def tables(summary):
    rows = summary['rows']
    by_key = {(r['workers'], r['connections'], r['server']): r for r in rows}

    def cell(row):
        flag = ' †' if row['full_population_trials'] != row['trials'] else ''
        return f"{number(row['requests_per_second'])}{flag}<br>{number(row['p99_ms'], 3)} ms"

    single = ['| Requested connections | ZHTPS | Go | Node | Bun |', '|---:|---:|---:|---:|---:|']
    for connections in sorted({r['connections'] for r in rows if r['workers'] == 1}):
        single.append(f'| {connections:,} | ' + ' | '.join(cell(by_key[1, connections, name])
                                                        for name in NAMES) + ' |')
    multi = ['| Server CPUs / workers | Requested connections | ZHTPS | Go |', '|---:|---:|---:|---:|']
    for workers, connections in sorted({(r['workers'], r['connections']) for r in rows if r['workers'] > 1}):
        multi.append(f'| {workers} | {connections:,} | ' + ' | '.join(cell(by_key[workers, connections, name])
                                                                 for name in ('zhtps', 'go')) + ' |')
    populations = ['| CPUs | Requested | Server | Ready at measurement start | Successful connections | Alive at end | Full-population trials |',
                   '|---:|---:|---|---:|---:|---:|---:|']
    failures = ['| CPUs | Requested | Server | Setup failures | Holding failures | Warmup failures | Measured failures | Measured failure rate | Unattempted connections |',
                '|---:|---:|---|---:|---:|---:|---:|---:|---:|']
    ranges = ['| CPUs | Requested | Server | Requests/s range | p99 range (ms) | Server CPU µs/success | Client CPU cores | Host TCP retransmits/s |',
              '|---:|---:|---|---:|---:|---:|---:|---:|']
    for row in rows:
        prefix = f"| {row['workers']} | {row['connections']:,} | {NAMES[row['server']]} | "
        populations.append(prefix + ' | '.join(extent(row, key) for key in
                                               ('ready_connections', 'successful_connections', 'alive_connections'))
                           + f" | {row['full_population_trials']}/{row['trials']} |")
        failures.append(prefix + ' | '.join(number(row[f'{phase}_failed']) for phase in PHASES)
                        + f" | {number(row['measurement_failure_percent'], 4)}% | {row['setup_unattempted']:,} |")
        ranges.append(prefix + f"{number(row['min_requests_per_second'])}–{number(row['max_requests_per_second'])} | "
                      f"{number(row['min_p99_ms'], 3)}–{number(row['max_p99_ms'], 3)} | "
                      f"{number(row['server_cpu_us_per_request'], 3)} | {number(row['client_cpu_cores'], 2)} | "
                      f"{number(row['server_tcp_retransmits_per_second'])} |")
    totals = ['| Server | Trials | Verified measured responses | Setup failures | Holding failures | Warmup failures | Measured failures |',
              '|---|---:|---:|---:|---:|---:|---:|']
    for total in summary['totals']:
        totals.append(f"| {NAMES[total['server']]} | {total['trials']} | " + ' | '.join(number(total[key]) for key in
                      ('measurement_succeeded', 'setup_failed', 'holding_failed', 'warmup_failed', 'measurement_failed')) + ' |')
    return {'SINGLE': '\n'.join(single), 'MULTI': '\n'.join(multi), 'POPULATIONS': '\n'.join(populations),
            'FAILURES': '\n'.join(failures), 'RANGES': '\n'.join(ranges), 'TOTALS': '\n'.join(totals)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--calibration', type=Path)
    args = parser.parse_args()
    summary = summarize(args.folder)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (args.output / 'audit.json').write_text(json.dumps(summary['audit'], indent=2) + '\n')
    with (args.output / 'summary.csv').open('w') as output:
        fields = list(summary['rows'][0])
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        for row in summary['rows']:
            writer.writerow({k: json.dumps(v, sort_keys=True) if isinstance(v, dict) else v for k, v in row.items()})
    if args.report:
        template = (Path(__file__).parent / 'http2_lan_report.md').read_text()
        for marker, value in tables(summary).items():
            template = template.replace(f'@@{marker}@@', value)
        template = template.replace('@@TRIALS@@', str(summary['audit']['trials']))
        template = template.replace('@@SUCCESSES@@', number(summary['audit']['measured_successes']))
        template = template.replace('@@FAILURE_RECORDS@@', number(summary['audit']['failure_records']))
        template = template.replace('@@STARTED@@', summary['started_utc'])
        template = template.replace('@@FINISHED@@', summary['finished_utc'])
        template = template.replace('@@FINDINGS@@', findings(summary))
        calibration = (json.loads(args.calibration.read_text())['finding'] if args.calibration else
                       'These primary measurements use the stated client placement; see the separate client calibration.')
        template = template.replace('@@CALIBRATION_NOTE@@', calibration)
        args.report.write_text(template)
    print(json.dumps(summary['audit'], indent=2))


if __name__ == '__main__':
    main()
