"""Paired ZHTPS HTTP/2 variants using the audited LAN client and failure accounting."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import resource
import shlex
import shutil
import socket
import subprocess
import tarfile
import tempfile

import compare_http2_lan as base
from compare_http2 import cpu_list, topology


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', action='append', required=True, help='label=path/to/zhtps')
    parser.add_argument('--location', choices=('loopback', 'remote'), required=True)
    parser.add_argument('--client-host', default='client.example')
    parser.add_argument('--ssh-key', default='/path/to/benchmark-key')
    parser.add_argument('--address')
    parser.add_argument('--client', default='zig-out/http2-benchmark/lan-client')
    parser.add_argument('--server-cpus', default='0-7')
    parser.add_argument('--client-cpus')
    parser.add_argument('--client-processes', type=int, default=8)
    parser.add_argument('--workers', default='1,2,4,8')
    parser.add_argument('--connections', default='64,1024,8192,16384')
    parser.add_argument('--streams', type=int, default=4)
    parser.add_argument('--duration', type=float, default=8)
    parser.add_argument('--warmup', type=float, default=2)
    parser.add_argument('--timeout', type=float, default=2)
    parser.add_argument('--setup-deadline', type=float, default=180)
    parser.add_argument('--setup-concurrency', type=int, default=32)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.address = args.address or ('127.0.0.1' if args.location == 'loopback' else '192.0.2.10')
    args.client_cpus = args.client_cpus or ('8-15,24-31' if args.location == 'loopback' else '0-15')
    variants = dict(value.split('=', 1) for value in args.variant)
    if len(variants) != len(args.variant) or len(variants) < 2:
        parser.error('at least two uniquely named variants are required')
    if any(not name.replace('-', '').replace('_', '').isalnum() for name in variants):
        parser.error('variant labels must be letters, numbers, hyphens or underscores')
    variants = {name: str(Path(path).resolve()) for name, path in variants.items()}
    workers = list(map(int, args.workers.split(',')))
    populations = list(map(int, args.connections.split(',')))
    cpus, client_cpus = cpu_list(args.server_cpus), cpu_list(args.client_cpus)
    if min(workers) < 1 or max(workers) > len(cpus) or not set(cpus) <= set(base.identity()['allowed_cpus']):
        parser.error('invalid worker/CPU selection')
    if min(populations) < args.client_processes or not 1 <= args.streams <= 100 or args.duration <= 0 or args.repeats < 1:
        parser.error('invalid workload')
    if args.location == 'loopback':
        if {topology(cpu) for cpu in cpus} & {topology(cpu) for cpu in client_cpus}:
            parser.error('loopback server/client must use separate physical cores')
    args.client = str(Path(args.client).resolve())
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, max(soft, 131072)), hard))
    binaries = {**variants, 'client': args.client}
    hashes = {name: base.digest(path) for name, path in binaries.items()}
    sources = [Path(__file__), base.ROOT / 'bench/compare_http2_lan.py',
               base.ROOT / 'bench/compare_http2.py', base.ROOT / 'bench/http2_remote.py',
               *sorted((base.ROOT / 'bench/http2_lan_client').glob('*'))]
    sources = [path for path in sources if path.is_file()]
    source_hashes = {str(path.relative_to(base.ROOT)): base.digest(path) for path in sources}
    with tarfile.open(args.output / 'harness.tar.gz', 'w:gz') as archive:
        for path in sources:
            archive.add(path, arcname=str(path.relative_to(base.ROOT)))
    report = {'started_utc': datetime.now(timezone.utc).isoformat(),
              'arguments': {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
              'variants': variants, 'binary_sha256': hashes, 'harness_sha256': source_hashes,
              'server_identity': base.identity(), 'runs': [], 'skipped': [], 'complete': False,
              'order': 'Rotate variant order between repetitions within each worker/connection pair.'}

    def save():
        temporary = args.output / 'results.tmp'
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(args.output / 'results.json')

    ssh_options = ['-i', str(Path(args.ssh_key).expanduser()), '-o', 'IdentitiesOnly=yes',
                   '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10']
    ssh = ['ssh', *ssh_options, args.client_host] if args.location == 'remote' else []
    with tempfile.TemporaryDirectory(prefix='zhtps-h2-variant-stage-') as temporary:
        stage = Path(temporary)
        remote_dir = subprocess.check_output([*ssh, 'mktemp -d /tmp/zhtps-http2-variants.XXXXXXXX'], text=True).strip() if ssh else str(stage)
        report['client_staging_directory'] = remote_dir
        save()
        cert, key = stage / 'cert.pem', stage / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                        '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=zhtps-benchmark',
                        '-addext', f'subjectAltName=IP:{args.address}'], check=True, capture_output=True)
        for path, name in ((Path(args.client), 'client'), (base.ROOT / 'bench/http2_remote.py', 'http2_remote.py'), (cert, 'cert.pem')):
            if ssh:
                subprocess.run(['scp', *ssh_options, str(path), f'{args.client_host}:{remote_dir}/{name}'], check=True)
            elif path != stage / name:
                shutil.copy2(path, stage / name)
        used_ports = set()
        for count in workers:
            for population in populations:
                if population > count * 8176:
                    report['skipped'].append({'workers': count, 'connections': population,
                                              'reason': 'Exceeds unchanged 8,176 connections per worker; already diagnosed capacity limit.'})
                    save()
                    continue
                for repeat in range(args.repeats):
                    labels = list(variants)
                    offset = repeat % len(labels)
                    for label in labels[offset:] + labels[:offset]:
                        while True:
                            with socket.socket() as listener:
                                listener.bind((args.address, 0))
                                port = listener.getsockname()[1]
                            if port not in used_ports:
                                used_ports.add(port)
                                break
                        name = f'w{count}-c{population}-{label}-r{repeat + 1}'
                        args.zhtps = variants[label]
                        run = base.trial(args, ssh, remote_dir, 'zhtps', count, population, repeat, port, cert, key, args.output / name)
                        run['variant'] = label
                        run['server_binary_sha256'] = hashes[label]
                        (args.output / name / 'run.json').write_text(json.dumps(run, indent=2) + '\n')
                        report['runs'].append(run)
                        save()
                        if not run['valid']:
                            raise RuntimeError(f'{name}: invalid trial retained: {run.get("error", run.get("artifact_error"))}')
                        status = run['server_after']['status']
                        rss = next(int(line.split()[1]) for line in status if line.startswith('VmRSS:')) / 1024
                        print(f"{name}: {run['requests_per_second']:,.0f}/s, CPU {run['server_cpu_us_per_request']:.3f} us/req, "
                              f"RSS {rss:.1f} MiB, p99 {run['p99_ms']:.3f} ms, "
                              f"failures {run['failure_log_entries']}, ready {run['ready_connections']}/{population}", flush=True)
        for name, path in binaries.items():
            assert base.digest(path) == hashes[name]
        for path in sources:
            assert base.digest(path) == source_hashes[str(path.relative_to(base.ROOT))]
        report['complete'] = bool(report['runs']) and all(run['valid'] for run in report['runs'])
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        save()
        if ssh and report['complete']:
            subprocess.run([*ssh, shlex.join(['rm', '-rf', '--', remote_dir])], check=True)


if __name__ == '__main__':
    main()
