#!/usr/bin/env python3
"""Choose worker CPUs from current NIC topology and optionally launch the server."""

import argparse
import json
import os
from pathlib import Path
import re


def cpu_list(text):
    cpus = set()
    for part in text.strip().split(','):
        if not part:
            continue
        ends = part.split('-')
        if len(ends) == 1:
            cpus.add(int(ends[0]))
        elif len(ends) == 2 and int(ends[0]) <= int(ends[1]):
            cpus.update(range(int(ends[0]), int(ends[1]) + 1))
        else:
            raise ValueError(f'invalid CPU list: {text!r}')
    return cpus


def suggest(interface, workers, allowed, sysfs=Path('/sys'), procfs=Path('/proc')):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.:-]*', interface):
        raise ValueError('invalid interface name')
    if not 1 <= workers <= 256:
        raise ValueError('workers must be between 1 and 256')
    nic = sysfs / 'class/net' / interface
    if not nic.is_dir():
        raise ValueError(f'interface {interface} does not exist')
    for queue in (nic / 'queues').glob('rx-*'):
        rps = queue / 'rps_cpus'
        if rps.exists() and int(rps.read_text().strip().replace(',', ''), 16):
            raise ValueError('RPS is enabled; measure its processing CPUs before choosing an explicit mapping')
    irqs = sorted(int(path.name) for path in (nic / 'device/msi_irqs').glob('*'))
    if not irqs:
        irq_file = nic / 'device/irq'
        if irq_file.exists() and int(irq_file.read_text()) > 0:
            irqs = [int(irq_file.read_text())]
    if not irqs:
        raise ValueError('no physical NIC IRQs found; use an explicit mapping for virtual interfaces')
    cpu_root = sysfs / 'devices/system/cpu'
    online = cpu_list((cpu_root / 'online').read_text())
    effective = {}
    for irq in irqs:
        effective[str(irq)] = sorted(cpu_list((procfs / f'irq/{irq}/effective_affinity_list').read_text()) & online)
        if not effective[str(irq)]:
            raise ValueError(f'IRQ {irq} has no effective online CPU')
    irq_cpus = set().union(*(set(cpus) for cpus in effective.values()))

    def siblings(cpu):
        return cpu_list((cpu_root / f'cpu{cpu}/topology/thread_siblings_list').read_text())

    def l3(cpu):
        for cache in sorted((cpu_root / f'cpu{cpu}/cache').glob('index*')):
            if (cache / 'level').read_text().strip() == '3':
                return frozenset(cpu_list((cache / 'shared_cpu_list').read_text()))
        raise ValueError(f'CPU {cpu} has no exposed L3 topology')

    excluded = set().union(*(siblings(cpu) for cpu in irq_cpus))
    domains = sorted({l3(cpu) for cpu in irq_cpus}, key=lambda domain: min(domain))
    candidates = set(allowed) & online & set(range(1024)) - excluded
    groups = [sorted(domain & candidates) for domain in domains]
    selected = []
    used = set(excluded)
    # Spread workers across IRQ cache domains without using SMT siblings twice.
    while len(selected) < workers:
        advanced = False
        for group in groups:
            cpu = next((cpu for cpu in group if cpu not in used), None)
            if cpu is None:
                continue
            selected.append(cpu)
            used.update(siblings(cpu))
            advanced = True
            if len(selected) == workers:
                break
        if not advanced:
            raise ValueError(f'only {len(selected)} allowed physical cores share IRQ L3 caches; requested {workers}')
    return {
        'interface': interface,
        'irq_affinity': effective,
        'excluded_irq_siblings': sorted(excluded),
        'allowed_online_cpus': sorted(set(allowed) & online),
        'worker_cpus': selected,
        'arguments': ['--workers', str(workers), '--worker-cpus', ','.join(map(str, selected))],
    }


def launch_arguments(result, executable, arguments):
    if arguments[:1] == ['--']:
        arguments = arguments[1:]
    for argument in arguments:
        if argument.split('=', 1)[0] in ('--workers', '--worker-cpus'):
            raise ValueError('set worker count on the launcher; worker mapping comes from NIC topology')
    return [executable, *result['arguments'], *arguments]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interface', required=True)
    parser.add_argument('--workers', type=int, default=1)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--exec', dest='executable', help='replace the launcher with this server executable')
    parser.add_argument('arguments', nargs=argparse.REMAINDER, help='server arguments after --')
    args = parser.parse_args()
    if args.json and args.executable:
        parser.error('--json and --exec are mutually exclusive')
    if args.arguments and not args.executable:
        parser.error('server arguments require --exec')
    try:
        result = suggest(args.interface, args.workers, os.sched_getaffinity(0))
        if args.executable:
            command = launch_arguments(result, args.executable, args.arguments)
            os.execvp(args.executable, command)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2) if args.json else ' '.join(result['arguments']))


if __name__ == '__main__':
    main()
