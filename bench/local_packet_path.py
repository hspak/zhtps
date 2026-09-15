"""Run local traffic across a veth pair in temporary user/network namespaces."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def run(command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--probe-binary', type=Path)
    parser.add_argument('--probe-mode', default='recv')
    parser.add_argument('--probe-size', type=int, default=64)
    parser.add_argument('--probe-iterations', type=int, default=100000)
    parser.add_argument('--case', choices=('small', 'echo'), default='small')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--schedule', default='50000:2s,100000:6s,200000:6s')
    parser.add_argument('--connections', type=int, default=64)
    parser.add_argument('--client-cpus', default='4-7')
    parser.add_argument('--server-cpus', default='2')
    parser.add_argument('--workers', type=int, default=1)
    parser.add_argument('--gro', choices=('on', 'off'), default='on')
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if (args.binary is None) == (args.probe_binary is None):
        parser.error('choose exactly one of --binary and --probe-binary')
    if not args.inside:
        os.execvp('unshare', ['unshare', '--user', '--map-root-user', '--net',
                             sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], '--inside'])
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    child = subprocess.Popen(['unshare', '--net', sys.executable, '-c', 'import signal; signal.pause()'])
    try:
        parent_ns = os.readlink('/proc/self/ns/net')
        deadline = time.monotonic() + 5
        while os.readlink(f'/proc/{child.pid}/ns/net') == parent_ns:
            if child.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('client network namespace did not start')
            time.sleep(.01)
        run(['ip', 'link', 'set', 'lo', 'up'])
        run(['ip', 'link', 'add', 'zpserver', 'type', 'veth', 'peer', 'name', 'zpclient'])
        run(['ip', 'link', 'set', 'zpclient', 'netns', str(child.pid)])
        run(['ip', 'address', 'add', '10.203.0.1/30', 'dev', 'zpserver'])
        run(['ip', 'link', 'set', 'zpserver', 'up'])
        enter = ['nsenter', '--target', str(child.pid), '--net']
        for command in (['ip', 'link', 'set', 'lo', 'up'],
                        ['ip', 'address', 'add', '10.203.0.2/30', 'dev', 'zpclient'],
                        ['ip', 'link', 'set', 'zpclient', 'up']):
            run([*enter, *command])
        run(['ethtool', '-K', 'zpserver', 'gro', args.gro])
        run([*enter, 'ethtool', '-K', 'zpclient', 'gro', args.gro])
        network = {'physical_network': False, 'shared_kernel': True,
                   'server_namespace': parent_ns, 'client_namespace': os.readlink(f'/proc/{child.pid}/ns/net'),
                   'server_link': json.loads(run(['ip', '-j', '-s', 'link', 'show', 'zpserver'])),
                   'client_link': json.loads(run([*enter, 'ip', '-j', '-s', 'link', 'show', 'zpclient'])),
                   'server_offloads': run(['ethtool', '-k', 'zpserver']),
                   'client_offloads': run([*enter, 'ethtool', '-k', 'zpclient'])}
        if args.probe_binary:
            command = [str(args.probe_binary.resolve()), args.probe_mode, str(args.probe_size),
                       str(args.probe_iterations), '10.203.0.1', str(child.pid)]
        else:
            command = [sys.executable, str(ROOT/'bench/overload.py'), '--server-binary', str(args.binary.resolve()),
                       '--output', str(args.output), '--server-address', '10.203.0.1', '--server-cpus', args.server_cpus,
                       '--workers', str(args.workers),
                       '--client-cpus', args.client_cpus, '--client-netns-pid', str(child.pid),
                       '--connections', str(args.connections), '--max-connections', '256', '--max-active', '256',
                       '--schedule', args.schedule]
            if args.case == 'echo':
                body = args.output.with_suffix('.body')
                body.write_bytes(bytes(range(256)) * 256)
                command += ['--method', 'POST', '--path', '/echo', '--request-body', str(body), '--expect-body', str(body)]
        network['command'] = command
        if args.probe_binary:
            result = subprocess.run(command, check=True, cwd=ROOT, capture_output=True, text=True, timeout=50)
            args.output.write_text(json.dumps(json.loads(result.stdout), indent=2) + '\n')
        else:
            subprocess.run(command, check=True, cwd=ROOT)
        network['server_link_after'] = json.loads(run(['ip', '-j', '-s', 'link', 'show', 'zpserver']))
        network['client_link_after'] = json.loads(run([*enter, 'ip', '-j', '-s', 'link', 'show', 'zpclient']))
        args.output.with_suffix('.network.json').write_text(json.dumps(network, indent=2)+'\n')
    finally:
        if child.poll() is None:
            child.send_signal(signal.SIGTERM)
        child.wait(timeout=5)
        # Exiting the parent namespace removes both ends; host interfaces are untouched.


if __name__ == '__main__':
    main()
