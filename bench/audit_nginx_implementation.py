"""Verify executable provenance and client accounting for the retained experiments."""

import hashlib
import json
import difflib
from pathlib import Path
import statistics
import tarfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/nginx-implementation'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def main():
    receipts = []
    known = {}
    baseline = read(EVIDENCE / 'baseline.json')
    path = ROOT / baseline['binary']
    assert digest(path) == baseline['binary_sha256']
    known[str(path)] = digest(path)
    with tarfile.open(EVIDENCE / 'baseline-source.tar.gz') as archive:
        for relative, expected in baseline['sources'].items():
            assert hashlib.sha256(archive.extractfile(relative).read()).hexdigest() == expected, relative
    for name in ('request-storage', 'idle-reclaim', 'upload-before', 'upload-streaming',
                 'upload-before-unobserved', 'upload-streaming-unobserved', 'final'):
        folder = EVIDENCE / name
        receipt = read(folder / 'build.json')
        assert receipt['build_exit'] == 0
        assert digest(folder / 'source.tar.gz') == receipt['source_archive_sha256']
        with tarfile.open(folder / 'source.tar.gz') as archive:
            for relative, expected in receipt['sources'].items():
                assert hashlib.sha256(archive.extractfile(relative).read()).hexdigest() == expected, relative
        for relative, expected in receipt['binaries'].items():
            binary = ROOT / relative
            assert digest(binary) == expected, relative
            known[str(binary)] = expected
        receipts.append(name)

    groups = {'storage-rates': 12, 'idle-rates': 6, 'idle-policy': 6,
              'idle-pressure-v3': 6, 'uploads': 12, 'uploads-paced': 6,
              'uploads-unobserved': 12, 'uploads-unobserved-paced': 6}
    audited = []
    for group, expected_count in groups.items():
        folder = EVIDENCE / group
        runs = sorted(folder.glob('*/run.json') if group.startswith('uploads') or group == 'idle-pressure-v3'
                      else folder.glob('*/zig-1/run.json'))
        assert len(runs) == expected_count, (group, len(runs))
        binary_hashes = set()
        for path in runs:
            record = read(path)
            actual = record['running_binary_sha256']
            assert actual == record['binary_sha256'] == known[record['command'][0]]
            binary_hashes.add(actual)
            assert record['outcome'] == 'measured' and record['server_exit'] == 0
            assert record['server_identity']['boot_id'] != record['remote_identity']['boot_id']
            load = record['load']
            if group.startswith('uploads'):
                size = record['body_bytes']
                body = (folder / f'body-{size}.bin').read_bytes()
                expected = f'{size}:{zlib.crc32(body):08x}\n'.encode()
                assert len(body) == size == load['request_body_bytes']
                assert load['request_body_sha256'] == hashlib.sha256(body).hexdigest()
                assert load['expected_body_sha256'] == hashlib.sha256(expected).hexdigest()
                assert not load['failures'] and load['window_successes'] > 0
                assert len(load['workers']) == load['connections'] == record['connections'] == 32
                assert all(w['attempts'] == w['successes'] and not w['failures'] for w in load['workers'])
                assert sum(len(w['latencies_ns']) for w in load['workers']) == load['window_successes']
                assert load['validated_body_bytes'] == size * load['window_successes']
                assert load['goodput_bytes_per_second'] == load['validated_body_bytes'] / load['duration_seconds']
                assert load['duration_seconds'] == 20
                assert load.get('rate_cap', 0) == (25 if group.endswith('paced') else 0)
                for flag, content in (('-request-body', body), ('-expect-body', expected)):
                    sent_file = record['remote_started']['files'][flag]
                    assert sent_file == dict(bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
            elif group == 'idle-pressure-v3':
                assert record['setup']['validated_initial_responses'] == 1024
                assert load['offered_new_connections'] == 128
                assert load['successes'] + sum(load['failures'].values()) == 128
                if record['variant'] == 'before':
                    assert load['successes'] == 0 and load['failures'] == {'TimeoutError': 128}
                else:
                    assert load['successes'] == 128 and not load['failures']
                    assert record['metrics_after']['counters']['connection_reclaim_timeouts_total'] == 0
            else:
                assert sum(p['connections_opened'] for p in load['phases']) == load['connections']
                for phase in load['phases']:
                    assert phase['offered'] == phase['sent'] + phase['generator_expired'] + phase['generator_queue_drops']
                    assert phase['successes'] == phase['sent'] and not phase['failures']
                    assert phase['response_bytes_validated'] == 6 * phase['successes']
            audited.append(str(path.relative_to(EVIDENCE)))
        # The deliberate same-binary off/on control isolates the reclamation policy.
        assert len(binary_hashes) == (1 if group == 'idle-policy' else 2)

    for group in ('uploads', 'uploads-paced', 'uploads-unobserved', 'uploads-unobserved-paced'):
        folder = EVIDENCE / group
        rows = [read(p) for p in sorted(folder.glob('*/summary.json'))]
        aggregate = []
        for size, variant in sorted({(r['body_bytes'], r['variant']) for r in rows}):
            selected = [r for r in rows if (r['body_bytes'], r['variant']) == (size, variant)]
            fields = ('goodput_mib_per_second', 'service_p99_ms', 'rss_median_mib', 'rss_peak_mib', 'cpu_us_per_mib')
            aggregate.append(dict(body_bytes=size, variant=variant,
                                  medians={field: statistics.median(r[field] for r in selected) for field in fields},
                                  trials={field: [r[field] for r in selected] for field in fields},
                                  server_retransmits=[r['server_host']['tcp']['RetransSegs'] for r in selected],
                                  server_rx_missed=[r['server_host']['nics']['server_eth0']['rx_missed_errors'] for r in selected]))
        (folder / 'aggregate.json').write_text(json.dumps(aggregate, indent=2) + '\n')

    final = read(EVIDENCE / 'final/build.json')
    for relative, expected in final['sources'].items():
        assert digest(ROOT / relative) == expected, ('changed since final build', relative)
    baseline_unobserved = read(EVIDENCE / 'upload-before-unobserved/build.json')
    baseline_observed = read(EVIDENCE / 'upload-before/build.json')
    for relative, expected in baseline_observed['sources'].items():
        if relative.startswith('src/'):
            assert baseline_unobserved['sources'][relative] == expected, relative
    comment_updates = []
    measured = read(EVIDENCE / 'upload-streaming-unobserved/build.json')
    with tarfile.open(EVIDENCE / 'upload-streaming-unobserved/source.tar.gz') as archive:
        for relative, expected in measured['sources'].items():
            if not relative.startswith('src/') or final['sources'][relative] == expected:
                continue
            previous = archive.extractfile(relative).read().decode().splitlines()
            current = (ROOT / relative).read_text().splitlines()
            for tag, start, end, new_start, new_end in difflib.SequenceMatcher(None, previous, current).get_opcodes():
                if tag != 'equal':
                    assert all(not line.strip() or line.lstrip().startswith('//')
                               for line in previous[start:end] + current[new_start:new_end]), relative
            comment_updates.append(relative)
    result = dict(outcome='passed', build_receipts=receipts, measured_runs=len(audited), runs=audited,
                  final_sources_match=True,
                  final_core_differs_from_measured_only_in_comments=comment_updates,
                  modified_baseline_sources=[relative for relative, expected in baseline['sources'].items()
                                             if final['sources'].get(relative) != expected],
                  supplemental_instrumented_uploads=['uploads', 'uploads-paced'],
                  excluded={'idle-pressure': 'Setup failed at the inherited descriptor limit.',
                            'idle-pressure-v2': 'Remote idle probe timed out; no complete result.',
                            'idle-pressure-smoke': 'Diagnostic small-capacity smoke test.',
                            'upload-smoke': 'Three-second smoke measurements; not decision evidence.'})
    (EVIDENCE / 'audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('runs', 'excluded')}, indent=2))


if __name__ == '__main__':
    main()
