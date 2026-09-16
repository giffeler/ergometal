#!/usr/bin/env python3
"""Approximate phase alignment of aggregate powermetrics; no miner-only energy claim."""
import bisect
import datetime as dt
import json
from pathlib import Path
import re
import statistics as st
import sys

def stats(x):
    return dict(n=len(x),median=st.median(x),mean=st.mean(x),min=min(x),max=max(x)) if x else None

def run(meta):
    m=json.loads(meta.read_text())
    if 'final' not in m:return None
    prefix=str(meta).removesuffix('.metadata.json')
    events=[json.loads(x) for x in Path(prefix+'.events.ndjson').read_text().splitlines()]
    observations=[e for e in events if e['type'] in ['statistics_sample','session_ended']]
    stamps=[dt.datetime.fromisoformat(e['timestamp']).timestamp() for e in observations]
    transitions=[]; previous=None
    for stamp,e in zip(stamps,observations):
        state=e['fields'].get('state')
        if state != previous: transitions.append(stamp); previous=state
    text=Path(prefix+'.power.txt').read_text()
    blocks=re.split(r'\*\*\* Sampled system activity \((.*?)\) \(([\d.]+)ms elapsed\) \*\*\*',text)
    rows=[]
    for i in range(1,len(blocks),3):
        timestamp,duration,block=blocks[i:i+3]
        stamp=dt.datetime.strptime(timestamp,'%a %b %d %H:%M:%S %Y %z').timestamp()
        index=bisect.bisect_right(stamps,stamp)-1
        if index<0 or stamp>stamps[-1]:continue
        gpu=block.split('**** GPU usage ****')[-1]
        def number(pattern,source=gpu):
            match=re.search(pattern,source,re.M)
            return float(match[1]) if match else None
        # Telemetry timestamps have one-second resolution and state samples
        # are two seconds apart. Exclude a three-second transition margin.
        stable=all(abs(stamp-t)>3 for t in transitions)
        rows.append(dict(timestamp=stamp,seconds=float(duration)/1000,
            phase=observations[index]['fields'].get('state') if stable else 'transition',
            temperature=float(observations[index]['fields'].get('soc_temperature_maximum_celsius','nan')),
            gpu_w=number(r'^GPU Power: ([\d.]+) mW')/1000,
            cpu_w=number(r'^CPU Power: ([\d.]+) mW',block)/1000,
            gpu_mhz=number(r'GPU HW active frequency: ([\d.]+) MHz'),
            gpu_active_percent=number(r'GPU HW active residency:\s+([\d.]+)%')))
    phases={}
    for phase in ['building_dataset','searching','transition']:
        selected=[r for r in rows if r['phase']==phase]
        phases[phase]={k:stats([r[k] for r in selected]) for k in ['gpu_w','cpu_w','gpu_mhz','gpu_active_percent','temperature']}
    energy=sum(r['gpu_w']*r['seconds'] for r in rows)
    f=m['final']['fields']
    return dict(file=meta.name,variant=m['variant'],batch=m['batch'],phases=phases,
        gpu_aggregate_energy_joules_approx=energy,
        observed_power_seconds=sum(r['seconds'] for r in rows),
        session_seconds=float(f['elapsed_seconds']),
        aggregate_million_nonces_per_joule=int(f['nonces'])/1e6/energy,
        samples=rows)

if __name__=='__main__':
    result=[]
    for directory in sys.argv[1:]:
        result.extend(r for p in sorted(Path(directory).glob('*.metadata.json')) if (r:=run(p)))
    print(json.dumps(result,indent=2))
