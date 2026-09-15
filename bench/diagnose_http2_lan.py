"""Run separate HTTP/2 trials with bounded paired TCP observations and queue counters."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tarfile

import compare_http2_lan as base
import http2_remote


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--capture-limit', type=int, default=32)
    parser.add_argument('--sample-missed', action='store_true')
    wrapper, arguments = parser.parse_known_args()
    if wrapper.capture_limit < 0:
        parser.error('capture limit must be nonnegative')
    observer_path = base.ROOT / 'docs/server-timeout-correlation/socket_observer.py'
    spec = importlib.util.spec_from_file_location('socket_observer', observer_path)
    observer_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(observer_module)
    original_trial = base.trial
    original_send = base.Remote.send
    original_sample = base.host_sample
    active = {}

    def send(self, message):
        if message['kind'] == 'run':
            message['diagnostics'] = True
            message['sample_missed'] = wrapper.sample_missed
            if wrapper.capture_limit:
                message['client_args'] = ['-diagnostic-observer', active['observer'].address,
                                          '-diagnostic-limit', str(wrapper.capture_limit)]
        return original_send(self, message)

    def sample():
        return {**original_sample(), 'diagnostic': http2_remote.diagnostic_sample()}

    def trial(args, ssh, remote_dir, name, workers, connections, repeat, port, cert, key, folder):
        # The ordinary runner owns folder creation and all server/client cleanup.
        log = folder.parent / (folder.name + '.server-sockets.jsonl')
        observer = observer_module.Observer(args.address, log,
                                            limit=wrapper.capture_limit * args.client_processes)
        observer.server_port = port
        active['observer'] = observer
        missed_path = folder.parent / (folder.name + '.nic-missed.jsonl')
        missed = http2_remote.MissedPackets(missed_path) if wrapper.sample_missed else None
        try:
            return original_trial(args, ssh, remote_dir, name, workers, connections, repeat,
                                  port, cert, key, folder)
        finally:
            observer.close()
            if missed:
                missed.close()
                missed_path.rename(folder / 'server-nic-missed.jsonl')
            log.rename(folder / 'server-sockets.jsonl')
            (folder / 'diagnostic.json').write_text(json.dumps({
                'capture_limit_per_process': wrapper.capture_limit,
                'sample_missed': wrapper.sample_missed,
                'captured_server_records': len(observer.records),
                'observer_sha256': base.digest(observer_path),
                'wrapper_sha256': base.digest(__file__),
                'scope': 'First unique measured timeout connections per process; throughput is diagnostic only.',
            }, indent=2) + '\n')
            sources = [Path(__file__), observer_path, base.ROOT / 'bench/http2_remote.py',
                       *sorted((base.ROOT / 'bench/http2_lan_client').glob('*'))]
            with tarfile.open(folder / 'diagnostic-source.tar.gz', 'w:gz') as archive:
                for path in sources:
                    if path.is_file():
                        archive.add(path, arcname=str(path.relative_to(base.ROOT)))

    base.Remote.send = send
    base.host_sample = sample
    base.trial = trial
    sys.argv = [str(base.ROOT / 'bench/compare_http2_lan.py'), *arguments]
    base.main()


if __name__ == '__main__':
    main()
