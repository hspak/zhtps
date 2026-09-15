"""Capture server kernel stacks with gradually opened, remote fixed-rate traffic."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import subprocess

from compare import admin_json, free_port, wait_ready
from overload import proc_sample, core_sample, stop
from physical_kernel import SSH, network


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--cpu',type=int,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.output.exists():p.error('use a fresh output directory')
    a.output.mkdir(parents=True)
    soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE);resource.setrlimit(resource.RLIMIT_NOFILE,(max(soft,20000),hard))
    binary=Path('/tmp/zhtps-kernel-work/baseline/out/bin/zhtps');port=free_port();admin=free_port()
    while admin==port:admin=free_port()
    command=['taskset','-c',str(a.cpu),str(binary),'--address','0.0.0.0','--port',str(port),'--admin-port',str(admin),'--max-connections','8168','--max-active','8168','--max-requests','4294967295','--no-access-log']
    client=['taskset','-c','0-7','/tmp/zhtps-kernel-work-load','-address',f'192.0.2.10:{port}','-connections','4096','-schedule','1000:5s,100000:5s','-shards','8']
    launcher="import os,resource;soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE);resource.setrlimit(resource.RLIMIT_NOFILE,(max(soft,20000),hard));os.environ['GOMAXPROCS']='8';os.execvp('taskset',"+repr(client)+")"
    record=['perf','record','-F','999','-e','cycles:k','-g','-o',str(a.output/'kernel.data'),'-p']
    server=None
    with (a.output/'server.log').open('w') as log:
        try:
            server=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=log);wait_ready(server,port)
            metrics_before=admin_json(admin,'/debug/metrics');before=proc_sample(server.pid);nic_before=network();cores_before=core_sample(range(os.cpu_count()))
            record += [str(server.pid),'--',*SSH,shlex.join(['python3','-c',launcher])]
            result=subprocess.run(record,capture_output=True,text=True,timeout=40)
            (a.output/'record.txt').write_text(result.stderr);(a.output/'client.json').write_text(result.stdout)
            result.check_returncode();load=json.loads(result.stdout)
            for phase in load['phases']:assert not phase['failures']
            after=proc_sample(server.pid);metrics_after=admin_json(admin,'/debug/metrics');nic_after=network();cores_after=core_sample(range(os.cpu_count()))
            report=dict(server_command=command,record_command=record,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),client=load,server_before=before,server_after=after,metrics_before=metrics_before,metrics_after=metrics_after,nic_before=nic_before,nic_after=nic_after,cores_before=cores_before,cores_after=cores_after)
        finally:stop(server)
    assert server.returncode==0
    report['server_exit']=server.returncode;(a.output/'run.json').write_text(json.dumps(report,indent=2)+'\n')
    command=['perf','report','--stdio','--no-children','-g','none','--sort','symbol,dso','--percent-limit','0.5','-i',str(a.output/'kernel.data')]
    r=subprocess.run(command,capture_output=True,text=True,check=True);(a.output/'report.txt').write_text(r.stdout+r.stderr)


if __name__=='__main__':main()
