"""Rotate keepalive policy trials on the recorded two-host LAN testbed."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import subprocess
import sys

from architecture import host_sample
from compare import admin_json, free_port, wait_ready
from overload import proc_sample, stop
from remote_load import identity
from summarize_architecture import summarize


ROOT = Path(__file__).resolve().parents[1]


def pressure(args, age, folder):
    port, admin = free_port(args.address), free_port()
    command = [str(args.binary.resolve()), '--address', args.address, '--port', str(port),
               '--admin-port', str(admin), '--workers', '1', '--worker-cpus', '9',
               '--max-connections', '1024', '--max-active', '1024', '--max-requests', '1000000',
               '--idle-timeout-ms', '60000', '--idle-reclaim-ms', str(age), '--no-access-log']
    source = (ROOT / 'bench/keepalive_returning_client.py').read_text()
    evidence = dict(command=command, server_identity=identity(),
                    binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                    client_source_sha256=hashlib.sha256(source.encode()).hexdigest())
    server = remote = None
    with (folder / 'server.log').open('w') as log, (folder / 'ssh.log').open('w') as sshlog:
        try:
            server = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log)
            wait_ready(server, port, args.address)
            evidence['running_binary_sha256'] = hashlib.sha256(Path(f'/proc/{server.pid}/exe').read_bytes()).hexdigest()
            assert evidence['running_binary_sha256'] == evidence['binary_sha256']
            remote = subprocess.Popen(['ssh', '-F', args.ssh_config, '-T', args.client_host,
                                       shlex.join(['python3', '-u', '-c', source])],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=sshlog, text=True)

            def send(message):
                remote.stdin.write(json.dumps(message) + '\n')
                remote.stdin.flush()

            send(dict(address=args.address, port=port, rounds=args.rounds, idle_ms=args.idle_ms))
            evidence['setup'] = json.loads(remote.stdout.readline())
            assert evidence['setup']['validated'] == 1024
            assert evidence['setup']['identity']['boot_id'] != evidence['server_identity']['boot_id']
            evidence['server_before'] = proc_sample(server.pid)
            evidence['host_before'] = host_sample()
            evidence['metrics_before'] = admin_json(admin, '/debug/metrics')
            send({'go': True})
            evidence['load'] = json.loads(remote.stdout.readline())
            evidence['server_after'] = proc_sample(server.pid)
            evidence['host_after'] = host_sample()
            evidence['metrics_after'] = admin_json(admin, '/debug/metrics')
            send({'finish': True})
            remote.wait(timeout=10)
            assert remote.returncode == 0
            evidence['outcome'] = 'measured'
        finally:
            if remote is not None:
                if remote.poll() is None:
                    remote.terminate()
                    remote.wait(timeout=5)
                remote.stdin.close()
                remote.stdout.close()
            stop(server)
            (folder / 'run.json').write_text(json.dumps(evidence, indent=2) + '\n')
    counters = evidence['metrics_after']['counters']
    previous = evidence['metrics_before']['counters']
    return dict(load=evidence['load'],
                server_cpu_seconds=evidence['server_after']['cpu_seconds'] - evidence['server_before']['cpu_seconds'],
                reclaimed=counters['connections_reclaimed_total'] - previous['connections_reclaimed_total'],
                reclaim_timeouts=counters['connection_reclaim_timeouts_total'] - previous['connection_reclaim_timeouts_total'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['normal', 'pressure'], required=True)
    parser.add_argument('--ages', type=int, nargs='+', default=[0, 50, 250, 1000])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--rounds', type=int, default=8)
    parser.add_argument('--idle-ms', type=int, default=150)
    parser.add_argument('--schedule', default='1000:3s,100000:12s,200000:12s')
    parser.add_argument('--address', default='192.0.2.10')
    parser.add_argument('--client-host', default='client.example')
    parser.add_argument('--ssh-config', default='/path/to/benchmark-ssh.conf')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 65536), hard))
    summary = []
    for repeat in range(args.repeats):
        order = args.ages[repeat % len(args.ages):] + args.ages[:repeat % len(args.ages)]
        for age in order:
            folder = args.output / f'age-{age}-r{repeat + 1}'
            print(f'Starting {folder}', flush=True)
            if args.mode == 'normal':
                command = [sys.executable, str(ROOT / 'bench/architecture.py'), '--output', str(folder),
                           '--variants', 'zig', '--zig-binary', str(args.binary.resolve()),
                           '--connections', '8192', '--workers', '7', '--capacity', '4096',
                           '--worker-cpus', '9-15', '--idle-reclaim-ms', str(age),
                           '--schedule', args.schedule, '--repeats', '1',
                           '--address', args.address, '--client-host', args.client_host,
                           '--ssh-config', args.ssh_config]
                subprocess.run(command, check=True)
                result = summarize(folder / 'zig-1/run.json')
            else:
                folder.mkdir()
                result = pressure(args, age, folder)
            summary.append(dict(age_ms=age, repeat=repeat + 1, result=result))
            (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            if args.mode == 'pressure':
                print(age, repeat + 1, result['load']['newcomers'], result['load']['residents'], flush=True)
            else:
                print(age, repeat + 1, [(p['offered_rate'], p['cpu_us_per_success_estimate'],
                                        p['service_p99_us'], p['failures'])
                                       for p in result['phases']], flush=True)


if __name__ == '__main__':
    main()
