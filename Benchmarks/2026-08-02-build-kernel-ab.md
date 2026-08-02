# Dataset build kernel A/B campaign — 2026-08-02

## Configuration

The campaign measured the three dataset kernels at height 1,841,500 with the
full 216,430,305-element (6,925,769,760-byte) consensus table. It used the
Release executable built from clean worktree revision
`0f56e44495ac2da89b390cc07ebfb65ac55e47a8` on arm64 macOS 26.6:

```sh
DURATION=60 WARMUP_RUNS=1 START_TEMPERATURE_CELSIUS=50 \
Scripts/benchmark-ab.zsh /tmp/ergometal-buildkernel-ab 4 \
  'inline:--dataset-kernel u32pair-inline-m' \
  'u32pair:--dataset-kernel u32pair' \
  'baseline:--dataset-kernel baseline'
```

All 12 measured runs and the excluded warmup completed. Every measured run
passed the temperature gate below 50 °C; no gate timed out. The measured order
was:

1. `inline`, `u32pair`, `baseline`
2. `baseline`, `u32pair`, `inline`
3. `u32pair`, `baseline`, `inline`
4. `inline`, `baseline`, `u32pair`

For each central value below, the two observations within each forward/reverse
round pair were reduced to a pair median, then the two pair medians were reduced
again. Minimum and maximum are the raw four-run extrema. Thus the comparisons
use the complete order-balanced campaign, not any variant's single best run.
Elements/s is derived from the ABBA-pair median wall time.

## Results

Times are seconds and shown as minimum / ABBA-pair median / maximum.

| variant | dataset wall | dataset GPU | prefetch wall | prefetch GPU | cold M elements/s | prefetch M elements/s |
|---|---:|---:|---:|---:|---:|---:|
| `u32pair-inline-m` (current default) | 30.214 / 30.231 / 30.264 | 30.035 / 30.062 / 30.089 | 33.538 / 33.821 / 34.068 | 32.752 / 33.052 / 33.305 | 7.159 | 6.399 |
| `u32pair` | 35.104 / 35.130 / 35.156 | 34.924 / 34.954 / 34.991 | 38.957 / 39.133 / 39.598 | 38.289 / 38.458 / 38.928 | 6.161 | 5.531 |
| `baseline` | 34.738 / 34.768 / 34.809 | 34.559 / 34.596 / 34.648 | 38.443 / 38.945 / 39.691 | 37.778 / 38.264 / 38.992 | 6.225 | 5.557 |

Same-round paired ratios put `u32pair-inline-m` 14.0% below `u32pair` in cold
wall time and 13.8% below it in prefetch wall time (16.2% and 16.0% more
elements/s, respectively). Against `baseline`, the reductions are 13.1% cold
and 12.9% prefetch. `u32pair` itself did not improve on `baseline` in this
campaign.

The current default has therefore already closed a material part of the build
gap. It has not eliminated build contention: applying the paired default-to-
`u32pair` ratios separately to the earlier 7.8-hour run estimates 7,237.4 s of
prefetch builds and 344.5 s of cold builds, or 7,581.9 s total. That is 27.0% of
the 28,099 s run, versus the old 31.3% (`u32pair`) window. In other words, the
current default still costs about 86.2% of the old contention window, while
closing about 4.3 percentage points (1,217.3 s) of it. This is a projection that
holds the historical build counts and run conditions constant.

No build-kernel optimization was attempted.

## Artifact checks

The driver output was retained at `/tmp/ergometal-buildkernel-ab` during the
analysis. Its checksums were:

- `results.jsonl`: `2b8ac5f0a01c5f0b34df61c2d4b947d54a402a8d85f04f0fc5daa60240a8c38e`
- `summary.json`: `fb8470bc4efcfc9e9990aadbaaf583aa7606a607343859d9b40ec2d6a9e0a405`
