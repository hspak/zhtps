"""Audit and summarize fixed-population HTTP/2 allocation and RSS measurements."""

import argparse
from collections import defaultdict
import csv
import hashlib
import json
from pathlib import Path
import statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = json.loads((args.folder / 'results.json').read_text())
    assert report['complete']
    labels = list(report['binary_sha256'])
    root = Path(__file__).resolve().parents[1]
    for label, expected in report['binary_sha256'].items():
        receipt = json.loads((root / f'docs/bun-http2-implementation/{label}-build.json').read_text())
        assert expected == receipt['binary_sha256']
    for path, expected in report['source_sha256'].items():
        assert hashlib.sha256((root / path).read_bytes()).hexdigest() == expected, path
    population = report['workload']['connections'] * report['workload']['streams']
    seen, groups = set(), defaultdict(list)
    for run in report['runs']:
        key = run['workers'], run['repeat'], run['variant']
        assert key not in seen
        seen.add(key)
        assert not run['errors'] and run['server_exit'] == 0
        assert run['successful_uploads'] == population
        assert '--worker-cpus' in run['command']
        assert run['command'][run['command'].index('--worker-cpus') + 1] == ','.join(map(str, range(run['workers'])))
        for phase, snapshot in run['snapshots'].items():
            gauges = snapshot['metrics']['gauges']
            active = population if phase.startswith('pending_') else 0
            assert gauges['http2_streams_active'] == active
            assert gauges['requests_active'] == active
            assert 0 <= gauges['http2_streams_cached'] <= 64 * run['workers']
            row = {'charged_bytes': gauges['http2_bytes_allocated'],
                   'cached_streams': gauges['http2_streams_cached']}
            for name, field in [('rss_bytes', 'VmRSS'), ('peak_rss_bytes', 'VmHWM'), ('virtual_bytes', 'VmSize')]:
                row[name] = int(next(line for line in snapshot['status'] if line.startswith(field + ':')).split()[1]) * 1024
            groups[run['workers'], run['variant'], phase].append(row)
    assert seen == {(w, r, label) for w in (1, 2, 4, 8) for r in (1, 2, 3) for label in labels}
    rows = []
    for (workers, variant, phase), items in sorted(groups.items()):
        assert len(items) == 3
        row = {'workers': workers, 'variant': variant, 'phase': phase, 'trials': len(items)}
        for field in items[0]:
            values = [item[field] for item in items]
            row[field] = statistics.median(values)
            row[field + '_range'] = [min(values), max(values)]
        rows.append(row)
    lookup = {(row['workers'], row['variant'], row['phase']): row for row in rows}
    pairs = []
    for workers in (1, 2, 4, 8):
        for phase in ('connected', 'pending_heads', 'pending_bodies', 'completed'):
            before, after = (lookup[workers, label, phase] for label in labels)
            pair = {'workers': workers, 'phase': phase}
            for field in ('charged_bytes', 'rss_bytes', 'peak_rss_bytes', 'virtual_bytes'):
                pair[field + '_median_percent'] = (after[field] / before[field] - 1) * 100
                pair[field + '_before'] = before[field]
                pair[field + '_after'] = after[field]
            pairs.append(pair)
    args.output.write_text(json.dumps({'audit': {'trials': len(seen), 'verified_uploads': len(seen) * population,
                                               'failed_uploads': 0, 'source_hashes_verified': True},
                                       'rows': rows, 'pairs': pairs}, indent=2) + '\n')
    with args.output.with_suffix('.csv').open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=list(pairs[0]))
        writer.writeheader()
        writer.writerows(pairs)
    for pair in pairs:
        if pair['phase'] == 'connected':
            continue
        print(f'w{pair["workers"]} {pair["phase"]}: charged {pair["charged_bytes_median_percent"]:+.1f}%, RSS {pair["rss_bytes_median_percent"]:+.1f}%')


if __name__ == '__main__':
    main()
