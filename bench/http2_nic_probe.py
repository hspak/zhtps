"""Read NIC identity, queue affinity, rings and pause settings without ethtool installed."""

import ctypes
import fcntl
import json
from pathlib import Path
import socket
import struct
import time


def probe():
    result = {'unix_ns': time.time_ns(), 'hostname': socket.gethostname(), 'interfaces': {}}
    for nic in Path('/sys/class/net').iterdir():
        if not (nic / 'device').exists() or (nic / 'operstate').read_text().strip() != 'up':
            continue
        row = {'driver': (nic / 'device/driver').resolve().name,
               'vendor': (nic / 'device/vendor').read_text().strip(),
               'device': (nic / 'device/device').read_text().strip(),
               'queues': {}, 'irqs': {}}
        for name in ('speed', 'duplex', 'carrier_changes', 'carrier_up_count', 'carrier_down_count'):
            try:
                row[name] = (nic / name).read_text().strip()
            except OSError as error:
                row[name] = repr(error)
        for path in (nic / 'queues').glob('*/*'):
            if path.name in ('rps_cpus', 'rps_flow_cnt', 'xps_cpus', 'xps_rxqs'):
                try:
                    row['queues'][str(path.relative_to(nic))] = path.read_text().strip()
                except OSError as error:
                    row['queues'][str(path.relative_to(nic))] = repr(error)
        for irq in (nic / 'device/msi_irqs').iterdir():
            row['irqs'][irq.name] = Path('/proc/irq', irq.name, 'effective_affinity_list').read_text().strip()
        for name, cmd, fields in (
            ('rings', 0x10, ['rx_max', 'rx_mini_max', 'rx_jumbo_max', 'tx_max',
                            'rx_pending', 'rx_mini_pending', 'rx_jumbo_pending', 'tx_pending']),
            ('pause', 0x12, ['autoneg', 'rx_pause', 'tx_pause']),
        ):
            buffer = ctypes.create_string_buffer(struct.pack('=' + 'I' * (len(fields) + 1),
                                                              cmd, *([0] * len(fields))))
            request = struct.pack('16sP16x', nic.name.encode(), ctypes.addressof(buffer))
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as control:
                    fcntl.ioctl(control.fileno(), 0x8946, request)
                row[name] = dict(zip(fields, struct.unpack_from('=' + 'I' * len(fields), buffer.raw, 4)))
            except OSError as error:
                row[name] = {'error': repr(error)}
        result['interfaces'][nic.name] = row
    return result


if __name__ == '__main__':
    print(json.dumps(probe(), indent=2))
