# Search versus gather-only ceiling A/B campaign — 2026-08-15

## Goal and gate

This campaign measures whether the consensus search kernel leaves meaningful
compute headroom above its 32 random dataset gathers. The retained
`gather-only` microbenchmark uses the normal index seed, reciprocal-modulo
index distribution, and all 32 dataset gathers, but omits the final
`searchSum` BLAKE2b compression.

The decision gate was fixed before measurement: if the current search kernel
reaches approximately 90% or more of gather-only throughput, search is treated
as memory-latency-saturated and the proposed register-pressure and
memory-level-parallelism experiments are not worthwhile. Only a result clearly
below that threshold would authorize those kernel experiments.

## Configuration

The campaign used the arm64 Release executable from revision
`0b54038d2d3f08b61f32ae59ee4661ec8331550e` on an Apple M4 running macOS
26.6.1 (25G76). The launch-time telemetry recorded `worktree_dirty=true`
because of a pre-existing, unrelated `.gitignore` change; that change was
present before this work, was excluded from both implementation commits, and
did not affect the built sources or executable hash.

The full 216,430,305-element consensus table occupied 6,925,769,760 bytes at
height 1,841,500. One excluded warmup preceded four measured, order-balanced
rounds:

1. `search`, `gather`
2. `gather`, `search`
3. `gather`, `search`
4. `search`, `gather`

Every measured start passed the 50 °C gate without a timeout; measured start
temperatures ranged from 48.60 °C to 49.96 °C. Fixed settings were a 30-second
duration, the `peak` profile, prebuild on, 1,048,576 search nonces per batch,
65,536 prebuild nonces, search threadgroup size 128, dataset threadgroup size
256, the `u32pair-inline-m` dataset kernel, overlap scheduling, 2,097,152-
element cold-build chunks, and 1,048,576-element prefetch chunks.

```sh
DURATION=30 WARMUP_RUNS=1 START_TEMPERATURE_CELSIUS=50 \
Scripts/benchmark-ab.zsh /tmp/ergometal-gather-ab 4 \
  'search:--search-kernel search' \
  'gather:--search-kernel gather-only'
```

The new pipeline telemetry reported a maximum of 1,024 threads per
threadgroup for both selected search pipelines and 1,024 for the build
pipeline in every run.

## Results

Values are raw minimum / median / maximum across four observations. Hashrates
are MH/s, duty and GPU busy values are percentages, and temperatures are
session peaks. Active hashrate is the primary ceiling comparison because it
excludes the identical full-table build interval; effective hashrate is shown
as a wall-clock cross-check.

| variant | active MH/s | effective MH/s | nonces M | search duty | search GPU busy | peak °C |
|---|---:|---:|---:|---:|---:|---:|
| `search` | 2.974568 / 3.107991 / 3.144877 | 1.449015 / 1.516004 / 1.535744 | 89.063 / 93.061 / 94.306 | 48.293 / 48.690 / 49.159 | 61.014 / 64.869 / 67.841 | 71.39 / 74.71 / 75.87 |
| `gather-only` | 2.882893 / 2.951784 / 3.033843 | 1.407242 / 1.442383 / 1.482014 | 86.311 / 88.506 / 91.030 | 48.289 / 48.761 / 49.181 | 56.064 / 58.219 / 59.981 | 73.39 / 74.67 / 75.87 |

The median active-hashrate ratio is:

`search / gather-only = 3.107991 / 2.951784 = 105.292%`

The independent effective-hashrate ratio is 105.104%. The same-round active
ratios were 103.180%, 105.326%, 103.188%, and 105.740%; all four are above
100%. Thus the gather-only microbenchmark did not produce a higher measured
ceiling on this hardware. That unexpected ordering does not weaken the gate:
the current search kernel is well above the required approximately 90% in
every comparison.

Dataset-build medians were closely matched at 30.930 seconds for `search` and
30.955 seconds for `gather-only`. All runs completed one dataset activation,
reported nominal final thermal state, and recorded zero protocol errors.

## Decision

At **105.292%** of gather-only active throughput, the current search kernel
clearly satisfies the `search >= ~90% of gather-only` gate. It is therefore
classified as memory-latency-saturated for the purpose of this optimization
screen.

The register-pressure and four-way memory-level-parallelism experiments from
Task 4 are **not worthwhile (`nicht lohnend`) and were not executed**. No
experimental search kernels were added, no consensus or dataset layout was
changed, and the `search` kernel remains the default.

## Validation and artifacts

- The Release arm64 Xcode build succeeded.
- All 35 Debug Xcode tests passed.
- `Tests/benchmark-ab.zsh` passed.
- Debug and Release replay both retained the consensus hit
  `2d9b2daa19cba01c595881ed4cc12eb24f3417d4b2e76f062ae1f355464deede`.
- All nine snapshots parsed, stopped normally, and contained both 1,024-thread
  pipeline proxies. All nine JSONL histories parsed, began with
  `session_started`, and ended with `session_ended` containing the same
  proxies.

The campaign outputs are retained at `/tmp/ergometal-gather-ab` during this
analysis:

- `results.jsonl` SHA-256:
  `2bd36b92133df36f3df866017c86069f75462c3b9d30acda9f71f8265c57cd2c`
- `summary.json` SHA-256:
  `6214706fb57909f4a018971888a086c3b49686d22bfcc7535c94cc9e803498a7`
- Aggregate SHA-256 of the lexically ordered per-run snapshot checksum
  manifest, including the warmup:
  `637f06660eb90c502621f08902eed3ae3291bda027673cdac7fba10c7fca362d`
- Aggregate SHA-256 of the lexically ordered per-run JSONL checksum manifest,
  including the warmup:
  `c47d00f2279422226cc91be5837949c9881ac3f0340f96abadc0cbe856664d51`
- Release executable SHA-256:
  `f2c1b76cae8c7c16a8cb0bdd6f59b3fce8bee020e2a37bb985c11e39678f2970`
- Release `MetalErgoCore` binary SHA-256:
  `d17e2f91bb1d19a214fffc2406dce28734e5494e5c82cd35299492d0b3c6885e`
- Release Metal library SHA-256:
  `e1fbd7fcbe735e96cb3cadc0b1b822eff1b245676ccc675049e519e1179952ea`
