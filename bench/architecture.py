"""Measure LAN request cost, host packet processing, placement and optional CPU profiles."""

import argparse
import hashlib
import inspect
import json
import os
from pathlib import Path
import resource
import shlex
import signal
import subprocess
import time

from compare import BUILD, ROOT, admin_json, free_port, wait_ready
from overload import cpu_list, proc_sample, stop
from remote_load import RemoteLoad, identity


def host_sample():
    result = {"unix_ns": time.time_ns()}
    for name in ("stat", "softirqs", "net/snmp", "net/netstat", "net/softnet_stat"):
        result[name] = Path('/proc/' + name).read_text()
    result['nics'] = {nic.name: {p.name: int(p.read_text())
                               for p in (nic / 'statistics').iterdir()}
                      for nic in Path('/sys/class/net').iterdir() if (nic / 'device').exists()}
    return result


def remote_source():
    source = (ROOT / 'bench/remote_load.py').read_text().rsplit('\nif __name__', 1)[0]
    return source + '\n' + inspect.getsource(host_sample) + '''
base_sample = sample_process
def sample_process(pid):
    try:
        result = base_sample(pid)
    except PermissionError as error:
        # A client closing thousands of sockets can make fd enumeration
        # unavailable before it has finished exiting. Retain other counters.
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        result = dict(unix_ns=time.time_ns(),
                      cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                      fd_sample_error=repr(error))
    result['host'] = host_sample()
    return result
agent()
'''


