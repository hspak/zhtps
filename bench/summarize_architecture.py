"""Derive interval CPU and packet counters from architectural diagnostic trials."""

import argparse
import json
from pathlib import Path
import statistics


def counters(text, protocol):
    lines = text.splitlines()
    for names, values in zip(lines[::2], lines[1::2], strict=True):
        if names.startswith(protocol + ':'):
            return dict(zip(names.split()[1:], map(int, values.split()[1:]), strict=True))
    raise ValueError(protocol)


def cores(text):
    return {words[0]: list(map(int, words[1:9])) for line in text.splitlines()
            if (words := line.split()) and words[0].startswith('cpu') and words[0] != 'cpu'}


def host_delta(first, last):
    seconds = (last['unix_ns'] - first['unix_ns']) / 1e9
    before, after = cores(first['stat']), cores(last['stat'])
    busy = {}
    softirq = {}
    for cpu, values in after.items():
        delta = [a-b for a,b in zip(values,before[cpu],strict=True)]
        ticks = sum(delta)
        busy[cpu] = (ticks-delta[3]-delta[4])/ticks if ticks else 0
        softirq[cpu] = delta[6]/ticks if ticks else 0
    tcp_before, tcp_after = counters(first['net/snmp'], 'Tcp'), counters(last['net/snmp'], 'Tcp')
    ext_before, ext_after = counters(first['net/netstat'], 'TcpExt'), counters(last['net/netstat'], 'TcpExt')
    return dict(seconds=seconds, busy_cores=sum(busy.values()), busy_by_cpu=busy,
                softirq_cores=sum(softirq.values()), softirq_by_cpu=softirq,
                tcp={k:tcp_after[k]-tcp_before[k] for k in ('InSegs','OutSegs','RetransSegs','InErrs','OutRsts')},
                tcp_ext={k:ext_after.get(k,0)-ext_before.get(k,0) for k in
                         ('ListenOverflows','ListenDrops','TCPBacklogDrop','TCPRcvQDrop','TCPOFODrop',
                          'TCPTimeouts','TCPFastRetrans','TCPLostRetransmit','TCPMemoryPressures')},
                nics={nic:{k:v-first['nics'][nic][k] for k,v in values.items()}
                      for nic,values in last['nics'].items()})


def summarize(path):
    run = json.loads(path.read_text())
    if run.get('outcome') != 'measured':
        return dict(path=str(path), outcome=run.get('outcome'), error=run.get('error'))
    before, after = run['server_before'], run['server_after']
    load = run['load']
    result = dict(path=str(path), variant=run['variant'], repeat=run['repeat'],
                  rss_mib=after['VmRSS']/2**20,
                  process_cpu_seconds=after['cpu_seconds']-before['cpu_seconds'],
                  server_network=host_delta(run['host_before'],run['host_after']),
                  server_exit=run['server_exit'], phases=[])
    samples = run['samples']
    if run.get('workers_after'):
        counts = [worker['requests_completed_total'] for worker in run['workers_after']['workers']]
        result['worker_requests_max_over_mean'] = max(counts)/statistics.mean(counts)
        result['worker_requests_min_over_mean'] = min(counts)/statistics.mean(counts)
        result['io_per_completion'] = {
            k:(run['metrics_after']['counters'][k]-run['metrics_before']['counters'][k]) /
              (run['metrics_after']['counters']['requests_completed_total']-
               run['metrics_before']['counters']['requests_completed_total'])
            for k in ('io_submissions_total','io_completions_total')}
    if 'phases' not in load:
        result['closed_loop'] = {k:load[k] for k in ('connections','connections_ready','connections_measured',
                                                   'connections_opened','window_successes_per_second','latency_us',
                                                   'setup_errors','warmup_errors','errors','failures')}
        return result
    successes = sum(phase['successes'] for phase in load['phases'])
    result['total_successes'] = successes
    result['whole_run_cpu_us_per_success'] = result['process_cpu_seconds']*1e6/successes
    result['whole_run_user_us_per_success'] = (after['user_seconds']-before['user_seconds'])*1e6/successes
    result['whole_run_system_us_per_success'] = (after['system_seconds']-before['system_seconds'])*1e6/successes
    for phase in load['phases']:
        start = phase['start_unix_ns'] + run['clock_offset_ns']
        end = phase['end_unix_ns'] + run['clock_offset_ns']
        interval = [s for s in samples if start+500_000_000 <= s['unix_ns'] < end-200_000_000]
        first, last = interval[0], interval[-1]
        seconds = (last['unix_ns']-first['unix_ns'])/1e9
        cpu = {k:(last['server'][k]-first['server'][k])/seconds for k in
               ('cpu_seconds','user_seconds','system_seconds')}
        row = dict(offered_rate=phase['offered_rate'], goodput=phase['window_successes_per_second'],
                   failures=phase['failures'], connections_opened=phase['connections_opened'],
                   generator_drops=phase['generator_queue_drops']+phase['generator_expired'],
                   offer_p99_us=phase['success_latency']['p99_us'],
                   service_p99_us=phase['success_service_latency']['p99_us'],
                   cpu_interval_seconds=seconds, process_cpu_cores=cpu['cpu_seconds'],
                   user_cpu_cores=cpu['user_seconds'], system_cpu_cores=cpu['system_seconds'],
                   cpu_us_per_success_estimate=cpu['cpu_seconds']*1e6/phase['window_successes_per_second'],
                   server_host=host_delta(first['host'],last['host']))
        remote = [s for s in run['remote_samples'] if 'host' in s and
                  phase['start_unix_ns']+500_000_000 <= s['unix_ns'] < phase['end_unix_ns']-200_000_000]
        if len(remote) >= 2:
            row['client_host'] = host_delta(remote[0]['host'],remote[-1]['host'])
        result['phases'].append(row)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder',type=Path)
    args = parser.parse_args()
    rows = [summarize(path) for path in sorted(args.folder.glob('*/run.json'))]
    (args.folder/'summary.json').write_text(json.dumps(rows,indent=2)+'\n')
    for row in rows:
        print(row['path'])
        for phase in row.get('phases',[]):
            print(phase['offered_rate'], round(phase['goodput']),
                  f"{phase['cpu_us_per_success_estimate']:.2f} us CPU/response (estimate)",
                  f"{phase['service_p99_us']/1000:.3f} ms service p99",
                  phase['server_host']['tcp']['RetransSegs'], 'retransmitted segments')
