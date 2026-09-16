#!/usr/bin/env python3
"""Within-run windows are descriptive, never independent benchmark replicates."""
import json
from pathlib import Path
import statistics as st
import sys

def analyze(path):
    events = [json.loads(line) for line in path.read_text().splitlines()]
    samples = [e['fields'] for e in events if e['type'] in ('statistics_sample','session_ended')]
    windows = []
    for start, end in [(40, 300), (340, 600), (640, 900),
                       (240, 300), (540, 600), (840, 900)]:
        intervals = [(a,b) for a,b in zip(samples,samples[1:])
                     if float(a['elapsed_seconds']) >= start
                     and float(b['elapsed_seconds']) <= end
                     and a.get('state') == b.get('state') == 'searching']
        seconds = sum(float(b['search_seconds'])-float(a['search_seconds']) for a,b in intervals)
        nonces = sum(int(b['nonces'])-int(a['nonces']) for a,b in intervals)
        temperatures = [float(b['soc_temperature_maximum_celsius']) for a,b in intervals]
        windows.append(dict(elapsed_start=start, elapsed_end=end,
            sampled_intervals=len(intervals), search_seconds=seconds, nonces=nonces,
            active_mhs=nonces/seconds/1e6 if seconds else None,
            sensor_temperature_median=st.median(temperatures) if temperatures else None,
            sensor_temperature_min=min(temperatures) if temperatures else None,
            sensor_temperature_max=max(temperatures) if temperatures else None))
    return dict(path=str(path), windows=windows)

if __name__ == '__main__':
    print(json.dumps([analyze(Path(x)) for x in sys.argv[1:]], indent=2))
