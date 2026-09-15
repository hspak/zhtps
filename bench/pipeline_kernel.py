"""Measure the actual server with validated pipeline and fragmented-write loads."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import time

from overload import get_json, kernel_sample, proc_sample, core_sample, stop
from compare_kernel import EVENTS, perf_counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--max-active', type=int, default=192)
    parser.add_argument('--depth', type=int, default=1)
    parser.add_argument('--fragment', type=int, default=0)
    parser.add_argument('--user-perf', action='store_true', help='omit kernel PMU events when profiling is restricted')
    args = parser.parse_args()
    events = tuple(event for event in EVENTS if event.endswith(':u')) if args.user_perf else EVENTS
    os.sched_setaffinity(0, {0})
    if args.output.exists(): parser.error("use a fresh output path")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = ['taskset', '-c', '2', str(args.binary), '--port', '0', '--admin-port', '0',
               '--no-access-log', '--max-connections', str(max(256,args.max_active)), '--max-active', str(args.max_active), '--max-requests', '4294967295']
    admin = None
    with args.output.with_suffix('.log').open('w+') as log:
        server = subprocess.Popen(command, stderr=log, stdout=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10; ports = {}
            while len(ports) < 2:
                log.seek(0)
                for line in log:
                    event = json.loads(line)
                    if event.get('event') in ('listening', 'admin_listening'): ports[event['event']] = event['port']
                if server.poll() is not None or time.monotonic() > deadline: raise RuntimeError('startup')
                time.sleep(.01)
            client = ['taskset', '-c', '4-7', '/tmp/zhtps-pipeline', '-address', f"127.0.0.1:{ports['listening']}",
                      '-connections', '64', '-depth', str(args.depth), '-fragment', str(args.fragment)]
            env = dict(os.environ, GOMAXPROCS='4')
            subprocess.run([*client, '-duration', '1s'], env=env, check=True, capture_output=True, timeout=10)
            admin = http.client.HTTPConnection('127.0.0.1', ports['admin_listening'], timeout=2)
            metrics_before = get_json(admin, '/debug/metrics'); before = proc_sample(server.pid); kernel_before = kernel_sample(); cores_before = core_sample(range(os.cpu_count()))
            perf_command = ['perf','stat','-x',';','-o',str(args.output.with_suffix('.perf')),'-e',','.join(events),'-p',str(server.pid),'--',*client,'-duration','5s']
            run = subprocess.run(perf_command, env=env, check=True, capture_output=True, text=True, timeout=15)
            after = proc_sample(server.pid); kernel_after = kernel_sample(); cores_after = core_sample(range(os.cpu_count())); metrics_after = get_json(admin, '/debug/metrics')
            workload = json.loads(run.stdout)
            deltas = {k: v-metrics_before['counters'][k] for k,v in metrics_after['counters'].items()}
            for key in ('requests_rejected_total','requests_aborted_total','protocol_errors_total','request_timeouts_total','io_errors_total'): assert deltas[key] == 0,(key,deltas[key])
            assert not workload['failures'] and workload['validated_responses'] > 0
            counts = perf_counts(args.output.with_suffix('.perf'), events)
            completed = deltas['requests_completed_total']
            result = {'counter_deltas':deltas,'perf':counts,'perf_command':perf_command,
                      'cores_before':cores_before,'cores_after':cores_after,
                      'perf_per_completed':{k:v['count']/completed for k,v in counts.items()},'server_command': command, 'client_command': client, 'workload': workload,
                      'before': before, 'after': after, 'kernel_before': kernel_before, 'kernel_after': kernel_after,
                      'metrics_before': metrics_before, 'metrics_after': metrics_after,
                      'server_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                      'client_sha256': hashlib.sha256(Path('/tmp/zhtps-pipeline').read_bytes()).hexdigest(),
                      'cpu_ns_per_response': (after['cpu_seconds'] - before['cpu_seconds']) * 1e9 / completed}
        finally:
            if admin is not None: admin.close()
            stop(server)
    result['server_exit'] = server.returncode
    assert server.returncode == 0, server.returncode
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'output': str(args.output), 'cpu_ns_per_response': result['cpu_ns_per_response'], **workload}), flush=True)


if __name__ == '__main__': main()
