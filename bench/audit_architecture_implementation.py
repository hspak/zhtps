"""Audit archived comparison binaries and accounting across architecture experiments."""

import hashlib
import json
from pathlib import Path
import tarfile


ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / 'docs/architecture-implementation'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit():
    issues = []
    versions = {}
    archives = []
    for path in sorted(FOLDER.rglob('*.tar.gz')):
        with tarfile.open(path) as archive:
            count = 0
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                content = archive.extractfile(member).read()
                versions.setdefault(member.name.removeprefix('./'), set()).add(hashlib.sha256(content).hexdigest())
                count += 1
        archives.append({'path': str(path.relative_to(ROOT)), 'sha256': digest(path), 'files': count})
    archived_harness = FOLDER / 'echo-rates/architecture.py'
    versions.setdefault('bench/architecture.py', set()).add(digest(archived_harness))
    binaries = {}
    for path in FOLDER.rglob('provenance.json'):
        for record in json.loads(path.read_text()).values():
            if not isinstance(record, dict) or 'binary_sha256' not in record:
                continue
            source = (path.parent / record['source_archive']).resolve()
            if not source.exists():
                issues.append(f'{path}: missing archive {source}')
            binary = Path(record['binary'])
            if not binary.is_absolute():
                binary = ROOT / binary
            if not binary.exists() or digest(binary) != record['binary_sha256']:
                issues.append(f'{path}: binary changed: {binary}')
            binaries[record['binary_sha256']] = {'binary': str(binary.relative_to(ROOT)),
                                                'source_archive': str(source.relative_to(ROOT))}
    for path in sorted(FOLDER.rglob('manifest.json')):
        for name, expected in json.loads(path.read_text())['sources'].items():
            if expected not in versions.get(name, set()) and (not (ROOT / name).exists() or digest(ROOT / name) != expected):
                issues.append(f'{path.relative_to(ROOT)}: unavailable source version: {name} {expected}')
    rows = []
    for path in sorted(FOLDER.rglob('run.json')):
        run = json.loads(path.read_text())
        checks = {}
        failures = {}
        checks['measured'] = run.get('outcome') == 'measured'
        if checks['measured']:
            checks['separate_hosts'] = run['server_identity']['boot_id'] != run['remote_identity']['boot_id']
            checks['archived_binary'] = run['binary_sha256'] in binaries
            checks['client_binary'] = run['remote_started']['binary_sha256'] == digest(ROOT / 'zig-out/bench/load')
            checks['server_exit'] = run['server_exit'] == 0
            checks['clock_uncertainty'] = run['clock_uncertainty_ns'] < 5_000_000
            load = run['load']
            checks['connections'] = load['connections'] == run['options']['connections']
            checks['client_procs'] = load['gomaxprocs'] == 8
            for index, phase in enumerate(load['phases']):
                failed = sum((phase['failures'] or {}).values())
                checks[f'{index}_offers'] = phase['offered'] == phase['started'] + phase['generator_queue_drops'] + phase['generator_expired']
                checks[f'{index}_outcomes'] = phase['started'] == phase['successes'] + phase['rejection_latency']['count'] + failed
                checks[f'{index}_latencies'] = phase['success_latency']['count'] == phase['success_service_latency']['count'] == phase['successes']
                checks[f'{index}_goodput'] = abs(phase['window_successes_per_second'] * phase['duration_seconds'] - phase['window_successes']) < .001
                checks[f'{index}_window'] = phase['window_successes'] <= phase['successes']
                start = phase['start_unix_ns'] + run['clock_offset_ns'] + 500_000_000
                end = phase['end_unix_ns'] + run['clock_offset_ns'] - 200_000_000
                checks[f'{index}_samples'] = sum(start <= sample['unix_ns'] < end for sample in run['samples']) >= 2
                for kind, count in (phase['failures'] or {}).items():
                    failures[kind] = failures.get(kind, 0) + count
        failed_checks = [name for name, passed in checks.items() if not passed]
        if failed_checks:
            issues.append(f'{path.relative_to(ROOT)}: {failed_checks}')
        rows.append({'path': str(path.relative_to(ROOT)), 'checks': len(checks),
                     'failed_checks': failed_checks, 'load_failures': failures,
                     'binary_sha256': run.get('binary_sha256')})
    return {'passed_integrity': not issues, 'issues': issues, 'archives': archives,
            'binaries': binaries, 'runs': rows,
            'scope': 'Binary preservation, source availability, two-host identity, and accounting. Source availability does not assert that an old binary was built from its newer measurement manifest. Failed requests remain failures; this audit does not certify sustained capacity.'}


if __name__ == '__main__':
    result = audit()
    (FOLDER / 'audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ('passed_integrity', 'issues', 'scope')}, indent=2))
    print(f"{len(result['runs'])} runs audited")
    raise SystemExit(0 if result['passed_integrity'] else 1)
