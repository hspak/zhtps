"""Measure direct-LAN HTTP worker placement against the observed single NIC IRQ."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import signal
import subprocess
import time

from compare import admin_json, free_port, wait_ready
from compare_kernel import EVENTS, perf_counts
from overload import core_sample, kernel_sample, proc_sample, stop
from remote_load import RemoteLoad

ROOT = Path(__file__).resolve().parents[1]
PLACEMENTS = {'irq': [24], 'sibling': [8], 'same_l3': [9], 'other_l3': [2],
              'eight_same_l3': list(range(8,16)), 'eight_other_l3': list(range(8))}
SSH = ['ssh','-T','-i','/path/to/benchmark-key','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
       '-o','UserKnownHostsFile=/path/to/known_hosts','-o','ConnectTimeout=10',
       '-o','ServerAliveInterval=5','-o','ServerAliveCountMax=3','client.example']


def network():
    base=Path('/sys/class/net/server_eth0')
    return {'statistics': {p.name:int(p.read_text()) for p in (base/'statistics').iterdir()},
            'interrupts':Path('/proc/interrupts').read_text(),
            'effective_affinity':Path('/proc/irq/103/effective_affinity_list').read_text().strip(),
            'softnet':Path('/proc/net/softnet_stat').read_text()}


def trial(binary,cpus,connections,prefix):
    port=free_port();admin=free_port()
    while admin==port:admin=free_port()
    command=['taskset','-c',','.join(map(str,cpus)),str(binary),'--address','0.0.0.0','--port',str(port),'--admin-port',str(admin),
             '--workers',str(len(cpus)),'--max-connections','8168','--max-active','8168',
             '--max-requests','4294967295','--no-access-log']
    server=remote=perf=None
    with prefix.with_suffix('.server.log').open('w') as log,prefix.with_suffix('.ssh.log').open('w') as sshlog:
        try:
            server=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=log)
            wait_ready(server,port)
            workers=admin_json(admin,'/debug/workers')
            for worker,cpu in zip(workers['workers'],cpus,strict=True):os.sched_setaffinity(worker['thread'],[cpu])
            remote_command=shlex.join(['python3','-u','-c',(ROOT/'bench/remote_load.py').read_text()])
            remote=RemoteLoad('client.example',sshlog,transport=[*SSH,remote_command])
            assert remote.identity['hostname']!='benchmark-server'
            metrics_before=admin_json(admin,'/debug/metrics');before=proc_sample(server.pid)
            cores_before=core_sample(range(os.cpu_count()));kernel_before=kernel_sample();nic_before=network()
            perf_command=['perf','stat','-x',';','-o',str(prefix.with_suffix('.perf')),'-e',','.join(EVENTS),'-p',str(server.pid)]
            perf=subprocess.Popen(perf_command,stdout=subprocess.DEVNULL,stderr=log)
            time.sleep(.1)
            arguments=['-address',f'192.0.2.10:{port}','-connections',str(connections),'-warmup','2s','-duration','5s']
            remote.start('/tmp/zhtps-kernel-work-load',arguments,list(range(8)),connections,90,{})
            assert remote.started['binary_sha256']==hashlib.sha256(Path('/tmp/zhtps-kernel-work/load').read_bytes()).hexdigest()
            deadline=time.monotonic()+95
            while not remote.completed():
                if time.monotonic()>deadline:raise TimeoutError('remote load')
                if server.poll() is not None:raise RuntimeError('server exited during load')
                time.sleep(.05)
            perf.send_signal(signal.SIGINT);perf.wait(timeout=5)
            after=proc_sample(server.pid);cores_after=core_sample(range(os.cpu_count()));kernel_after=kernel_sample();nic_after=network()
            metrics_after=admin_json(admin,'/debug/metrics');load=remote.result['client']
            assert load['errors']==load['setup_errors']==load['warmup_errors']==0
            assert not load['failures'] and not load['window_failures']
            assert load['connections_opened']==load['connections_measured']==connections
            deltas={k:v-metrics_before['counters'][k] for k,v in metrics_after['counters'].items()}
            for k in ('requests_rejected_total','requests_aborted_total','protocol_errors_total','request_timeouts_total','io_errors_total'):assert deltas[k]==0,(k,deltas[k])
            counts=perf_counts(prefix.with_suffix('.perf'));completed=deltas['requests_completed_total']
            row={'command':command,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
                 'load':load,'remote_identity':remote.identity,'remote_started':remote.started,'remote_samples':remote.samples,
                 'remote_clock_offset_ns':remote.clock_offset_ns,'remote_clock_uncertainty_ns':remote.clock_uncertainty_ns,
                 'workers':workers,'server_before':before,'server_after':after,'cores_before':cores_before,'cores_after':cores_after,
                 'kernel_before':kernel_before,'kernel_after':kernel_after,'nic_before':nic_before,'nic_after':nic_after,
                 'counter_deltas':deltas,'perf':counts,'perf_command':perf_command,
                 'cpu_ns':(after['cpu_seconds']-before['cpu_seconds'])*1e9/completed,
                 'system_ns':(after['system_seconds']-before['system_seconds'])*1e9/completed,
                 'perf_per_completed':{k:v['count']/completed for k,v in counts.items()}}
        except Exception as error:
            failed = {'error':repr(error),'server_command':command,
                      'remote_failure':getattr(remote,'failure',None),
                      'nic_before':locals().get('nic_before'),'nic_after':network()}
            if server and server.poll() is None:
                failed['server_after']=proc_sample(server.pid)
                try: failed['metrics_after']=admin_json(admin,'/debug/metrics')
                except Exception as inspection_error: failed['inspection_error']=repr(inspection_error)
            prefix.with_suffix('.failed.json').write_text(json.dumps(failed,indent=2)+'\n')
            raise
        finally:
            if perf and perf.poll() is None:perf.send_signal(signal.SIGINT);perf.wait(timeout=5)
            if remote:remote.stop()
            stop(server)
        assert server.returncode==0,server.returncode
    row['server_exit']=server.returncode
    prefix.with_suffix('.json').write_text(json.dumps(row,indent=2)+'\n')
    return {'goodput':load['window_successes_per_second'],'p99_us':load['latency_us']['p99'],
            'cpu_ns':row['cpu_ns'],'system_ns':row['system_ns'],'perf_per_completed':row['perf_per_completed'],
            'irq_cpu_before':nic_before['effective_affinity'],'irq_cpu_after':nic_after['effective_affinity']}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--placements',nargs='+',choices=PLACEMENTS,default=['irq','sibling','same_l3','other_l3'])
    p.add_argument('--connections',type=int,default=4096);p.add_argument('--repeats',type=int,default=3)
    a=p.parse_args()
    if a.output.exists():p.error('use a fresh output directory')
    a.output.mkdir(parents=True)
    soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE);resource.setrlimit(resource.RLIMIT_NOFILE,(max(soft,65536),hard))
    report={'options':{k:str(v) if isinstance(v,Path) else v for k,v in vars(a).items()},'placements':PLACEMENTS,'runs':[]}
    for repeat in range(a.repeats):
        order=a.placements[repeat%len(a.placements):]+a.placements[:repeat%len(a.placements)]
        for name in order:
            print(f'{repeat+1} {name}',flush=True)
            row=trial(a.binary,PLACEMENTS[name],a.connections,a.output/f'{name}-{repeat+1}')
            row.update(placement=name,repeat=repeat+1);report['runs'].append(row)
            (a.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(row),flush=True)


if __name__=='__main__':main()
