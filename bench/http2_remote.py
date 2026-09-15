"""Remote HTTP/2 client supervisor; standard library only, JSON control over SSH."""

import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import resource
import signal
import subprocess
import sys
import threading
import time


class MissedPackets:
    """Retain short-interval raw NIC counters; do not guess how many times they wrap."""

    def __init__(self, path):
        self.path = Path(path)
        self.paths = {nic.name: nic / 'statistics/rx_missed_errors'
                      for nic in Path('/sys/class/net').iterdir()
                      if (nic / 'device').exists() and (nic / 'operstate').read_text().strip() == 'up'}
        self.done = threading.Event()
        self.rows = []
        self.thread = threading.Thread(target=self.sample)
        self.thread.start()

    def sample(self):
        while not self.done.is_set():
            row = {'started_ns': time.time_ns()}
            try:
                row['counters'] = {name: int(path.read_text()) for name, path in self.paths.items()}
            except OSError as error:
                row['error'] = repr(error)
            row['finished_ns'] = time.time_ns()
            self.rows.append(row)
            self.done.wait(.005)

    def close(self):
        self.done.set()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise RuntimeError('NIC sampler did not stop')
        with self.path.open('w') as output:
            for row in self.rows:
                output.write(json.dumps(row, separators=(',', ':')) + '\n')


def diagnostic_sample():
    started = time.time_ns()
    command = ['tc', '-s', '-j', 'qdisc', 'show']
    result = subprocess.run(command, capture_output=True, text=True, timeout=5)
    return {'started_ns': started, 'finished_ns': time.time_ns(),
            'qdisc_exit': result.returncode, 'qdisc_stderr': result.stderr,
            'qdiscs': json.loads(result.stdout) if result.returncode == 0 else [],
            'softnet': Path('/proc/net/softnet_stat').read_text(),
            'interrupts': Path('/proc/interrupts').read_text(),
            'stat': Path('/proc/stat').read_text()}


def identity():
    cpus = sorted(os.sched_getaffinity(0))
    topology = {}
    for cpu in cpus:
        folder = Path(f'/sys/devices/system/cpu/cpu{cpu}/topology')
        topology[str(cpu)] = [int((folder / name).read_text()) for name in
                              ('physical_package_id', 'core_id')]
    return {'hostname': platform.node(), 'kernel': platform.release(), 'machine': platform.machine(),
            'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'cpu': next(line.split(':', 1)[1].strip() for line in
                        Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),
            'allowed_cpus': cpus, 'topology': topology,
            'file_limit': list(resource.getrlimit(resource.RLIMIT_NOFILE)),
            'memory': Path('/proc/meminfo').read_text(),
            'port_range': Path('/proc/sys/net/ipv4/ip_local_port_range').read_text().strip()}


def host_sample():
    nics = {}
    for nic in Path('/sys/class/net').iterdir():
        if not (nic / 'device').exists():
            continue
        values = {p.name: int(p.read_text()) for p in (nic / 'statistics').iterdir()}
        for name in ('speed', 'duplex', 'mtu'):
            try:
                values[name] = (nic / name).read_text().strip()
            except OSError:
                pass
        nics[nic.name] = values
    return {'unix_ns': time.time_ns(), 'nics': nics,
            **({'diagnostic': diagnostic_sample()} if globals().get('diagnostics', False) else {}),
            'tcp': Path('/proc/net/snmp').read_text(), 'netstat': Path('/proc/net/netstat').read_text()}


def emit(kind, **values):
    print(json.dumps({'kind': kind, **values}, separators=(',', ':')), flush=True)


