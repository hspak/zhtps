"""Build an immutable, source-recorded variant in a separate Zig cache."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--optimize', default='ReleaseSafe')
    parser.add_argument('--step', action='append', default=[])
    parser.add_argument('--zig-option', action='append', default=[])
    args = parser.parse_args()
    if not args.name or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-_' for c in args.name):
        parser.error('name must be a simple directory name')
    folder = ROOT / 'docs/nginx-implementation' / args.name
    folder.mkdir(exist_ok=False)
    snapshot = Path(tempfile.mkdtemp(prefix=f'zhtps-nginx-{args.name}-'))
    paths = [args.source / p for p in ('build.zig', 'build.zig.zon', 'README.md', 'AGENTS.md')]
    for base in ('src', 'bench', 'tests', 'deploy', 'examples/embedded'):
        paths.extend(p for p in (args.source / base).rglob('*')
                     if p.is_file() and p.suffix in ('.zig', '.zon', '.py', '.go', '.md', '.txt')
                     and not any(part in ('.zig-cache', 'zig-pkg', '__pycache__', 'zig-out')
                                 for part in p.relative_to(args.source / base).parts))
    paths = sorted(set(paths))
    with tarfile.open(folder / 'source.tar.gz', 'w:gz') as archive:
        for path in paths:
            relative = path.relative_to(args.source)
            archive.add(path, arcname=str(relative))
            destination = snapshot / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
    (snapshot / 'zig-pkg').symlink_to(ROOT / 'zig-pkg', target_is_directory=True)
    command = ['zig', 'build', *(args.step or ['install']), f'-Doptimize={args.optimize}',
               '--global-cache-dir', str(ROOT / '.zig-global-cache'),
               '--prefix', str(snapshot / 'out'), '--summary', 'all', *args.zig_option]
    receipt = dict(snapshot=str(snapshot), command=command,
                   source_archive_sha256=digest(folder / 'source.tar.gz'),
                   sources={str(p.relative_to(args.source)): digest(p) for p in paths},
                   zig_version=subprocess.check_output(['zig', 'version'], text=True).strip())
    with (folder / 'build.txt').open('w') as log:
        result = subprocess.run(command, cwd=snapshot, stdout=log, stderr=subprocess.STDOUT)
    receipt['build_exit'] = result.returncode
    receipt['binaries'] = {}
    if result.returncode == 0:
        destination = ROOT / 'zig-out/nginx-implementation' / args.name
        destination.mkdir(exist_ok=False, parents=True)
        for binary in sorted((snapshot / 'out/bin').iterdir()):
            installed = destination / binary.name
            # Zig installs can share cache inodes; preserve independent bytes.
            installed.write_bytes(binary.read_bytes())
            installed.chmod(binary.stat().st_mode & 0o777)
            receipt['binaries'][str(installed.relative_to(ROOT))] = digest(installed)
    (folder / 'build.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'name': args.name, 'exit': result.returncode,
                      'binaries': receipt['binaries']}, indent=2), flush=True)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
