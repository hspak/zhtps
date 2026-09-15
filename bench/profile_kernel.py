"""Capture per-process kernel stacks under the validated closed-loop HTTP workload."""
import argparse
import hashlib
import json
import os
import resource
from pathlib import Path
import subprocess
import time

from compare import admin_json, free_port, wait_ready
from compare_kernel import CASES
from overload import proc_sample, stop

ROOT = Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--case',choices=CASES,default='many')
    a=p.parse_args()
    if a.output.exists(): p.error('choose a fresh output directory')
    a.output.mkdir(parents=True)
    soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE,(min(max(soft,65536),hard),hard))
    case=CASES[a.case]; port=free_port(); admin=free_port()
    while admin==port: admin=free_port()
    command=['taskset','-c',','.join(map(str,case['server_cpus'])),str(a.binary),'--port',str(port),'--admin-port',str(admin),'--workers',str(len(case['server_cpus'])),'--max-connections',str(case['capacity']),'--max-active',str(case['capacity']),'--max-requests','4294967295','--no-access-log']
    server=None
    with (a.output/'server.log').open('w') as log:
        try:
            server=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=log)
            wait_ready(server,port)
            workers=admin_json(admin,'/debug/workers')
            for w,cpu in zip(workers['workers'],case['server_cpus'],strict=True): os.sched_setaffinity(w['thread'],[cpu])
            before=proc_sample(server.pid); metrics_before=admin_json(admin,'/debug/metrics')
            client=['taskset','-c',','.join(map(str,case['client_cpus'])),'/tmp/zhtps-kernel-work/load','-address',f'127.0.0.1:{port}','-connections',str(case['connections']),'-duration','5s','-warmup','2s']
            record=['perf','record','-F','999','-e','cycles:k','-g','-o',str(a.output/'kernel.data'),'-p',str(server.pid),'--',*client]
            r=subprocess.run(record,capture_output=True,text=True,env=dict(os.environ,GOMAXPROCS=str(len(case['client_cpus']))),timeout=100)
            (a.output/'record.txt').write_text(r.stderr)
            r.check_returncode(); load=json.loads(r.stdout)
            assert load['errors']==load['setup_errors']==load['warmup_errors']==0
            assert load['connections_measured']==case['connections'] and load['connections_opened']==case['connections']
            after=proc_sample(server.pid);metrics_after=admin_json(admin,'/debug/metrics')
            report={'server_command':command,'record_command':record,'case':case,'workers':workers,'binary_sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'client':load,'server_before':before,'server_after':after,'metrics_before':metrics_before,'metrics_after':metrics_after,'profile_scope':'kernel samples while server threads are current, including synchronous softirqs; separate ksoftirqd/IRQ CPUs are not fully represented'}
            (a.output/'run.json').write_text(json.dumps(report,indent=2)+'\n')
        finally: stop(server)
    report_command=['perf','report','--stdio','--no-children','-g','none','--sort','symbol,dso','--percent-limit','0.5','-i',str(a.output/'kernel.data')]
    r=subprocess.run(report_command,capture_output=True,text=True,check=True)
    (a.output/'report.txt').write_text(r.stdout+r.stderr)
    print(r.stdout)


if __name__=='__main__': main()