def run():
    if '--identity' in sys.argv:
        emit('identity', identity=identity(), host=host_sample())
        return
    emit('hello', identity=identity())
    while True:
        message = json.loads(sys.stdin.readline())
        if message['kind'] == 'clock':
            emit('clock', unix_ns=time.time_ns())
        elif message['kind'] == 'run':
            config = message
            break
        else:
            raise ValueError('unsupported initial command')
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, max(soft, 65536)), hard))
    folder = Path(config['folder'])
    globals()['diagnostics'] = config.get('diagnostics', False)
    folder.mkdir(exist_ok=False)
    binary = Path(config['binary'])
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    if digest != config['binary_sha256']:
        raise ValueError('client executable hash mismatch')
    cpus = config['client_cpus']
    if not set(cpus) <= os.sched_getaffinity(0):
        raise ValueError('unavailable client CPUs')
    processes = config['client_processes']
    placements = [cpus[i::processes] for i in range(processes)]
    if any(not placement for placement in placements):
        raise ValueError('empty client CPU placement')
    events = queue.Queue()
    cancelled = threading.Event()
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: cancelled.set())
    last_contact = [time.monotonic()]
    def controls():
        for line in sys.stdin:
            last_contact[0] = time.monotonic()
            event = json.loads(line)
            if event['kind'] != 'heartbeat':
                events.put(('control', 0, event))
        cancelled.set()
    threading.Thread(target=controls, daemon=True).start()
    clients, handles, commands = [], [], []
    missed = None
    def collect(index, process):
        try:
            for line in process.stdout:
                events.put(('client', index, json.loads(line)))
            events.put(('exit', index, process.wait()))
        except BaseException as error:
            events.put(('invalid', index, repr(error)))
    try:
        if config.get('sample_missed', False):
            missed = MissedPackets(folder / 'nic-missed.jsonl')
        for i, placement in enumerate(placements):
            connections = config['connections'] // processes + (i < config['connections'] % processes)
            command = ['taskset', '-c', ','.join(map(str, placement)), str(binary),
                       '-url', config['url'], '-ca', config['certificate'],
                       '-connections', str(connections), '-streams', str(config['streams']),
                       '-duration', f"{config['duration']}s", '-warmup', f"{config['warmup']}s",
                       '-timeout', f"{config['timeout']}s", '-setup-deadline', f"{config['setup_deadline']}s",
                       '-setup-concurrency', str(config['setup_concurrency']),
                       '-failures', str(folder / f'client-{i}.failures.jsonl'), '-synchronize']
            command.extend(config.get('client_args', []))
            logs = (folder / f'client-{i}.stderr.log').open('w')
            handles.append(logs)
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=logs, env={**os.environ, 'GOMAXPROCS': str(len(placement))})
            clients.append(process)
            commands.append(command)
            threading.Thread(target=collect, args=(i, process), daemon=True).start()
        emit('launched', binary_sha256=digest, commands=commands, placements=placements,
             pids=[process.pid for process in clients], host=host_sample())
        prepared, ready, measured, results, exited = {}, {}, {}, {}, {}
        deadline = time.monotonic() + config['max_seconds']
        last_sample = 0
        while len(exited) < len(clients):
            if cancelled.is_set() or time.monotonic() - last_contact[0] > 20:
                raise RuntimeError('controller disconnected')
            if time.monotonic() > deadline:
                raise TimeoutError('remote trial deadline')
            try:
                kind, index, value = events.get(timeout=.2)
            except queue.Empty:
                kind = None
            if kind == 'client':
                phase = value['phase']
                if phase == 'prepared':
                    prepared[index] = value
                    if len(prepared) == len(clients):
                        emit('prepared', clients=[prepared[i] for i in range(len(clients))])
                elif phase == 'ready':
                    ready[index] = value
                    if len(ready) == len(clients):
                        emit('ready', clients=[ready[i] for i in range(len(clients))])
                elif phase == 'measured':
                    measured[index] = value
                    if len(measured) == len(clients):
                        emit('measured', clients=[measured[i] for i in range(len(clients))])
                elif phase == 'result':
                    results[index] = value
                    (folder / f'client-{index}.json').write_text(json.dumps(value, indent=2) + '\n')
                else:
                    raise ValueError(f'unknown client phase {phase}')
            elif kind == 'control':
                phase = value['kind']
                if not ((phase == 'warmup' and len(prepared) == len(clients)) or
                        (phase == 'measure' and len(ready) == len(clients))):
                    raise ValueError('load requested before clients ready')
                start_ns = time.time_ns() + 500_000_000
                for process in clients:
                    process.stdin.write(f'{start_ns}\n'.encode())
                    process.stdin.flush()
                emit('scheduled' if phase == 'measure' else 'warmup_scheduled', start_ns=start_ns)
            elif kind == 'exit':
                exited[index] = value
                if value != 0 or index not in results:
                    raise RuntimeError(f'client {index} exited {value} without a complete result')
            elif kind == 'invalid':
                raise RuntimeError(f'client {index}: {value}')
            if time.monotonic() - last_sample >= 1:
                samples = []
                for process in clients:
                    try:
                        fields = Path(f'/proc/{process.pid}/stat').read_text().rsplit(')', 1)[1].split()
                        samples.append({'pid': process.pid,
                                        'cpu_seconds': (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
                                        'rss_bytes': int(fields[21]) * os.sysconf('SC_PAGE_SIZE')})
                    except (FileNotFoundError, ProcessLookupError):
                        pass
                emit('sample', unix_ns=time.time_ns(), clients=samples)
                last_sample = time.monotonic()
        failures = []
        for i in range(len(clients)):
            path = folder / f'client-{i}.failures.jsonl'
            compressed = path.with_suffix('.jsonl.gz')
            digest = hashlib.sha256()
            count = 0
            with path.open('rb') as source, gzip.open(compressed, 'wb', compresslevel=6) as output:
                for line in source:
                    digest.update(line)
                    count += 1
                    output.write(line)
            if count != results[i]['failure_log_entries']:
                raise ValueError('failure log count mismatch')
            failures.append({'path': compressed.name, 'entries': count, 'sha256_uncompressed': digest.hexdigest()})
            path.unlink()
        emit('result', shards=[results[i] for i in range(len(clients))], exit_codes=exited,
             failure_logs=failures, host=host_sample())
    except BaseException as error:
        emit('error', error=repr(error))
        raise
    finally:
        for process in clients:
            if process.poll() is None:
                process.terminate()
        for process in clients:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for handle in handles:
            handle.close()
        if missed:
            missed.close()


if __name__ == '__main__':
    run()
