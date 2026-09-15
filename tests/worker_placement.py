"""Exercise worker affinity on live event-loop threads and inherited restrictions."""

import json
import os
import subprocess
import unittest

from wire import BINARY, Client, Running


class WorkerPlacementTests(unittest.TestCase):
    def test_ordered_mapping_pins_each_worker_and_serves_requests(self):
        cpus = sorted(os.sched_getaffinity(0))[:2][::-1]
        with Running('--workers', str(len(cpus)), '--worker-cpus', ','.join(map(str, cpus))) as server:
            with Client(server.port) as client:
                client.send(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                self.assertEqual(client.response()[::2], (200, b'ZHTPS\n'))
            with Client(server.admin_port) as admin:
                admin.send(b'GET /debug/workers HTTP/1.1\r\nHost: localhost\r\n\r\n')
                workers = json.loads(admin.response()[2])['workers']
            self.assertEqual([worker['cpu'] for worker in workers], cpus)
            for worker, cpu in zip(workers, cpus):
                self.assertEqual(os.sched_getaffinity(worker['thread']), {cpu})

    def test_default_preserves_inherited_affinity(self):
        with Running('--workers', '2') as server, Client(server.admin_port) as admin:
            admin.send(b'GET /debug/workers HTTP/1.1\r\nHost: localhost\r\n\r\n')
            for worker in json.loads(admin.response()[2])['workers']:
                self.assertIsNone(worker['cpu'])
                self.assertEqual(os.sched_getaffinity(worker['thread']), os.sched_getaffinity(0))

    def test_mapping_cannot_escape_inherited_affinity_or_report_readiness(self):
        cpus = sorted(os.sched_getaffinity(0))
        if len(cpus) < 2:
            self.skipTest('needs two allowed CPUs')
        result = subprocess.run(
            ['taskset', '-c', str(cpus[0]), BINARY, '--port', '0', '--admin-port', '0',
             '--workers', '2', '--worker-cpus', ','.join(map(str, cpus[:2]))],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        events = [json.loads(line) for line in result.stderr.splitlines()]
        self.assertFalse(any(event['event'] in ('listening', 'admin_listening') for event in events))
        self.assertTrue(any(event.get('reason') == 'CpuUnavailable' for event in events))


if __name__ == '__main__':
    unittest.main(verbosity=2)
