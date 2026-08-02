# Dataset scalar-state A/B campaign — 2026-08-02

## Change under test

The experimental `u32pair-scalar-m` kernel keeps the BLAKE2b state and the
high halves of the fixed message words in named scalar values for the 63
dominant full blocks and the final block. The varying first block continues to
use the existing, consensus-tested array implementation. The worktree was based
on revision `838299bdfd375c48aaa4428bf076fcebf63e3205`.

An optimized Metal AIR inspection confirmed that the scalar compression path
was inlined into `buildDatasetU32PairScalarM` and did not introduce another
`[16 x <2 x i32>]` allocation. The only `[8 x <2 x i32>]` and
`[16 x <2 x i32>]` allocations left in that kernel belong to the deliberately
unchanged first block.

## Campaigns

Both campaigns used the Release executable, height 1,841,500, and the full
216,430,305-element (6,925,769,760-byte) consensus table. Prebuild was disabled
so each observation measured one cold build without concurrent search. A
warmup preceded six measured, order-balanced rounds.

The first screen used a 50 °C start gate:

```sh
DURATION=5 WARMUP_RUNS=1 START_TEMPERATURE_CELSIUS=50 \
Scripts/benchmark-ab.zsh /tmp/ergometal-buildscalar-cold-ab 6 \
  'current256:--dataset-kernel u32pair-inline-m --dataset-threadgroup-size 256 --prebuild off' \
  'scalar256:--dataset-kernel u32pair-scalar-m --dataset-threadgroup-size 256 --prebuild off' \
  'scalar128:--dataset-kernel u32pair-scalar-m --dataset-threadgroup-size 128 --prebuild off'
```

The isolation campaign added the old kernel at threadgroup size 128 and used a
stricter 45 °C gate:

```sh
DURATION=5 WARMUP_RUNS=1 START_TEMPERATURE_CELSIUS=45 \
Scripts/benchmark-ab.zsh /tmp/ergometal-buildscalar-isolation-ab 6 \
  'current256:--dataset-kernel u32pair-inline-m --dataset-threadgroup-size 256 --prebuild off' \
  'current128:--dataset-kernel u32pair-inline-m --dataset-threadgroup-size 128 --prebuild off' \
  'scalar128:--dataset-kernel u32pair-scalar-m --dataset-threadgroup-size 128 --prebuild off'
```

For each central value below, the two observations in each forward/reverse
round pair were reduced to a pair median, then the median of the three pair
medians was used. Minimum and maximum are raw six-run extrema. Times are
seconds; elements/s is derived from the ABBA-pair median wall time.

## Results

The 50 °C screen was:

| variant | dataset wall min / pair median / max | dataset GPU min / pair median / max | M elements/s |
|---|---:|---:|---:|
| `current256` | 30.197 / 30.294 / 31.032 | 30.021 / 30.099 / 30.841 | 7.144 |
| `scalar256` | 30.142 / 30.189 / 30.913 | 29.974 / 30.006 / 30.718 | 7.169 |
| `scalar128` | 30.082 / 30.109 / 30.695 | 29.913 / 29.921 / 30.492 | 7.188 |

This put `scalar256` 0.35% below `current256` in wall time and
`scalar128` 0.61% below it. The three same-pair `scalar256` changes were
0.26%, 0.34%, and -0.13%, so the scalar-only direction was not consistent.

The stricter isolation campaign was:

| variant | dataset wall min / pair median / max | dataset GPU min / pair median / max | M elements/s | peak °C pair median |
|---|---:|---:|---:|---:|
| `current256` | 30.085 / 30.088 / 31.459 | 29.890 / 29.896 / 31.248 | 7.193 | 62.04 |
| `current128` | 30.040 / 30.072 / 30.883 | 29.843 / 29.872 / 30.676 | 7.197 | 61.80 |
| `scalar128` | 29.956 / 29.969 / 29.982 | 29.769 / 29.781 / 29.792 | 7.222 | 61.28 |

The first forward/reverse pair contained a slow clock/warm-state transient in
both existing-kernel variants. Its combined apparent improvement was 2.64%.
The two subsequent pairwise improvements were only 0.394% and 0.369%, and the
median-of-pairs result was 0.395%. At the same threadgroup size, scalarization
accounted for 0.341%; changing the existing kernel from 256 to 128 accounted
for only 0.055%.

## Decision

The scalar representation is measurable after warmup, but it does not meet the
2% cold-build gate chosen to justify the extra kernel complexity. The existing
`u32pair-inline-m` kernel and threadgroup size 256 therefore remain the
defaults. The longer prefetch campaign was intentionally not run.

Applying the 0.395% combined reduction to the previously projected 7,581.9 s
current-default contention window would save only about 30.0 s in a 28,099 s
run. The projected window would move from about 27.0% to 26.88% of the run, a
reduction of roughly 0.11 percentage points. This is too small to address the
build-contention problem materially.

## Validation

- The Release arm64 Xcode build succeeded.
- All 32 Debug Xcode tests passed, including exact CPU comparisons for every
  `DatasetKernel` case.
- `Tests/benchmark-ab.zsh` passed without using the GPU.
- Debug and Release replay both retained the consensus hit
  `2d9b2daa19cba01c595881ed4cc12eb24f3417d4b2e76f062ae1f355464deede`.

## Artifact checks

The campaign outputs were retained in `/tmp` during the analysis:

- 50 °C `results.jsonl`: `6b03cfdf171087103cfef454f3f8740ba8b47cc038fb84f6622b93bb3b442e71`
- 50 °C `summary.json`: `05c2b3ed79df837c5add27aa8fdec169aea4a553487cdf200dc05bf61f655574`
- 45 °C `results.jsonl`: `744e039ac7350c8d8ce4a58f774c1b5b71a7e7c232f17c4f7cee26d2eb13c820`
- 45 °C `summary.json`: `c35a1403e6fa7921c2520d043b95ff89220da1fdf9c82ac87f1aedd55c1f9aa5`
