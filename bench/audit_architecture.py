"""Check diagnostic provenance and accounting; recorded load errors remain errors."""

import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(folder):
    issues = []
    manifests = []
    rows = []
    for path in sorted(folder.rglob('manifest.json')):
        manifest = json.loads(path.read_text())
        changed = []
        for name, expected in manifest['sources'].items():
            source = path.parent / 'harness.py' if name == 'bench/architecture.py' else Path(name)
            if not source.exists() or digest(source) != expected:
                changed.append(name)
        manifests.append(dict(path=str(path), changed_sources=changed))
        if changed:
            issues.append(f'{path}: source mismatch: {changed}')
    for path in sorted(folder.rglob('run.json')):
        run = json.loads(path.read_text())
        if run.get('outcome') != 'measured':
            rows.append(dict(path=str(path), outcome=run.get('outcome'), excluded=True,
                             error=run.get('error')))
            continue
        checks = []
        server, client = run['server_identity'], run['remote_identity']
        checks.append(server['boot_id'] != client['boot_id'])
        checks.append(run['remote_started']['binary_sha256'] == digest(Path('zig-out/bench/load')))
        binary = run['options'].get('zig_binary', 'zig-out/bench/release_safe/bin/zhtps')
        if run['variant'] == 'go':
            binary = 'zig-out/bench/go_profile' if run['options']['profile'] else 'zig-out/bench/go_server'
            checks.append(run['go_runtime']['gomaxprocs'] == 32)
        checks.append(run['binary_sha256'] == digest(Path(binary)))
        checks.append(run['server_exit'] == (0 if run['variant'] == 'zig' or run['options']['profile'] else -15))
        checks.append(run['clock_uncertainty_ns'] < 5_000_000)
        load = run['load']
        checks.append(load['connections'] == 8192)
        failures = {}
        if 'phases' in load:
            checks.append(load['gomaxprocs'] == 8)
            checks.append(load['phases'][0]['connections_opened'] == 8192)
            for phase in load['phases']:
                phase_failures = sum((phase['failures'] or {}).values())
                checks.append(phase['offered'] == phase['started'] + phase['generator_queue_drops'] + phase['generator_expired'])
                checks.append(phase['started'] == phase['successes'] + phase['rejection_latency']['count'] + phase_failures)
                checks.append(phase['success_latency']['count'] == phase['successes'])
                checks.append(phase['success_service_latency']['count'] == phase['successes'])
                checks.append(phase['window_successes'] <= phase['successes'])
                checks.append(abs(phase['window_successes_per_second'] * phase['duration_seconds'] - phase['window_successes']) < .001)
                start = phase['start_unix_ns'] + run['clock_offset_ns'] + 500_000_000
                end = phase['end_unix_ns'] + run['clock_offset_ns'] - 200_000_000
                checks.append(sum(start <= sample['unix_ns'] < end for sample in run['samples']) >= 2)
                for kind, count in (phase['failures'] or {}).items():
                    failures[kind] = failures.get(kind, 0) + count
        else:
            checks.append(load['connections_ready'] == load['connections_measured'] == 8192)
            checks.append(load['attempts'] == load['successes'] + load['errors'])
            checks.append(load['errors'] == sum((load['failures'] or {}).values()))
            failures = dict(load['failures'] or {})
        failed_checks = [i for i, passed in enumerate(checks) if not passed]
        if failed_checks:
            issues.append(f'{path}: failed integrity checks {failed_checks}')
        rows.append(dict(path=str(path), outcome='measured', checks=len(checks),
                         failed_checks=failed_checks, load_failures=failures,
                         warmup_errors=load.get('warmup_errors'),
                         clock_uncertainty_ms=run['clock_uncertainty_ns'] / 1e6))
    return dict(passed_integrity=not issues, issues=issues, manifests=manifests, runs=rows,
                scope='Provenance and accounting only; this is not a zero-error capacity or sustained-load certification.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    result = audit(args.folder)
    (args.folder / 'audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ('passed_integrity', 'issues', 'scope')}, indent=2))
    raise SystemExit(0 if result['passed_integrity'] else 1)
