#!/usr/bin/env python3
"""Measure actual production-built core libraries, full production index space.

Run after build-U has been built with ENABLE_TESTABILITY=NO, and only when
no mining or other build/test campaign is running. Computes individual CPU
verification elements, never an entire CPU Dataset.
"""
import argparse
import csv
import json
from pathlib import Path
import statistics as st
import subprocess as sp

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work',type=Path,default=ROOT/'DerivedDataToolchainAudit20260916')
parser.add_argument('--output',type=Path,required=True,help='New output directory; existing results are never overwritten')
args=parser.parse_args()
WORK=args.work.resolve()
OUTPUT=args.output.resolve()
OUTPUT.mkdir(parents=True,exist_ok=False)
ART=OUTPUT/'artifacts'
ART.mkdir()
for group in ['B','C','U']:
    product=WORK/('build-'+group)/'Build/Products/Release'
    command=['xcrun','swiftc','-parse-as-library','-swift-version','6','-O',
             '-whole-module-optimization','-target','arm64-apple-macos26.5',
             '-I',str(product),'-L',str(product),'-lMetalErgoCore',
             str(HERE/'benchmark-consensus-full.swift'),'-o',str(ART/('cpu-linked-'+group))]
    with (OUTPUT/('compile-cpu-linked-'+group+'.log')).open('w') as log:
        log.write(json.dumps(command)+'\n');log.flush()
        sp.run(command,check=True,stdout=log,stderr=log)
    print(group,'linked',flush=True)

rows=[]; checks={}
with (OUTPUT/'cpu-linked.csv').open('w') as output:
    writer=csv.writer(output)
    writer.writerow(['pair','round','order','variant','workload','iterations','seconds','checksum'])
    for a,b in [('B','C'),('C','U')]:
        for cycle in range(3):
            for order,group in enumerate([a,b,b,a]):
                for line in sp.check_output([str(ART/('cpu-linked-'+group))],text=True).splitlines():
                    workload,iterations,seconds,checksum=line.split(',')
                    if workload in checks:assert checks[workload]==checksum,(group,workload,checksum)
                    checks[workload]=checksum
                    writer.writerow([a+'/'+b,cycle,order,group,workload,iterations,seconds,checksum])
                    rows.append(dict(pair=a+'/'+b,variant=group,workload=workload,seconds=float(seconds)))
                output.flush()
        print(a,b,'ABBA x3 complete',flush=True)
summary={}
for a,b in [('B','C'),('C','U')]:
    pair=a+'/'+b;summary[pair]={}
    for workload in checks:
        groups={v:[r['seconds'] for r in rows if r['pair']==pair and r['variant']==v and r['workload']==workload] for v in [a,b]}
        summary[pair][workload]={v:dict(n=len(x),median=st.median(x),min=min(x),max=max(x),stdev=st.stdev(x)) for v,x in groups.items()}
        summary[pair][workload]['speedup']=st.median(groups[a])/st.median(groups[b])
(OUTPUT/'cpu-linked-summary.json').write_text(json.dumps(dict(checksums=checks,comparisons=summary),indent=2)+'\n')
