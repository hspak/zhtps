"""Audit preserved request accounting, errors, counters, and source identities."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'docs/kernel-work'
HEALTH=('requests_rejected_total','requests_aborted_total','protocol_errors_total','request_timeouts_total','io_errors_total')


def audit():
    result={'closed_loop':{},'echo':{},'pipeline':{},'physical_gradual':{},'failures_preserved':[
        'bundle-tests-safe.txt: initial queued-fragment failure, corrected and revalidated',
        'physical-many.txt: saturation client failure; old collector lost its JSON details',
        'physical-offered/same_l3-3.json: collector exit-sampling race, fixed with regression coverage',
        'physical-saturation-followup/same_l3-2.failed.json: two read timeouts and two reconnections',
        'echo-counters.txt: refused unsupported closed-loop echo case before running a trial'],
        'profile_scope':'per-task PMU includes kernel/softirq execution while the task is current; /proc process CPU excludes separately accounted softirq time'}
    for block in ('baseline-counters','multishot-counters','receive-counters-v2','send-counters','large-pool-counters'):
        summary=json.loads((OUT/block/'summary.json').read_text());count=success=0
        for brief in summary['runs']:
            path=OUT/block/f"{brief['case']}-{brief['variant']}-{brief['repeat']}.json"
            row=json.loads(path.read_text());load=row['load'];d=row['counter_deltas']
            assert load['errors']==load['setup_errors']==load['warmup_errors']==0
            assert not load['failures'] and not load['window_failures']
            assert load['attempts']==load['successes']
            assert load['connections_opened']==load['connections_measured']==load['connections_ready']
            assert all(d[k]==0 for k in HEALTH)
            assert all(v['running_percent']==100 and v['count'] is not None for v in row['perf'].values())
            count+=1;success+=load['window_successes']
        result['closed_loop'][block]={'trials':count,'validated_window_responses':success,'errors':0,'all_pmu_events_running_percent':100}
    summary=json.loads((OUT/'echo-offered-counters/summary.json').read_text());success=0
    for brief in summary['runs']:
        row=json.loads((OUT/'echo-offered-counters'/f"echo-{brief['variant']}-{brief['repeat']}.json").read_text())
        load=row['load'];assert load['workload']['request_body_bytes']==load['workload']['expected_body_bytes']==65536
        assert all(row['counter_deltas'][k]==0 for k in HEALTH)
        for phase in load['phases']:
            assert not phase['failures'] and phase['successes']==phase['sent']
            assert phase['response_bytes_validated']==phase['successes']*65536
        success+=load['phases'][-1]['window_successes']
    result['echo']={'trials':len(summary['runs']),'validated_window_responses':success,'transport_or_http_failures':0}
    for block in ('pipeline','pipeline-packets'):
        trials=json.loads((OUT/block/'trials.json').read_text());success=0
        for trial in trials:
            assert trial['returncode']==0
            row=json.loads((OUT/block/(trial['tag']+'.json')).read_text())
            assert row['server_exit']==0 and not row['workload']['failures']
            assert all(row['counter_deltas'][k]==0 for k in HEALTH)
            success+=row['workload']['validated_responses']
        result['pipeline'][block]={'trials':len(trials),'validated_responses':success,'errors':0}
    trials=json.loads((OUT/'physical-offered-gradual/trials.json').read_text());success=unsent=0
    for trial in trials:
        assert trial['returncode']==0
        row=json.loads((OUT/'physical-offered-gradual'/(trial['tag']+'.json')).read_text())
        assert row['status']=='complete' and row['server_exit']==0
        assert row['remote_client']['separate_kernel']
        assert all(row['metrics_after']['counters'][k]-row['metrics_before']['counters'][k]==0 for k in HEALTH)
        phases=row['client']['phases'];assert sum(p['connections_opened'] for p in phases)==4096
        assert sum(p['dial_attempts'] for p in phases)==4096
        for phase in phases:
            assert not phase['failures'] and phase['sent']==phase['successes']
            assert phase['successes']>=phase['offered']*.999
            success+=phase['window_successes'];unsent+=phase['generator_expired']+phase['generator_queue_drops']
    result['physical_gradual']={'trials':len(trials),'validated_window_responses_including_warmup':success,'transport_or_http_failures':0,'reconnections':0,'unsent_offers':unsent,'minimum_phase_success_fraction':.999}
    original=json.loads((OUT/'baseline-source.json').read_text())['sources']
    current={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'src').rglob('*.zig'))}
    assert original==current,'runtime source changed from the baseline'
    result['runtime_matches_baseline']=True
    for name in ('baseline','multishot','bundle','batch','vector','multishot-large-pool'):
        tree=OUT/'snapshots'/name
        manifest=json.loads((tree/'manifest.json').read_text())
        assert all(hashlib.sha256((tree/path).read_bytes()).hexdigest()==digest for path,digest in manifest.items())
    result['source_manifests_verified']=True
    (OUT/'audit.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))


if __name__=='__main__':audit()
