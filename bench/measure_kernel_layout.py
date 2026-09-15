"""Record compiled offsets and static cache-line coverage of selected GET fields.

Coverage is a source-level access model, not a trace of CPU loads. It excludes
external buffers and, for borrowed parsers, the separately stored header entry.
All eight possible 8-byte-aligned positions within a 64-byte line are considered.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'docs/kernel-work'
WORKSPACE = Path('/tmp/zhtps-kernel-work')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('variants', nargs='+')
    args = parser.parse_args()
    for name in args.variants:
        tree = WORKSPACE / name
        command = ['zig','build-exe','-O','ReleaseSafe','-mcpu=x86_64_v4',
                   '--cache-dir',str(tree/'layout-cache'),'--global-cache-dir','/tmp/zhtps-zig-global-cache',
                   '--dep','zhtps','-Mroot='+str(OUTPUT/'layout.zig'),'--dep','zeit',
                   '-Mzhtps='+str(tree/'src/root.zig'),
                   '-Mzeit='+str(next((tree/'zig-pkg').glob('zeit-*/src/zeit.zig'))),
                   '-femit-bin='+str(tree/'out/bin/layout')]
        subprocess.run(command,check=True)
        output = subprocess.run([str(tree/'out/bin/layout')],capture_output=True,text=True,check=True).stderr
        (OUTPUT/f'{name}-layout.txt').write_text(output)
        layouts = {}
        current = None
        for line in output.splitlines():
            if match := re.fullmatch(r'([\w.]+): size=(\d+) align=(\d+)',line):
                current = dict(size=int(match[2]),alignment=int(match[3]),fields={})
                layouts[match[1]] = current
            elif match := re.fullmatch(r'  (\w+): offset=(\d+) bytes=(\d+)',line):
                current['fields'][match[1]] = dict(offset=int(match[2]),size=int(match[3]))
        connection, decoder = layouts['Connection'], layouts['Connection.Parser']
        groups = {
            'completion': ['fd','generation','pending','phase','receive_pending','send_pending'],
            'request_io': ['fd','phase','receive_buffer','receive_start','receive_end','output_buffer',
                           'output_len','output_sent','body','body_sent','send_pending','receive_pending',
                           'request_started','request_completed','first_byte_recorded','request_id',
                           'started_ns','deadline','requests','response_status','permit','response_body_bytes',
                           'streaming','interim','close_after_response','more_pending','more_count'],
        }
        model = {}
        for label, fields in groups.items():
            ranges = [(connection['fields'][field]['offset'], connection['fields'][field]['size']) for field in fields]
            if label == 'request_io':
                base = connection['fields']['parser']['offset']
                for field in ('head_storage','limits','request','phase','head_len','leading_lines','first_line','spaces','target_len'):
                    entry = decoder['fields'][field]
                    ranges.append((base+entry['offset'],entry['size']))
                entry = decoder['fields']['head_fields']
                ranges.append((base+entry['offset'],min(32,entry['size'])))
            counts=[]
            for alignment in range(0,64,8):
                lines=set()
                for offset,size in ranges:
                    lines.update(range((alignment+offset)//64,(alignment+offset+size-1)//64+1))
                counts.append(len(lines))
            model[label] = dict(cache_lines_by_alignment=counts,mean=sum(counts)/len(counts))
        report=dict(command=command,source_sha256=hashlib.sha256((OUTPUT/'layout.zig').read_bytes()).hexdigest(),
                    layouts=layouts,static_access_model=model)
        (OUTPUT/f'{name}-layout.json').write_text(json.dumps(report,indent=2)+'\n')
        print(name,'connection',connection['size'],'parser',decoder['size'],'static lines',model)


if __name__ == '__main__':
    main()
