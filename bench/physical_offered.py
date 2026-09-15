"""Run the offered-rate harness over the authorized LAN, retaining both TCP stacks."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

import overload
from physical_kernel import SSH
from remote_load import RemoteLoad

SNAPSHOT = '''
import json
from pathlib import Path
result={p:Path(p).read_text() for p in ('/proc/net/snmp','/proc/net/netstat','/proc/net/softnet_stat','/proc/interrupts','/proc/stat')}
result['nics']={nic.name:{p.name:int(p.read_text()) for p in (nic/'statistics').iterdir()} for nic in Path('/sys/class/net').iterdir() if (nic/'device').exists()}
print(json.dumps(result))
'''


def snapshot(remote):
    command=[*SSH,shlex.join(['python3','-c',SNAPSHOT])] if remote else ['python3','-c',SNAPSHOT]
    return json.loads(subprocess.run(command,capture_output=True,text=True,check=True,timeout=15).stdout)


class LanLoad(RemoteLoad):
    def __init__(self,host,error_file):
        source=(Path(__file__).parent/'remote_load.py').read_text()
        super().__init__(host,error_file,transport=[*SSH,shlex.join(['python3','-u','-c',source])])


if __name__=='__main__':
    output=Path(sys.argv[sys.argv.index('--output')+1]).with_suffix('.network.json')
    output.parent.mkdir(parents=True,exist_ok=True)
    evidence={'server_before':snapshot(False),'client_before':snapshot(True)}
    try:
        overload.RemoteLoad=LanLoad
        overload.main()
    finally:
        evidence.update(server_after=snapshot(False),client_after=snapshot(True))
        output.write_text(json.dumps(evidence,indent=2)+'\n')
