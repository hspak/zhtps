"""Compare verified component binaries with alternating execution order."""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variants", nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    binaries = {name: Path('/tmp/zhtps-experiments') / name / 'out/bin/hot-paths' for name in args.variants}
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()}
    if len(set(hashes.values())) != len(hashes):
        raise RuntimeError('different variants must have different binaries')
    for name, value in hashes.items():
        provenance = json.loads((Path(__file__).resolve().parents[1] / 'docs/critical-path-experiments' / (name + '-build.json')).read_text())
        tree = binaries[name].parents[2]
        current_sources = {str(path.relative_to(tree)): hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted((tree / "src").rglob("*.zig"))}
        if current_sources != provenance["sources"] or provenance['binaries']['hot-paths'] != value:
            raise RuntimeError(f"{name}: source or executable differs from recorded build")
    report = {'hashes': hashes, 'runs': []}
    for repeat in range(args.repeats):
        for name in (list(reversed(args.variants)) if repeat % 2 else args.variants):
            result = subprocess.run(['taskset', '-c', '2', str(binaries[name]), '20000000'],capture_output=True,text=True,check=True)
            report['runs'].append({'variant': name,'repeat': repeat,'rows': [json.loads(line) for line in result.stderr.splitlines()]})
    values = {}
    for run in report['runs']:
        for row in run['rows']:
            values.setdefault(run['variant'],{}).setdefault(row['case'],[]).append(row['elapsed_ns'] / row['iterations'])
    report['summary'] = {name: {case: {'median_ns':statistics.median(ns),'min_ns':min(ns),'max_ns':max(ns)} for case,ns in cases.items()} for name,cases in values.items()}
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({name:{case:times for case,times in cases.items() if case.startswith('parser')} for name,cases in report['summary'].items()},indent=2),flush=True)


if __name__ == '__main__':
    main()