def run_one(args, variant, repeat, folder):
    port, admin = free_port(args.address), free_port()
    while port == admin:
        admin = free_port()
    if variant == 'go':
        binary = (Path(args.go_binary).resolve() if args.go_binary else
                  BUILD / ('go_profile' if args.profile else 'go_server'))
    else:
        binary = Path(args.before_binary if variant == 'before' else args.zig_binary).resolve()
    command = [str(binary)]
    if args.server_cpus:
        command = ['taskset', '-c', args.server_cpus, *command]
    if variant == 'go':
        command += ['-listen', f'{args.address}:{port}']
    else:
        command += ['--address', args.address, '--port', str(port), '--admin-port', str(admin),
                    '--workers', str(args.workers), '--max-connections', str(args.capacity),
                    '--max-active', str(args.capacity), '--max-requests', '4294967295',
                    '--completion-budget', str(args.completion_budget)]
        if not args.access_log:
            command += ['--no-access-log']
        if args.worker_cpus:
            command += ['--worker-cpus', args.worker_cpus]
        if args.idle_reclaim_ms is not None:
            command += ['--idle-reclaim-ms', str(args.idle_reclaim_ms)]
    env = dict(os.environ)
    for setting in ('GOMAXPROCS', 'GOGC', 'GOMEMLIMIT', 'GODEBUG'):
        env.pop(setting, None)
    if args.go_procs:
        env['GOMAXPROCS'] = str(args.go_procs)
    if variant == 'go' and args.profile:
        env['ZHTPS_GO_PROFILE'] = str(folder / 'go')
        env['GODEBUG'] = 'gctrace=1'
    if variant == 'go' and args.go_gc_off:
        env['GOGC'] = 'off'
    evidence = dict(variant=variant, repeat=repeat, command=command,
                    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    server_identity=identity(), options=vars(args).copy(), samples=[])
    server = remote = perf = None
    log_path = Path(os.devnull) if args.log_output == 'null' else folder / 'server.log'
    with log_path.open('w') as log, (folder / 'ssh.log').open('w') as sshlog:
        try:
            server = subprocess.Popen(command, env=env, stdout=subprocess.PIPE if variant == 'go' else subprocess.DEVNULL,
                                      stderr=log, text=True)
            evidence['go_runtime'] = json.loads(server.stdout.readline()) if variant == 'go' else None
            wait_ready(server, port, args.address)
            evidence['running_binary_sha256'] = hashlib.sha256(
                Path(f'/proc/{server.pid}/exe').read_bytes()).hexdigest()
            assert evidence['running_binary_sha256'] == evidence['binary_sha256']
            evidence['server_affinity'] = sorted(os.sched_getaffinity(server.pid))
            source = remote_source()
            transport = ['ssh', '-F', args.ssh_config, '-T', args.client_host,
                         shlex.join(['python3', '-u', '-c', source])]
            remote = RemoteLoad(args.client_host, sshlog, transport=transport)
            assert remote.identity['boot_id'] != evidence['server_identity']['boot_id']
            evidence['remote_identity'] = remote.identity
            evidence['remote_source_sha256'] = hashlib.sha256(source.encode()).hexdigest()
            if variant != 'go':
                evidence['metrics_before'] = admin_json(admin, '/debug/metrics')
                evidence['workers_before'] = admin_json(admin, '/debug/workers')
            evidence['server_before'] = proc_sample(server.pid)
            evidence['host_before'] = host_sample()
            if args.profile and variant != 'go':
                perf_command = ['perf', 'record', '-F', '199', '-e', 'cycles:u', '--call-graph', 'dwarf,4096',
                                '-o', str(folder / 'user.perf.data'), '-p', str(server.pid)]
                perf = subprocess.Popen(perf_command, stdout=subprocess.DEVNULL, stderr=log)
                evidence['perf_command'] = perf_command
            arguments = ['-address', f'{args.address}:{port}', '-connections', str(args.connections)]
            if args.schedule:
                arguments += ['-schedule', args.schedule, '-shards', '8', '-queue', '128', '-timeout', '2s',
                              '-method', args.method, '-path', args.path]
                if args.churn:
                    arguments += ['-churn']
            else:
                arguments += ['-warmup', '2s', '-duration', f'{args.duration}s', '-allow-errors']
            files = {flag: Path(path) for flag, path in
                     [('-request-body', args.request_body), ('-expect-body', args.expect_body)] if path}
            start = time.monotonic()
            remote.start(args.client_binary, arguments, cpu_list(getattr(args, 'client_cpus', '0-7')),
                         args.connections, 180, files)
            local_client = Path(getattr(args, 'local_client_binary', BUILD / 'load'))
            assert remote.started['binary_sha256'] == hashlib.sha256(local_client.read_bytes()).hexdigest()
            evidence['remote_started'] = remote.started
            evidence['clock_offset_ns'] = remote.clock_offset_ns
            evidence['clock_uncertainty_ns'] = remote.clock_uncertainty_ns
            next_sample = 0
            while not remote.completed():
                if server.poll() is not None:
                    raise RuntimeError('server exited during load')
                if time.monotonic() - start > 185:
                    raise TimeoutError('load deadline')
                if time.monotonic() >= next_sample:
                    sample = dict(unix_ns=time.time_ns(), server=proc_sample(server.pid), host=host_sample())
                    if variant != 'go':
                        sample['metrics'] = admin_json(admin, '/debug/metrics')
                        sample['workers'] = admin_json(admin, '/debug/workers')
                    evidence['samples'].append(sample)
                    next_sample = time.monotonic() + .5
                time.sleep(.025)
            evidence['elapsed_seconds'] = time.monotonic() - start
            evidence['server_after'] = proc_sample(server.pid)
            evidence['host_after'] = host_sample()
            evidence['load'] = remote.result['client']
            for flag, path in files.items():
                field = 'request_body_sha256' if flag == '-request-body' else 'expected_body_sha256'
                assert evidence['load']['workload'][field] == hashlib.sha256(path.read_bytes()).hexdigest()
            evidence['remote_samples'] = remote.samples
            if variant != 'go':
                evidence['metrics_after'] = admin_json(admin, '/debug/metrics')
                evidence['workers_after'] = admin_json(admin, '/debug/workers')
            if perf:
                perf.send_signal(signal.SIGINT)
                perf.wait(timeout=10)
                if perf.returncode not in (0, -signal.SIGINT):
                    raise RuntimeError(f'perf exited {perf.returncode}')
            evidence['outcome'] = 'measured'
        except BaseException as error:
            evidence['outcome'] = 'failed'
            evidence['error'] = repr(error)
            evidence['remote_failure'] = getattr(remote, 'failure', None)
            raise
        finally:
            if perf and perf.poll() is None:
                perf.send_signal(signal.SIGINT)
                perf.wait(timeout=10)
            if remote:
                remote.stop()
            stop(server)
            if server:
                evidence['server_exit'] = server.returncode
                if server.stdout:
                    server.stdout.close()
            (folder / 'run.json').write_text(json.dumps(evidence, indent=2) + '\n')
    if args.profile:
        if variant != 'go':
            report_command = ['perf', 'report', '--stdio', '--no-children', '-g', 'none', '--sort', 'symbol,dso',
                              '--percent-limit', '.5', '-i', str(folder / 'user.perf.data')]
        else:
            report_command = ['go', 'tool', 'pprof', '-top', '-nodecount=80', str(binary), str(folder / 'go.cpu.pprof')]
        result = subprocess.run(report_command, capture_output=True, text=True, check=True)
        (folder / 'profile.txt').write_text(result.stdout + result.stderr)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--variants', nargs='+', choices=['zig', 'go', 'before'], default=['zig', 'go'])
    parser.add_argument('--connections', type=int, default=8192)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--duration', type=int, default=10)
    parser.add_argument('--schedule', default='')
    parser.add_argument('--workers', type=int, default=16)
    parser.add_argument('--capacity', type=int, default=2048)
    parser.add_argument('--worker-cpus', default='')
    parser.add_argument('--server-cpus', default='')
    parser.add_argument('--completion-budget', type=int, default=64)
    parser.add_argument('--idle-reclaim-ms', type=int,
                        help='Override the binary default; 0 explicitly disables reclamation')
    parser.add_argument('--go-procs', type=int)
    parser.add_argument('--go-binary', default='', help='Use a separately recorded Go executable')
    parser.add_argument('--go-gc-off', action='store_true')
    parser.add_argument('--zig-binary', default=str(BUILD / 'release_safe/bin/zhtps'))
    parser.add_argument('--before-binary', default='', help='Recorded ZHTPS baseline for rotated before/after trials')
    parser.add_argument('--profile', action='store_true')
    parser.add_argument('--method', default='GET')
    parser.add_argument('--path', default='/')
    parser.add_argument('--request-body', default='')
    parser.add_argument('--expect-body', default='')
    parser.add_argument('--churn', action='store_true')
    parser.add_argument('--access-log', action='store_true')
    parser.add_argument('--log-output', choices=['file', 'null'], default='file')
    parser.add_argument('--address', default='192.0.2.10')
    parser.add_argument('--client-host', default='client.example')
    parser.add_argument('--client-cpus', default='0-7', help='Load-host CPU list; runtime parallelism matches its length')
    parser.add_argument('--ssh-config', default='/path/to/benchmark-ssh.conf')
    parser.add_argument('--client-binary', default='/tmp/zhtps-go-comparison-load-20260912')
    parser.add_argument('--local-client-binary', default=str(BUILD / 'load'),
                        help='Local executable whose SHA must match the remote client')
    args = parser.parse_args()
    try:
        client_cpus = cpu_list(args.client_cpus)
        assert client_cpus and len(set(client_cpus)) == len(client_cpus) and min(client_cpus) >= 0
    except (ValueError, AssertionError):
        parser.error('--client-cpus must contain distinct nonnegative CPU IDs or ranges')
    if 'before' in args.variants and not args.before_binary:
        parser.error('--variants before requires --before-binary')
    if not args.schedule and (args.method != 'GET' or args.path != '/' or
                              args.request_body or args.expect_body or args.churn):
        parser.error('custom workloads require --schedule')
    folder = Path(args.output).resolve()
    folder.mkdir(parents=True, exist_ok=False)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 65536), hard))
    sources = [Path(__file__), ROOT/'bench/go_server/main.go', ROOT/'bench/go_server/profile.go',
               ROOT/'bench/remote_load.py', ROOT/'bench/load/main.go', ROOT/'bench/load/offered.go',
               *sorted((ROOT/'src').rglob('*.zig'))]
    manifest = dict(timestamp_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                    command=os.sys.argv, sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                                 for p in sources}, runs=[])
    for repeat in range(args.repeats):
        order = args.variants[repeat % len(args.variants):] + args.variants[:repeat % len(args.variants)]
        for variant in order:
            trial = folder / f'{variant}-{repeat+1}'
            trial.mkdir()
            print(f'Starting {trial.name}', flush=True)
            evidence = run_one(args, variant, repeat+1, trial)
            manifest['runs'].append(str(trial / 'run.json'))
            (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
            load = evidence['load']
            if 'phases' in load:
                for phase in load['phases']:
                    print(variant, phase['offered_rate'], round(phase['window_successes_per_second']),
                          phase['failures'], flush=True)
            else:
                print(variant, round(load['window_successes_per_second']), load['failures'], flush=True)


if __name__ == '__main__':
    main()
