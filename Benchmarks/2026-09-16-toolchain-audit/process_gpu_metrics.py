#!/usr/bin/env python3
"""Check whether powermetrics per-process GPU observations are usable."""
import collections
import json
from pathlib import Path
import statistics as st
import sys

def analyze(path):
    observations = collections.defaultdict(list)
    for block in path.read_text().split('*** Running tasks ***')[1:]:
        for line in block.split('***', 1)[0].splitlines():
            fields = line.rsplit(maxsplit=8)
            if len(fields) != 9 or not fields[1].lstrip('-').isdigit():
                continue
            try:
                observations[fields[0]].append((float(fields[2]), float(fields[8])))
            except ValueError:
                continue
    return dict(path=str(path), processes={name:dict(
        samples=len(values), cpu_ms_per_second_mean=st.mean(v[0] for v in values),
        gpu_ms_per_second_mean=st.mean(v[1] for v in values),
        gpu_ms_per_second_max=max(v[1] for v in values))
        for name,values in sorted(observations.items())})

if __name__ == '__main__':
    print(json.dumps([analyze(Path(x)) for x in sys.argv[1:]], indent=2))
