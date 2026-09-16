#!/usr/bin/env python3
"""Read-only, session-aware audit of existing miner telemetry."""
import collections
import datetime as dt
import hashlib
import json
from pathlib import Path
import statistics as st
import sys


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return dict(n=len(values), minimum=values[0], median=st.median(values),
                maximum=values[-1], mean=st.mean(values),
                stdev=st.stdev(values) if len(values) > 1 else 0)


def analyze(path):
    sessions = collections.defaultdict(list)
    for line in path.read_text().splitlines():
        event = json.loads(line)
        sessions[event['sessionID']].append(event)
    result = []
    for sid, events in sessions.items():
        starts = [x for x in events if x['type'] == 'session_started']
        ends = [x for x in events if x['type'] == 'session_ended']
        samples = [x for x in events if x['type'] in ('statistics_sample', 'session_ended')]
        issues = []
        if len(starts) != 1 or len(ends) != 1:
            issues.append(f'start/end counts {len(starts)}/{len(ends)}')
        if not ends:
            result.append(dict(sessionID=sid, issues=issues)); continue
        final = ends[-1]['fields']
        n = lambda key: float(final[key])
        for a, b in zip(events, events[1:]):
            if a['timestamp'] > b['timestamp']:
                issues.append(f'timestamp reversal {a["timestamp"]}/{b["timestamp"]}')
        previous = {}
        checked = set()
        for event in samples:
            for key, value in event['fields'].items():
                if key.endswith('_total') or key in ('nonces', 'search_seconds', 'gpu_seconds',
                    'elapsed_seconds', 'shares_found', 'shares_submitted', 'shares_accepted',
                    'shares_rejected', 'shares_stale', 'reconnects', 'protocol_errors'):
                    number = float(value); checked.add(key)
                    if key in previous and number + 1e-7 < previous[key]:
                        issues.append(f'nonmonotonic {key}: {previous[key]} -> {number}')
                    previous[key] = number
        residuals = {
            'active_hashrate': n('average_hashrate') - n('nonces') / n('search_seconds'),
            'effective_hashrate': n('effective_hashrate') - n('nonces') / n('elapsed_seconds'),
            'search_duty': n('search_duty_cycle') - n('search_seconds') / n('elapsed_seconds'),
            'search_wall_busy': n('search_seconds') - n('gpu_search_command_wall_busy_seconds_total'),
            'search_busy_partition': n('gpu_search_command_wall_busy_seconds_total') -
                n('gpu_search_command_gpu_busy_seconds_total') - n('gpu_search_command_non_gpu_busy_seconds_total'),
            'nonce_command_count': int(final['nonces']) - int(final['gpu_search_commands_completed_total']) * int(final['batch_nonces']),
        }
        for key, value in residuals.items():
            if abs(value) > 1e-5:
                issues.append(f'invariant {key}: {value}')
        builds = [e for e in events if e['type'] == 'dataset_completed' and e['fields']['source'] == 'built']
        temp = [float(e['fields']['soc_temperature_maximum_celsius']) for e in samples
                if 'soc_temperature_maximum_celsius' in e['fields']]
        intervals = []
        for a, b in zip(samples, samples[1:]):
            af, bf = a['fields'], b['fields']
            search = float(bf['search_seconds']) - float(af['search_seconds'])
            if search > 0:
                intervals.append(dict(start=a['timestamp'], end=b['timestamp'],
                    active_mhs=(int(bf['nonces'])-int(af['nonces']))/search/1e6,
                    temperature_end=float(bf.get('soc_temperature_maximum_celsius', 'nan'))))
        residual_time = n('elapsed_seconds') - n('search_seconds') - n('dataset_cold_build_wall_seconds_total')
        result.append(dict(sessionID=sid, first=events[0]['timestamp'], last=events[-1]['timestamp'],
            event_counts=dict(collections.Counter(e['type'] for e in events)),
            start_fields=starts[0]['fields'] if starts else {}, final_fields=final,
            chronology_and_monotonicity_issues=issues, monotonic_fields_checked=sorted(checked),
            invariant_residuals=residuals, unaccounted_wall_seconds=residual_time,
            cold_build_seconds=distribution([float(e['fields']['seconds']) for e in builds]),
            cold_build_gpu_seconds=distribution([float(e['fields']['gpu_seconds']) for e in builds]),
            sampled_sensor_maximum_celsius=distribution(temp), intervals=intervals))
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), sessions=result)


if __name__ == '__main__':
    print(json.dumps([analyze(Path(p)) for p in sys.argv[1:]], indent=2))
