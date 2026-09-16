#!/usr/bin/env python3
"""Compile and measure isolated CPU controls; run only with no mining campaign."""
import csv
import hashlib
import json
from pathlib import Path
import statistics
import subprocess as sp

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WORK = ROOT / 'DerivedDataToolchainAudit20260916'
ART = WORK / 'artifacts'
CORE = ROOT / 'Sources/MetalErgoCore'
OLD = WORK / 'baseline/Sources/MetalErgoCore'
SEG = WORK / 'experiment/Sources/MetalErgoCore'
FLAGS = ['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos26.5',
         '-O', '-whole-module-optimization']

def compile_probe(name, sources, probe, extra=()):
    command = FLAGS + list(extra) + [str(p) for p in sources] + [str(probe), '-o', str(ART/name)]
    with (HERE/'raw'/f'compile-{name}.log').open('w') as log:
        log.write(json.dumps(command)+'\n'); log.flush()
        sp.run(command, check=True, stdout=log, stderr=log)

def consensus(blake=CORE/'Blake2b.swift', uint=CORE/'UInt256.swift', auto=CORE/'Autolykos.swift'):
    return [blake, uint, auto]

variants = {
    'force-inline': consensus(blake=WORK/'force-inline/Blake2b.swift'),
    'unrolled': consensus(blake=WORK/'unrolled/Blake2b.swift'),
    'manual-load': consensus(blake=WORK/'manual-load/Blake2b.swift'),
    'old-uint': consensus(uint=OLD/'UInt256.swift'),
}
checks = {}
for label, sources in variants.items():
    compile_probe('cpu-'+label, sources, ROOT/'Scripts/benchmark-consensus.swift')
    compile_probe('correctness-'+label, sources, HERE/'correctness-probe.swift')
    lines = sp.check_output([str(ART/('correctness-'+label))], text=True).splitlines()
    checked = 0
    for line in lines:
        if line.startswith('layout,'): continue
        size, digest = line.split(','); size = int(size)
        data = bytes((i*17+size) & 255 for i in range(size))
        assert digest == hashlib.blake2b(data, digest_size=32).hexdigest(), (label, size)
        checked += 1
    checks[label] = dict(independent_blake_vectors=checked, passed=True)
    print(label, 'compiled, independent vectors pass', flush=True)

compile_probe('correctness-E', consensus(*(SEG/n for n in ['Blake2b.swift','UInt256.swift','Autolykos.swift'])),
              HERE/'correctness-probe.swift', ['-D', 'SEGMENTED'])
lines = sp.check_output([str(ART/'correctness-E')], text=True).splitlines()
for line in lines:
    if line.startswith('layout,'): continue
    size, digest = line.split(','); size = int(size)
    assert digest == hashlib.blake2b(bytes((i*17+size)&255 for i in range(size)), digest_size=32).hexdigest()
checks['segmented-independent-buffers'] = dict(independent_blake_vectors=307, passed=True)
(HERE/'raw/cpu-extra-correctness.json').write_text(json.dumps(checks, indent=2)+'\n')

reference = {line.split(',')[0]: line.split(',')[3] for line in sp.check_output([str(ART/'cpu-C')],text=True).splitlines()}
rows=[]
with (HERE/'raw/cpu-extra.csv').open('w') as output:
    writer=csv.writer(output);writer.writerow(['candidate','round','order','variant','workload','iterations','seconds','checksum'])
    for label in variants:
        for cycle in range(3):
            for order, variant in enumerate(['C',label,label,'C']):
                for line in sp.check_output([str(ART/('cpu-'+variant))],text=True).splitlines():
                    workload,iterations,seconds,checksum=line.split(',')
                    assert checksum == reference[workload], (variant,workload,checksum)
                    writer.writerow([label,cycle,order,variant,workload,iterations,seconds,checksum])
                    rows.append(dict(candidate=label,variant=variant,workload=workload,seconds=float(seconds)))
                output.flush()
        print(label, 'ABBA x3 complete', flush=True)
summary={}
for label in variants:
    summary[label]={}
    for workload in reference:
        groups={v:[r['seconds'] for r in rows if r['candidate']==label and r['variant']==v and r['workload']==workload] for v in ['C',label]}
        summary[label][workload]={v:dict(n=len(x),median=statistics.median(x),min=min(x),max=max(x),stdev=statistics.stdev(x)) for v,x in groups.items()}
        summary[label][workload]['speedup']=statistics.median(groups['C'])/statistics.median(groups[label])
(HERE/'raw/cpu-extra-summary.json').write_text(json.dumps(summary,indent=2)+'\n')

with (HERE/'raw/allocations-updated.csv').open('w') as output:
    writer=csv.writer(output)
    writer.writerow(['variant','workload','objects','bytes','result'])
    for label,folder in [('B',OLD),('C',CORE),('E',SEG)]:
        compile_probe('alloc-'+label, [folder/n for n in ['Blake2b.swift','UInt256.swift','Autolykos.swift']], HERE/'allocation-probe.swift')
        import os
        env=dict(os.environ,DYLD_INSERT_LIBRARIES=str(ART/'allocation-counter.dylib'))
        for line in sp.check_output([str(ART/('alloc-'+label))],env=env,text=True).splitlines():
            writer.writerow([label]+line.split(',',3))
print('CPU experiments complete',flush=True)
