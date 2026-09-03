# Adaptive M4 autotuning verification — 2026-09-03

## Goal and safety gate

This verification exercises the production autotuner rather than establishing
new cross-device defaults. Every candidate was measured in A-B-B-A order and
was eligible only after exact CPU/Metal consensus checks and a median gain of
at least 2%. The conservative M1-compatible configuration therefore remains
the fallback for M1 through M6 and unknown future Apple GPUs.

The tuner classifies hardware and stores independent `efficiency` and `peak`
records by executable SHA-256, Metal architecture, known Apple GPU family,
device name, operating-system build, workload, and normalized overrides. No
result from this M4 run is compiled into the executable.

## Configuration

The runs used an arm64 Release build from revision
`bbca5a961576b042ec164b6b7c5e3a7c10e9c206` plus the uncommitted adaptive
tuning implementation. The executable SHA-256 was
`3df1b3997a8ce246e184ffa9396b1be8be7bae0b6cd2e3d2bdae146e31527aa6`.
The host was an Apple M4 reported as Metal architecture `applegpu_g16g`, Apple
GPU family 9, with 32-thread Search and Dataset execution widths. The OS was
macOS 26.6.2 (25G83), built with Xcode 26.6 (17F113).

Each profile had a 120-second budget. Candidate comparisons used a
4,194,304-element Dataset and Search table. Prefetch throughput used a
4,194,304-element table. The overlap score used a 4,194,304-element active
table, a 16,777,216-element background table, and a fixed 2,097,152-nonce
Search window. The overlap score is a weighted geometric mean of Search and
Dataset throughput, with Search weights of 0.5 for `efficiency` and 0.7 for
`peak`.

## Results

Both profiles completed every candidate stage within budget and were written
to the same locked cache file.

| setting | M1-safe efficiency | tuned efficiency | M1-safe peak | tuned peak |
|---|---:|---:|---:|---:|
| Search threadgroup | 128 | 64 | 128 | 128 |
| Dataset threadgroup | 256 | 256 | 256 | 256 |
| normal batch nonces | 262,144 | 262,144 | 1,048,576 | 1,048,576 |
| prebuild batch nonces | 65,536 | 131,072 | 65,536 | 131,072 |
| cold-build chunk elements | 2,097,152 | 2,097,152 | 2,097,152 | 2,097,152 |
| prefetch chunk elements | 1,048,576 | 1,048,576 | 1,048,576 | 1,048,576 |
| Search pipeline depth | 2 | 2 | 2 | 3 |
| Dataset pipeline depth | 2 | 2 | 2 | 2 |
| complete elapsed time | — | 66.481 s | — | 72.683 s |

For `efficiency`, Search threadgroup 64 cleared the gate by 8.94% at its
comparison stage. Search threadgroups 128 and 256 did not subsequently beat
it. The final 262,144-nonce normal batch beat the temporarily selected
131,072 setting by 9.31%; 524,288 did not clear the gate. For `peak`, Search
threadgroup 128 was retained after the staged comparisons, and pipeline depth
3 beat depth 2 by 15.24%; depth 4 then improved only 1.92% and was rejected.

The 131,072-nonce prebuild batch improved the weighted overlap score by 21.94%
for `efficiency` and 34.26% for `peak`. Neither profile found a qualifying
change to the Dataset threadgroup, either chunk size, or Dataset pipeline
depth. The Peak normal-batch alternatives were all slower than 1,048,576.

## Decision

Use the stored per-binary M4 configurations above. Retain the exact M1-safe
fallback as the starting point for cache misses and future architectures; only
completed qualifying comparisons may replace its fields, while hard failures
in automatic mode return to it. Do not introduce generation-specific shader
branches from these dispatch-only measurements.

The existing gather-only ceiling result also remains insufficient evidence for
an MLP shader variant. The Profile AIR gate confirms that `searchNonces` and
`gatherOnlyNonces` call the same 32-iteration helper containing the same two
`uint4` device-load sites. Machine ISA, load issue history, occupancy limiter
attribution, and instruction-level stalls still require an Xcode Shader
Profiler replay before changing the gather dependency graph.

## Validation and artifacts

- All 52 Core and 12 CLI tests passed.
- The independent Autolykos replay retained hit
  `2d9b2daa19cba01c595881ed4cc12eb24f3417d4b2e76f062ae1f355464deede`.
- A three-height explicit Peak benchmark activated three datasets, promoted two
  from prefetch, and reported no build failures or protocol errors.
- `--autotune auto` loaded the matching Efficiency record with cache provenance.
- `--autotune off` neither read nor created its supplied cache path.
- The gather-only tuning probe completed with exact Dataset consensus and kept
  threadgroup 128 because neither alternative cleared 2%.
- The Release executable is arm64, contains `__TEXT,__metallib`, contains no
  `__DWARF` segment, uses Swift `-O` whole-module optimization and Metal fast
  math, and was built with Metal debug information disabled.
- `Tests/benchmark-ab.zsh`, script syntax validation, and
  `Scripts/inspect-search-air.zsh` passed.

The final cache was retained at
`/tmp/ergometal-m4-autotune-final3-20260903.json` during this analysis:

- cache SHA-256:
  `72a4705dbb3321f60c87f03de7268552e99b5399cb81233c9704e1ffbd33babb`
- embedded Metal library SHA-256:
  `e1fbd7fcbe735e96cb3cadc0b1b822eff1b245676ccc675049e519e1179952ea`

## Notarized production artifact

The production packaging pass created
`Distribution/ergometal-macos-arm64-2026-09-03-notarized.zip`. The ignored
`Distribution` artifact remains local; these identifiers provide the committed
verification record:

- ZIP SHA-256:
  `a11c45d46eb298a55fab0c085f037b85cc9bdac6df4c46e1e56c25d934ef88b5`
- unpacked, stripped executable SHA-256:
  `cb24dc3221ab199c358f44b3ef5f3fce9fba01f1947bbc9128222fc11128901b`
- Developer ID CDHash: `96f191dfa17dd80813e58053534c55e9cd593899`
- Apple notarization submission:
  `96ad0ee8-dd18-4c5d-a924-29c23be4a7e4`
- Apple result: `Accepted`, `Ready for distribution`, no issues
- Gatekeeper result: the code is valid but is not an app, which is the expected
  online-ticket result for this raw command-line executable
