"""Compare admission under a full set of idle keepalives on the second host."""

import argparse
import hashlib
import json
from pathlib import Path
import queue
import resource
import shlex
import subprocess
import threading

from architecture import host_sample
from compare import admin_json, free_port, wait_ready
from overload import proc_sample, stop
from remote_load import identity


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--connections', type=int, default=1024)
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, args.connections + 256), hard))
    args.output.mkdir(exist_ok=False, parents=True)
    variants = {'before': args.before.resolve(), 'candidate': args.candidate.resolve()}
    hashes = {name: hashlib.sha256(p.read_bytes()).hexdigest() for name, p in variants.items()}
    assert len(set(hashes.values())) == 2
    source = (ROOT / 'bench/idle_pressure_client.py').read_text()
    for repeat in range(args.repeats):
        order = list(variants)
        order = order[repeat % 2:] + order[:repeat % 2]
        for name in order:
            folder = args.output / f'{name}-{repeat + 1}'
            folder.mkdir()
            port, admin = free_port('192.0.2.10'), free_port()
            command = [str(variants[name]), '--address', '192.0.2.10', '--port', str(port),
                       '--admin-port', str(admin), '--workers', '1', '--worker-cpus', '9',
                       '--max-connections', str(args.connections), '--max-active', str(args.connections),
                       '--idle-timeout-ms', '60000', '--no-access-log']
            if name == 'candidate':
                command += ['--idle-reclaim-ms', '50']
            record = dict(variant=name, repeat=repeat + 1, command=command,
                           binary_sha256=hashes[name], server_identity=identity(),
                           client_source_sha256=hashlib.sha256(source.encode()).hexdigest())
            server = remote = None
            with (folder / 'server.log').open('w') as log, (folder / 'ssh.log').open('w') as sshlog:
                try:
                    server = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log)
                    wait_ready(server, port, '192.0.2.10')
                    record['running_binary_sha256'] = hashlib.sha256(
                        Path(f'/proc/{server.pid}/exe').read_bytes()).hexdigest()
                    assert record['running_binary_sha256'] == hashes[name]
                    remote = subprocess.Popen(
                        ['ssh', '-F', '/path/to/benchmark-ssh.conf', '-T', 'client.example',
                         shlex.join(['python3', '-u', '-c', source])],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sshlog, text=True)
                    events = queue.Queue()

                    def read_events():
                        try:
                            for line in remote.stdout:
                                events.put(json.loads(line))
                        finally:
                            events.put(None)

                    reader = threading.Thread(target=read_events, daemon=True)
                    reader.start()

                    def send(message):
                        remote.stdin.write(json.dumps(message) + '\n')
                        remote.stdin.flush()

                    def receive(kind):
                        result = events.get(timeout=30)
                        assert result is not None and result['kind'] == kind, result
                        return result

                    send({'address': '192.0.2.10', 'port': port,
                          'connections': args.connections, 'requests': 128})
                    record['remote_identity'] = receive('hello')
                    assert record['remote_identity']['boot_id'] != record['server_identity']['boot_id']
                    record['setup'] = receive('ready')
                    record['metrics_before'] = admin_json(admin, '/debug/metrics')
                    record['server_before'] = proc_sample(server.pid)
                    record['host_before'] = host_sample()
                    send({'kind': 'go'})
                    record['load'] = receive('result')
                    record['server_after'] = proc_sample(server.pid)
                    record['host_after'] = host_sample()
                    record['metrics_after'] = admin_json(admin, '/debug/metrics')
                    send({'kind': 'finish'})
                    remote.wait(timeout=5)
                    assert remote.returncode == 0
                    record['outcome'] = 'measured'
                except BaseException as error:
                    record['outcome'] = 'failed'
                    record['error'] = repr(error)
                    raise
                finally:
                    if remote is not None:
                        if remote.poll() is None:
                            remote.terminate()
                            remote.wait(timeout=5)
                        remote.stdin.close()
                        remote.stdout.close()
                    stop(server)
                    record['server_exit'] = None if server is None else server.returncode
                    (folder / 'run.json').write_text(json.dumps(record, indent=2) + '\n')
            print(name, repeat + 1, {key: value for key, value in record['load'].items()
                                     if key != 'outcomes'}, flush=True)


if __name__ == '__main__':
    main()
