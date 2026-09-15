"""Compare 64 KiB echoes at an offered rate, validating workload identity and kernel counters."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import time

from compare import admin_json, free_port, wait_ready
from overload import core_sample, kernel_sample, proc_sample, stop

ROOT = Path(__file__).resolve().parents[1]
EVENTS = ('cycles:k', 'instructions:k', 'cycles:u', 'instructions:u', 'context-switches', 'cpu-migrations')
CASES = {'echo': dict(connections=64, capacity=256, server_cpus=[2], client_cpus=[4, 5, 6, 7])}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def perf_counts(path):
    counts = {}
    for line in path.read_text().splitlines():
        fields = line.split(';')
        if len(fields) >= 5 and fields[2] in EVENTS:
            counts[fields[2]] = dict(count=float(fields[0]) if not fields[0].startswith('<') else None,
                                    running_percent=float(fields[4]), raw=line)
    if set(counts) != set(EVENTS):
        raise RuntimeError(f'missing counters: {path.read_text()}')
    if any(v['count'] is None or v['running_percent'] < 95 for v in counts.values()):
        raise RuntimeError(f'counter unavailable or multiplexed: {counts}')
    return counts


def thread_switches(pid):
    result = {}
    for task in Path(f'/proc/{pid}/task').iterdir():
        try:
            result[task.name] = {k: int(v) for k, v in
                (line.split(':', 1) for line in (task/'status').read_text().splitlines() if ':' in line)
                if k in ('voluntary_ctxt_switches', 'nonvoluntary_ctxt_switches')}
        except FileNotFoundError:
            pass
    return result


def trial(binary, client, case, options, prefix):
    port, admin_port = free_port(), free_port()
    while port == admin_port:
        admin_port = free_port()
    cpus = case['server_cpus']
    command = ['taskset', '-c', ','.join(map(str, cpus)), str(binary),
               '--port', str(port), '--admin-port', str(admin_port),
               '--workers', str(len(cpus)), '--max-connections', str(case['capacity']),
               '--max-active', str(case['capacity']), '--max-requests', '4294967295', '--no-access-log']
    server = None
    with prefix.with_suffix('.server.log').open('w') as log:
        try:
            server = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log)
            headers = wait_ready(server, port)
            workers_before = admin_json(admin_port, '/debug/workers')
            for worker, cpu in zip(workers_before['workers'], cpus, strict=True):
                os.sched_setaffinity(worker['thread'], [cpu])
            affinity = {str(w['thread']): sorted(os.sched_getaffinity(w['thread'])) for w in workers_before['workers']}
            metrics_before = admin_json(admin_port, '/debug/metrics')
            before = proc_sample(server.pid)
            kernel_before = kernel_sample()
            cores_before = core_sample(range(os.cpu_count()))
            threads_before = thread_switches(server.pid)
            body = prefix.parent / 'echo-body.bin'
            if not body.exists(): body.write_bytes(bytes(range(256))*256)
            load_command = ['taskset','-c',','.join(map(str,case['client_cpus'])),str(client),
                            '-address',f'127.0.0.1:{port}','-connections',str(case['connections']),
                            '-schedule',f'2000:{options.warmup}s,20000:{options.duration}s','-shards','8',
                            '-method','POST','-path','/echo','-request-body',str(body),'-expect-body',str(body)]
            measured_command = ['perf', 'stat', '-x', ';', '-o', str(prefix.with_suffix('.perf')),
                                '-e', ','.join(EVENTS), '-p', str(server.pid), '--', *load_command]
            start = time.monotonic()
            result = subprocess.run(measured_command, capture_output=True, text=True,
                                    env=dict(os.environ, GOMAXPROCS=str(len(case['client_cpus']))),
                                    timeout=options.duration + options.warmup + 90)
            elapsed = time.monotonic() - start
            after = proc_sample(server.pid)
            kernel_after = kernel_sample()
            cores_after = core_sample(range(os.cpu_count()))
            threads_after = thread_switches(server.pid)
            if result.returncode:
                raise RuntimeError(f'load/perf failed: {result.stdout} {result.stderr}')
            load = json.loads(result.stdout)
            prefix.with_suffix('.client.json').write_text(result.stdout)
            assert load['workload']['request_body_sha256'] == digest(body)
            assert load['workload']['expected_body_sha256'] == digest(body)
            assert load['workload']['method'] == 'POST' and load['workload']['path'] == '/echo'
            assert sum(p['connections_opened'] for p in load['phases']) == case['connections']
            for phase in load['phases']:
                assert not phase['failures']
                assert phase['successes'] == phase['sent']
                assert phase['response_bytes_validated'] == phase['successes'] * 65536
            phase = load['phases'][-1]
            assert phase['sent'] >= phase['offered'] * .999
            metrics_after = admin_json(admin_port, '/debug/metrics')
            workers_after = admin_json(admin_port, '/debug/workers')
            deltas = {k: v - metrics_before['counters'][k] for k, v in metrics_after['counters'].items()}
            for key in ('requests_rejected_total', 'requests_aborted_total', 'protocol_errors_total',
                        'request_timeouts_total', 'io_errors_total', 'log_dropped_total'):
                assert deltas[key] == 0, (key, deltas[key])
            completed = deltas['requests_completed_total']
            counts = perf_counts(prefix.with_suffix('.perf'))
            row = dict(server_command=command, client_command=load_command, perf_command=measured_command,
                       worker_affinities=affinity, workers_before=workers_before, workers_after=workers_after,
                       response_headers=headers, load=load, server_before=before, server_after=after,
                       kernel_before=kernel_before, kernel_after=kernel_after,
                       cores_before=cores_before, cores_after=cores_after,
                       threads_before=threads_before, threads_after=threads_after,
                       elapsed_including_setup_seconds=elapsed, counter_deltas=deltas,
                       metrics_before=metrics_before, metrics_after=metrics_after, perf=counts,
                       cpu_ns_per_completed=(after['cpu_seconds'] - before['cpu_seconds']) * 1e9 / completed,
                       user_ns_per_completed=(after['user_seconds'] - before['user_seconds']) * 1e9 / completed,
                       system_ns_per_completed=(after['system_seconds'] - before['system_seconds']) * 1e9 / completed,
                       perf_per_completed={k: v['count'] / completed for k, v in counts.items()})
            prefix.with_suffix('.json').write_text(json.dumps(row, indent=2) + '\n')
            return row
        finally:
            stop(server)
            if server is not None and server.returncode != 0:
                raise RuntimeError(f'server exit {server.returncode}; see {prefix.with_suffix(".server.log")}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('variants', nargs='+')
    parser.add_argument('--workspace', type=Path, default=Path('/tmp/zhtps-kernel-work'))
    parser.add_argument('--records', type=Path, default=ROOT / 'zig-out/bench/kernel-work')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cases', nargs='+', choices=CASES, default=['echo'])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--duration', type=float, default=5)
    parser.add_argument('--warmup', type=float, default=2)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 20 or not 0 < args.duration <= 60 or not 0 < args.warmup <= 30:
        parser.error('require repeats 1..20, duration (0,60], warmup (0,30]')
    if args.output.exists():
        parser.error('choose a new output directory to preserve previous trials')
    args.output.mkdir(parents=True)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 20000), hard))
    client = Path('/tmp/zhtps-kernel-work/load')
    binaries = {name: args.workspace / name / 'out/bin/zhtps' for name in args.variants}
    provenance = {}
    for name, binary in binaries.items():
        record = json.loads((args.records / f'{name}-build.json').read_text())
        tree = binary.parents[2]
        assert digest(binary) == record['binaries']['zhtps']
        assert {str(p.relative_to(tree)): digest(p) for p in sorted((tree/'src').rglob('*.zig'))} == record['sources']
        provenance[name] = record
    report = dict(timestamp_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  options={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                  cases={k: CASES[k] for k in args.cases}, builds=provenance,
                  harness_sha256=digest(Path(__file__)), client_sha256=digest(client),
                  pmu_scope='kernel and user execution charged to server threads, including client setup/warmup/drain; host core/packet counters also include other activity', runs=[])
    for case_name in args.cases:
        case = CASES[case_name]
        assert not set(case['server_cpus']) & set(case['client_cpus'])
        for repeat in range(args.repeats):
            order = args.variants[repeat % len(args.variants):] + args.variants[:repeat % len(args.variants)]
            for name in order:
                print(f'{case_name} {repeat+1}: {name}', flush=True)
                row = trial(binaries[name], client, case, args, args.output/f'{case_name}-{name}-{repeat+1}')
                brief = dict(case=case_name, variant=name, repeat=repeat+1,
                             goodput=row['load']['phases'][-1]['window_successes_per_second'],
                             p99_us=row['load']['phases'][-1]['success_service_latency']['p99_us'], cpu_ns=row['cpu_ns_per_completed'],
                             user_ns=row['user_ns_per_completed'], system_ns=row['system_ns_per_completed'],
                             perf_per_completed=row['perf_per_completed'], rss_bytes=row['server_after']['VmRSS'])
                report['runs'].append(brief)
                (args.output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
                print(json.dumps(brief), flush=True)
    report['medians'] = []
    for case_name in args.cases:
        for name in args.variants:
            group = [r for r in report['runs'] if r['case']==case_name and r['variant']==name]
            report['medians'].append(dict(case=case_name, variant=name,
                **{key: statistics.median(r[key] for r in group) for key in ('goodput','p99_us','cpu_ns','user_ns','system_ns','rss_bytes')},
                goodput_min=min(r['goodput'] for r in group), goodput_max=max(r['goodput'] for r in group),
                perf_per_completed={key: statistics.median(r['perf_per_completed'][key] for r in group) for key in EVENTS}))
    (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['medians'],indent=2),flush=True)


if __name__ == '__main__':
    main()
