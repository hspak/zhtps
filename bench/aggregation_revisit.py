"""Rotate matched pipeline comparisons and retain packet, CPU, and PMU evidence."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    'serial': (1, 0, 192),
    'pipeline8': (8, 0, 192),
    'pipeline32': (32, 0, 192),
    'fragmented8': (8, 8, 192),
    'roomy8': (8, 0, 1024),
    'roomy32': (32, 0, 1024),
}


def summarize(directory):
    rows = []
    for path in sorted(directory.glob('*.json')):
        if path.name in ('manifest.json', 'summary.json'):
            continue
        record = json.loads(path.read_text())
        if 'workload' not in record:
            continue
        case, variant, trial = path.stem.split('--')
        count = record['counter_deltas']['requests_completed_total']
        row = {
            'case': case, 'variant': variant, 'trial': int(trial),
            'responses_per_second': record['workload']['responses_per_second'],
            'cpu_ns_per_response': record['cpu_ns_per_response'],
            'tcp_segments_per_response': (record['kernel_after']['tcp_mib']['OutSegs'] - record['kernel_before']['tcp_mib']['OutSegs']) / count,
            'validated_responses': record['workload']['validated_responses'],
            'counter_deltas': record['counter_deltas'],
            'server_sha256': record['server_sha256'],
        }
        rows.append(row)
    medians = {}
    for case in CASES:
        medians[case] = {}
        for variant in sorted({row['variant'] for row in rows if row['case'] == case}):
            trials = [row for row in rows if row['case'] == case and row['variant'] == variant]
            medians[case][variant] = {
                'trials': len(trials),
                **{key: statistics.median(row[key] for row in trials) for key in
                   ('responses_per_second', 'cpu_ns_per_response', 'tcp_segments_per_response')},
            }
    result = {'trials': rows, 'medians': medians}
    (directory / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--variant', action='append', required=True, help='NAME=BINARY')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--cases', nargs='+', choices=CASES, default=list(CASES))
    parser.add_argument('--user-perf', action='store_true')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('use a fresh output directory')
    variants = dict(item.split('=', 1) for item in args.variant)
    if not 1 <= args.repeats <= 20 or any('--' in name or '/' in name for name in variants):
        parser.error('invalid repeats or variant name')
    args.output.mkdir(parents=True)
    (args.output / 'manifest.json').write_text(json.dumps({
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'variants': {name: {'binary': binary, 'sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest()} for name, binary in variants.items()},
        'cases': {name: CASES[name] for name in args.cases},
        'repeats': args.repeats,
        'user_perf_only': args.user_perf,
        'perf_event_paranoid': Path('/proc/sys/kernel/perf_event_paranoid').read_text().strip(),
    }, indent=2) + '\n')
    names = list(variants)
    for case in args.cases:
        depth, fragment, permits = CASES[case]
        for trial in range(args.repeats):
            order = names[trial % len(names):] + names[:trial % len(names)]
            for name in order:
                prefix = args.output / f'{case}--{name}--{trial + 1}'
                command = [sys.executable, str(ROOT / 'bench/pipeline_packets.py'), '--binary', variants[name],
                           '--output', str(prefix.with_suffix('.json')), '--depth', str(depth),
                           '--fragment', str(fragment), '--max-active', str(permits)]
                if args.user_perf:
                    command.append('--user-perf')
                with prefix.with_suffix('.runner.txt').open('w') as output:
                    subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=40)
                summary = summarize(args.output)
                row = next(row for row in summary['trials'] if row['case'] == case and row['variant'] == name and row['trial'] == trial + 1)
                print(json.dumps({key: row[key] for key in ('case', 'variant', 'trial', 'responses_per_second', 'cpu_ns_per_response', 'tcp_segments_per_response')}), flush=True)


if __name__ == '__main__':
    main()
