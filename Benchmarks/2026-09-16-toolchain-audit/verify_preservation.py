#!/usr/bin/env python3
"""Verify original inputs and identify retained review artifacts; read-only to inputs."""
import hashlib
import json
from pathlib import Path
import subprocess as sp
from inspect_artifacts import inspect

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
RAW = HERE/'raw'
initial = json.loads((RAW/'input-manifest.json').read_text())
environment = json.loads((RAW/'environment.json').read_text())
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
checks = {}
for name, expected in initial['inputs'].items():
    path = ROOT/name
    actual = dict(size=path.stat().st_size, sha256=digest(path))
    assert actual == expected, (name, expected, actual)
    checks[name] = actual
cache = Path('/Users/denis/Library/Caches/dev.ergometal/autotune-v1.json')
assert digest(cache) == initial['autotune_cache_sha256'], 'Original tuning cache changed'
head = sp.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'], text=True).strip()
assert head == initial['git_head'], (head, initial['git_head'])
xcode = sp.check_output(['xcode-select','-p'], text=True).strip()
assert xcode == environment['xcode-select -p'], xcode
sp.run(['git','-C',str(ROOT),'diff','--exit-code'], check=True)
sp.run(['git','-C',str(ROOT),'diff','--cached','--exit-code'], check=True)
result = dict(original_inputs=checks, original_cache_sha256=digest(cache),
              head=head, selected_xcode=xcode,
              os=sp.check_output(['sw_vers'],text=True),
              git_status=sp.check_output(['git','-C',str(ROOT),'status','--short'],text=True))
(RAW/'preservation-check.json').write_text(json.dumps(result,indent=2)+'\n')
artifacts = ROOT/'DerivedDataToolchainAudit20260916/artifacts'
names = ['A','B0-old-metal','B','C','C-production','D-old-metal','E-segmented',
         'G-get-accessors','H-full-simd','U-unrolled','Q-search','Q-gather']
(RAW/'final-artifact-identities.json').write_text(json.dumps(
    {name:inspect(artifacts/name) for name in names},indent=2)+'\n')
print('Original binaries, archives, logs, tuning cache, HEAD and selected Xcode preserved.')
