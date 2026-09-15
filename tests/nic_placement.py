"""Check NIC placement against synthetic sysfs topologies."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('worker_cpus', Path(__file__).resolve().parents[1] / 'deploy/worker_cpus.py')
placement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(placement)


class NicPlacementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sysfs = self.root / 'sys'
        self.procfs = self.root / 'proc'
        self.write('sys/devices/system/cpu/online', '0-7')
        self.write('sys/class/net/eth0/device/msi_irqs/40', '')
        self.write('proc/irq/40/effective_affinity_list', '4')
        for cpu in range(8):
            self.write(f'sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list', f'{cpu % 4},{cpu % 4 + 4}')
            self.write(f'sys/devices/system/cpu/cpu{cpu}/cache/index3/level', '3')
            self.write(f'sys/devices/system/cpu/cpu{cpu}/cache/index3/shared_cpu_list', '0-1,4-5' if cpu % 4 < 2 else '2-3,6-7')

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def suggest(self, workers=1, allowed=range(8)):
        return placement.suggest('eth0', workers, allowed, self.sysfs, self.procfs)

    def test_uses_same_l3_and_excludes_entire_irq_core(self):
        result = self.suggest()
        self.assertEqual(result['worker_cpus'], [1])
        self.assertEqual(result['excluded_irq_siblings'], [0, 4])

    def test_respects_restricted_mask_and_online_cpus(self):
        self.assertEqual(self.suggest(allowed={5})['worker_cpus'], [5])
        self.write('sys/devices/system/cpu/online', '0-4,6-7')
        with self.assertRaisesRegex(ValueError, 'only 0'):
            self.suggest(allowed={5})

    def test_does_not_fill_shortage_with_smt_or_remote_l3(self):
        with self.assertRaisesRegex(ValueError, 'only 1'):
            self.suggest(workers=2)

    def test_spreads_multiple_irq_domains_and_supports_legacy_irq(self):
        self.write('sys/class/net/eth0/device/msi_irqs/41', '')
        self.write('proc/irq/41/effective_affinity_list', '6')
        self.assertEqual(self.suggest(workers=2)['worker_cpus'], [1, 3])
        for irq in (40, 41):
            (self.sysfs / f'class/net/eth0/device/msi_irqs/{irq}').unlink()
        self.write('sys/class/net/eth0/device/irq', '40')
        self.assertEqual(self.suggest()['worker_cpus'], [1])

    def test_refuses_unknown_processing_or_cache_topology(self):
        self.write('sys/class/net/eth0/queues/rx-0/rps_cpus', '00000001')
        with self.assertRaisesRegex(ValueError, 'RPS is enabled'):
            self.suggest()
        self.write('sys/class/net/eth0/queues/rx-0/rps_cpus', '0')
        self.write('sys/devices/system/cpu/cpu4/cache/index3/level', '2')
        with self.assertRaisesRegex(ValueError, 'no exposed L3'):
            self.suggest()

    def test_launcher_preserves_arguments_without_a_shell(self):
        result = self.suggest()
        arguments = ['--', '--address', '192.0.2.1', '--log-slots', '16']
        command = placement.launch_arguments(result, '/tmp/server with spaces', arguments)
        self.assertEqual(command, ['/tmp/server with spaces', '--workers', '1',
                                   '--worker-cpus', '1', '--address', '192.0.2.1',
                                   '--log-slots', '16'])
        for option in ['--workers', '--workers=2', '--worker-cpus', '--worker-cpus=3']:
            with self.assertRaisesRegex(ValueError, 'mapping comes from NIC topology'):
                placement.launch_arguments(result, 'zhtps', [option])

    def test_launch_mode_executes_the_discovered_mapping(self):
        result = self.suggest()
        argv = ['worker_cpus.py', '--interface', 'eth0', '--workers', '1',
                '--exec', '/tmp/zhtps', '--', '--port', '8081']
        with mock.patch('sys.argv', argv), mock.patch.object(placement, 'suggest', return_value=result), \
                mock.patch.object(placement.os, 'execvp', side_effect=SystemExit(0)) as execute:
            with self.assertRaises(SystemExit) as stopped:
                placement.main()
        self.assertEqual(stopped.exception.code, 0)
        execute.assert_called_once_with('/tmp/zhtps', ['/tmp/zhtps', '--workers', '1',
                                                     '--worker-cpus', '1', '--port', '8081'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
