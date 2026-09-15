"""Summarize paired optimization trials; keep each workload and all failures visible."""

import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path
import statistics

from audit_http2_lan import audit


def memory(snapshot, field):
    if snapshot is None:
        return None
    return next(int(line.split()[1]) * 1024 for line in snapshot['status'] if line.startswith(field + ':'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folders', nargs='+', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    groups = defaultdict(list)
    audits = []
    for folder in args.folders:
        audits.append({'folder': str(folder), **audit(folder)})
        report = json.loads((folder / 'results.json').read_text())
        for run in report['runs']:
            row = dict(run)
            row['rss_bytes'] = memory(run['server_after'], 'VmRSS')
            row['peak_rss_bytes'] = memory(run['server_after'], 'VmHWM')
            row['prepared_rss_bytes'] = memory(run['server_prepared'], 'VmRSS')
            row['measurement_failure_rate'] = run['measurement']['failed'] / max(1, run['measurement']['attempted'])
            group = (folder.name, report['arguments']['location'], run['workers'], run['connections'], run['variant'])
            groups[group].append(row)
    rows = []
    for (experiment, location, workers, connections, variant), runs in sorted(groups.items()):
        row = {'experiment': experiment, 'location': location, 'workers': workers,
               'connections': connections, 'streams': runs[0]['streams'], 'variant': variant,
               'trials': len(runs), 'full_population_trials': sum(run['full_population'] for run in runs),
               'server_binary_sha256': runs[0]['server_binary_sha256']}
        assert all(run['server_binary_sha256'] == row['server_binary_sha256'] for run in runs)
        for field in ('requests_per_second', 'server_cpu_us_per_request', 'p50_ms', 'p99_ms',
                      'rss_bytes', 'peak_rss_bytes', 'prepared_rss_bytes', 'measurement_failure_rate',
                      'server_cpu_cores', 'client_cpu_cores'):
            values = [run[field] for run in runs]
            row[field] = statistics.median(values)
            row[field + '_range'] = [min(values), max(values)]
        for phase in ('setup', 'holding', 'warmup', 'measurement'):
            for field in ('attempted', 'succeeded', 'failed'):
                row[f'{phase}_{field}'] = sum(run[phase][field] for run in runs)
        row['setup_unattempted'] = sum(run['setup_unattempted'] for run in runs)
        row['failure_records'] = sum(run['failure_log_entries'] for run in runs)
        rows.append(row)
    pairs = []
    for folder in args.folders:
        report = json.loads((folder / 'results.json').read_text())
        baseline, *candidates = report['variants']
        for candidate in candidates:
            for workers, connections in sorted({(run['workers'], run['connections']) for run in report['runs']}):
                before = groups[folder.name, report['arguments']['location'], workers, connections, baseline]
                after = groups[folder.name, report['arguments']['location'], workers, connections, candidate]
                old = {run['repeat']: run for run in before}
                new = {run['repeat']: run for run in after}
                assert old.keys() == new.keys()
                pair = {'experiment': folder.name, 'location': report['arguments']['location'],
                        'workers': workers, 'connections': connections, 'baseline': baseline,
                        'candidate': candidate, 'pairs': len(old),
                        'full_population_pairs': sum(old[i]['full_population'] and new[i]['full_population'] for i in old)}
                for field in ('requests_per_second', 'server_cpu_us_per_request', 'p99_ms', 'rss_bytes', 'peak_rss_bytes'):
                    changes = [(new[i][field] / old[i][field] - 1) * 100 for i in sorted(old)]
                    pair[field + '_paired_percent'] = changes
                    pair[field + '_paired_median_percent'] = statistics.median(changes)
                    pair[field + '_median_percent'] = (statistics.median(run[field] for run in after) /
                                                       statistics.median(run[field] for run in before) - 1) * 100
                pair['before_failures'] = sum(run['failure_log_entries'] for run in before)
                pair['after_failures'] = sum(run['failure_log_entries'] for run in after)
                pairs.append(pair)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'audits': audits, 'rows': rows, 'pairs': pairs}, indent=2) + '\n')
    with args.output.with_suffix('.csv').open('w', newline='') as file:
        columns = [key for key in rows[0] if not key.endswith('_range')]
        writer = csv.DictWriter(file, fieldnames=columns, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)
    for pair in pairs:
        print(f"{pair['experiment']} w{pair['workers']} c{pair['connections']} {pair['candidate']}: "
              f"RPS {pair['requests_per_second_median_percent']:+.1f}%, "
              f"CPU/req {pair['server_cpu_us_per_request_median_percent']:+.1f}%, "
              f"RSS {pair['rss_bytes_median_percent']:+.1f}%, "
              f"failures {pair['before_failures']} -> {pair['after_failures']}")


if __name__ == '__main__':
    main()
