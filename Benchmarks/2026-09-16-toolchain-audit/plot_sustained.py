#!/usr/bin/env python3
"""Standalone scientific plot from preserved observations (requires matplotlib)."""
import datetime as dt
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
RAW = HERE/'raw'
meta = json.loads((RAW/'sustained-mine/01-C-production-4194304.metadata.json').read_text())
events = [json.loads(line) for line in
          (RAW/'sustained-mine/01-C-production-4194304.events.ndjson').read_text().splitlines()]
samples = [e['fields'] for e in events if e['type'] in ('statistics_sample','session_ended')]
phase = [p for p in json.loads((RAW/'all-phase-metrics.json').read_text())
         if p['campaign'] == 'sustained-mine'][0]
rate_x, rate_y = [], []
for start in range(0,900,60):
    pairs = [(a,b) for a,b in zip(samples,samples[1:])
             if float(a['elapsed_seconds']) >= start
             and float(b['elapsed_seconds']) < start+60
             and a['state'] == b['state'] == 'searching']
    seconds = sum(float(b['search_seconds'])-float(a['search_seconds']) for a,b in pairs)
    nonces = sum(int(b['nonces'])-int(a['nonces']) for a,b in pairs)
    if seconds:
        rate_x.append((start+30)/60)
        rate_y.append(nonces/seconds/1e6)
builds=[]
for e in events:
    if e['type'] == 'dataset_completed' and e['fields']['source'] == 'built':
        end=dt.datetime.fromisoformat(e['timestamp']).timestamp()-meta['wall_start']
        builds.append(((end-float(e['fields']['seconds']))/60,end/60))

plt.rcParams.update({'font.size':10, 'svg.fonttype':'none'})
fig,axes=plt.subplots(3,1,figsize=(10,7.8),sharex=True,layout='constrained')
axes[0].plot(rate_x,rate_y,'o-',color='#185b97',markersize=4,linewidth=1.3)
axes[0].set_ylabel('Active Search\n(MH/s)')
axes[0].set_ylim(14.7,15.5)
axes[0].set_title('15 minutes of load: 4M batch, unchanged production binary',loc='left')
axes[1].plot([float(s['elapsed_seconds'])/60 for s in samples],
             [float(s['soc_temperature_maximum_celsius']) for s in samples],
             color='#a34618',linewidth=1.2)
axes[1].set_ylabel('Highest sensor\n(°C)')
axes[1].set_ylim(40,82)
axes[2].plot([(s['timestamp']-meta['wall_start'])/60 for s in phase['samples']],
             [s['gpu_w'] for s in phase['samples']],color='#316547',linewidth=1)
axes[2].set_ylabel('Total GPU\n(W)')
axes[2].set_ylim(0,22)
axes[2].set_xlabel('Time since start (minutes)')
for ax in axes:
    for i,(start,end) in enumerate(builds):
        ax.axvspan(start,end,color='#777777',alpha=.14,
                   label='Full Dataset build' if ax is axes[0] and i==0 else None)
    ax.grid(axis='y',alpha=.18)
    ax.spines[['top','right']].set_visible(False)
    ax.set_xlim(0,15)
axes[0].legend(loc='lower right',frameon=False,fontsize=9)
fig.supxlabel('Search: grouped 60-second windows; not independent replicates. '
              'Temperature and GPU power are system-wide measurements.',fontsize=9)
fig.savefig(HERE/'sustained-profile.svg',metadata={'Creator':None,'Date':None})
fig.savefig(HERE/'sustained-profile.png',dpi=170,metadata={'Software':None})
print('Saved sustained-profile.svg and sustained-profile.png')
