#!/usr/bin/env python3
"""Summarize preserved per-run telemetry; never infer hashrate from shares."""
import collections
import json
from pathlib import Path
import re
import statistics as st
import sys


def stats(values):
    if not values: return None
    return dict(n=len(values), median=st.median(values), min=min(values), max=max(values),
                mean=st.mean(values), stdev=st.stdev(values) if len(values)>1 else 0)


def runs(directory):
    result=[]
    for path in sorted(directory.glob('*.metadata.json')):
        m=json.loads(path.read_text())
        if 'final' not in m: continue
        prefix=str(path).removesuffix('.metadata.json')
        f=m['final']['fields']; number=lambda key:float(f[key])
        events=[json.loads(s) for s in Path(prefix+'.events.ndjson').read_text().splitlines()]
        samples=[e for e in events if e['type'] in ('statistics_sample','session_ended')]
        temps=[float(e['fields']['soc_temperature_maximum_celsius']) for e in samples
               if 'soc_temperature_maximum_celsius' in e['fields']]
        builds=[e['fields'] for e in events if e['type']=='dataset_completed' and e['fields']['source']=='built']
        power=Path(prefix+'.power.txt').read_text()
        freqs=[float(x) for x in re.findall(r'GPU HW active frequency: ([\d.]+) MHz',power)]
        # cpu_power also prints a GPU estimate. Use only gpu_power's section
        # so there is one GPU power observation per sampling interval.
        gpu_sections=re.findall(r'\*\*\*\* GPU usage \*\*\*\*(.*?)(?=\*\*\* Sampled|$)',power,re.S)
        watts=[float(x)/1000 for block in gpu_sections for x in re.findall(r'^GPU Power: ([\d.]+) mW',block,re.M)]
        residency=[float(x) for x in re.findall(r'GPU HW active residency:\s+([\d.]+)%',power)]
        stderr=Path(prefix+'.stderr').read_text()
        cpu={k:float(v) for k,v in re.findall(r'^(real|user|sys)\s+([\d.]+)',stderr,re.M)}
        windows=[]
        for a,b in zip(samples,samples[1:]):
            af,bf=a['fields'],b['fields'];dt=float(bf['search_seconds'])-float(af['search_seconds'])
            if dt>0:
                windows.append(dict(elapsed=float(bf['elapsed_seconds']), active_mhs=(int(bf['nonces'])-int(af['nonces']))/dt/1e6,
                                    temperature=float(bf.get('soc_temperature_maximum_celsius','nan'))))
        result.append(dict(file=path.name,variant=m['variant'],batch=m['batch'],
            active_mhs=number('average_hashrate')/1e6,effective_mhs=number('effective_hashrate')/1e6,
            elapsed=number('elapsed_seconds'),search_seconds=number('search_seconds'),
            search_duty=number('search_duty_cycle'),nonces=int(f['nonces']),
            build_wall=stats([float(b['seconds']) for b in builds]),
            build_gpu=stats([float(b['gpu_seconds']) for b in builds]),
            builds=builds,
            dataset_bytes=int(f['dataset_bytes']),start_temperature=m['start_temperature']['maximumCelsius'],
            sample_temperature=stats(temps),peak_temperature=number('soc_temperature_session_peak_celsius'),
            gpu_active_frequency_mhz=stats(freqs),gpu_power_w=stats(watts),gpu_active_percent=stats(residency),
            cpu_time=cpu,cpu_percent_one_core=100*(cpu.get('user',0)+cpu.get('sys',0))/number('elapsed_seconds'),
            non_gpu_search_busy_seconds=number('gpu_search_command_non_gpu_busy_seconds_total'),
            verified_candidates=f.get('verified_candidates'),protocol_errors=int(f['protocol_errors']),
            windows=windows))
    return result


def summarize(directory):
    data=runs(directory);groups=collections.defaultdict(list)
    for r in data: groups[f'{r["variant"]}:{r["batch"]}'].append(r)
    summary={}
    for label,rows in groups.items():
        summary[label]={k:stats([r[k] for r in rows]) for k in
                        ('active_mhs','effective_mhs','peak_temperature','cpu_percent_one_core','non_gpu_search_busy_seconds')}
        summary[label]['build_wall']=stats([r['build_wall']['median'] for r in rows if r['build_wall']])
        summary[label]['build_gpu']=stats([r['build_gpu']['median'] for r in rows if r['build_gpu']])
    blocks=[]
    for i in range(0,len(data)-3,4):
        a,b,c,d=data[i:i+4]
        if (a['variant'],a['batch'])!=(d['variant'],d['batch']) or (b['variant'],b['batch'])!=(c['variant'],c['batch']):continue
        label=lambda r:f'{r["variant"]}:{r["batch"]}'
        ratios={k:((b[k]+c[k])/(a[k]+d[k])-1)*100 for k in ('active_mhs','effective_mhs')}
        blocks.append(dict(start=i+1,baseline=label(a),candidate=label(b),percent_change=ratios))
    return dict(directory=str(directory),summary=summary,abba_blocks=blocks,runs=data)


if __name__=='__main__':
    print(json.dumps([summarize(Path(d)) for d in sys.argv[1:]],indent=2))
