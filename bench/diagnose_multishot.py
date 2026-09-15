"""Count verbose CQE outcomes in a short diagnostic run; not performance evidence."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess

from compare import admin_json, free_port, wait_ready
from overload import stop


def main():
    root=Path('/tmp/zhtps-kernel-work');out=Path('docs/kernel-work/receive-diagnostic');out.mkdir()
    soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE);resource.setrlimit(resource.RLIMIT_NOFILE,(max(soft,20000),hard))
    for variant in ['multishot','multishot-large-pool']:
        port=free_port();admin=free_port()
        while admin==port:admin=free_port()
        binary=root/variant/'out/bin/zhtps'
        command=['taskset','-c','2',str(binary),'--port',str(port),'--admin-port',str(admin),'--max-connections','8168','--max-active','8168','--max-requests','4294967295','--verbose','--no-access-log']
        path=out/(variant+'.log');server=None
        with path.open('w') as log:
            try:
                server=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=log)
                wait_ready(server,port)
                client=['taskset','-c','4-7',str(root/'load'),'-address',f'127.0.0.1:{port}','-connections','4096','-warmup','0.1s','-duration','0.2s']
                result=subprocess.run(client,capture_output=True,text=True,env=dict(os.environ,GOMAXPROCS='4'),timeout=60)
                metrics=admin_json(admin,'/debug/metrics')
            finally:stop(server)
        outcomes={};records=0
        for line in path.read_text().splitlines():
            try:event=json.loads(line)
            except ValueError:continue
            if event.get('event')=='io_completion' and event.get('operation')=='receive':
                key=str(event['result']);outcomes[key]=outcomes.get(key,0)+1;records+=1
        report={'server_command':command,'client_command':client,'client_returncode':result.returncode,'client':json.loads(result.stdout),'client_stderr':result.stderr,'server_exit':server.returncode,'metrics':metrics,'receive_completions_by_result':outcomes,'logged_receive_completions':records,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'scope':'verbose functional diagnostic; counts are lower bounds if log records were dropped'}
        (out/(variant+'.json')).write_text(json.dumps(report,indent=2)+'\n')
        with gzip.open(str(path)+'.gz','wb') as file:file.write(path.read_bytes())
        path.unlink()
        print(variant, 'ENOBUFS',outcomes.get('-105',0),'client exit',result.returncode,'server exit',server.returncode,flush=True)


if __name__=='__main__':main()
