"""Add whole-host TCP segment counters to the pinned pipeline experiment."""
from pathlib import Path
import pipeline_kernel

original_sample=pipeline_kernel.kernel_sample


def sample():
    result=original_sample()
    lines=Path('/proc/net/snmp').read_text().splitlines()
    for i,line in enumerate(lines):
        if line.startswith('Tcp:'):
            result['tcp_mib']=dict(zip(line.split()[1:],map(int,lines[i+1].split()[1:])))
            break
    return result


if __name__=='__main__':
    pipeline_kernel.kernel_sample=sample
    pipeline_kernel.main()
