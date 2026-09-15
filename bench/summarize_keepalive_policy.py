"""Summarize rotated policy trials, retaining ranges and failure accounting."""

import argparse
import json
from pathlib import Path
import statistics


def distribution(values):
    return dict(median=statistics.median(values), minimum=min(values), maximum=max(values), trials=values)


def summarize(path):
    rows = json.loads(path.read_text())
    result = {}
    for age in sorted({row['age_ms'] for row in rows}):
        group = [row['result'] for row in rows if row['age_ms'] == age]
        if 'phases' in group[0]:
            # The first phase is setup/warmup in both the screen and confirmation.
            phases = [r['phases'][1:] for r in group]
            result[age] = {
                rate: {
                    metric: distribution([p[metric] for trial in phases for p in trial
                                          if p['offered_rate'] == rate])
                    for metric in ('goodput', 'cpu_us_per_success_estimate', 'service_p99_us', 'offer_p99_us')
                } for rate in sorted({p['offered_rate'] for trial in phases for p in trial})
            }
            result[age]['failures'] = [p['failures'] for trial in phases for p in trial]
            result[age]['warmup_failures'] = [r['phases'][0]['failures'] for r in group]
        else:
            result[age] = {}
            for cohort in ('newcomers', 'residents'):
                samples = [r['load'][cohort] for r in group]
                result[age][cohort] = {
                    key: [sample[key] for sample in samples]
                    for key in ('offered', 'successes', 'failures', 'connections_opened', 'attempt_errors')
                }
                for key in ('p50_us', 'p99_us'):
                    values = [sample[key] for sample in samples if sample[key] is not None]
                    result[age][cohort][key] = distribution(values) if values else None
            result[age]['reclaimed'] = [r['reclaimed'] for r in group]
            result[age]['reclaim_timeouts'] = [r['reclaim_timeouts'] for r in group]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    result = {path.parent.name: summarize(path) for path in sorted(args.folder.glob('*/summary.json'))}
    output = args.folder / 'aggregate.json'
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
