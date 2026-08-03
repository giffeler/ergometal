# Dataset scheduling full-table A/B campaign — 2026-08-03

## Motivation and observability

The 16 h 13 min production run in `ergometal-long.jsonl` completed normally at
11.704 MH/s effective and 12.014 MH/s active-average hashrate. It accepted all
42 submitted shares against 39.17 expected shares, had no rejected or stale
shares, no protocol errors, and no dataset build failures. Its session peak was
80.75 °C and the final macOS thermal state was nominal.

The dominant throughput cost was dataset preparation. Build command wall time
was 15,323.3 s, or 26.23% of the 58,409.2 s session, and 90 prefetch waits cost
1,117.9 s. The old event schema exposed summed search command wall and GPU
times, but not the already-collected unions of overlapping search intervals.
That prevented a wall-clock-safe separation of actual GPU occupancy from
queueing and command concurrency.

The observability change under test adds these cumulative JSONL fields:

- `gpu_search_command_wall_busy_seconds_total`
- `gpu_search_command_gpu_busy_seconds_total`
- `gpu_search_command_non_gpu_busy_seconds_total`

Matching `ergometal_*` Prometheus counters were added. The non-GPU value is
clamped to zero and computed from the two busy unions. The historical JSONL was
left unchanged; the new fields were verified in every A/B event log.

## Configuration

The A/B used the Release build from worktree revision
`1bacc9e81a0fb7fdc64e49f54141dbe16565e446` plus the observability worktree
changes. It measured the full 216,430,305-element (6,925,769,760-byte)
consensus table. Each observation used a 1,800-second benchmark duration and
simulated a height change every 120 seconds, producing 15 dataset activations.
One excluded warmup preceded four order-balanced rounds in ABBA order:

1. `overlap`, `serialized`
2. `serialized`, `overlap`
3. `serialized`, `overlap`
4. `overlap`, `serialized`

All starts passed a 50 °C temperature gate. The remaining fixed settings were
the `peak` profile, prebuild on, `u32pair-inline-m`, 1,048,576 search nonces,
65,536 prebuild nonces, search threadgroup size 128, dataset threadgroup size
256, 2,097,152-element cold-build chunks, and 1,048,576-element prefetch
chunks.

```sh
DURATION=1800 HEIGHT_INTERVAL=120 WARMUP_RUNS=1 \
START_TEMPERATURE_CELSIUS=50 GATE_TIMEOUT_SECONDS=600 \
Scripts/benchmark-ab.zsh \
  /tmp/ergometal-overlap-serialized-full-20260803 4 \
  'overlap:--dataset-scheduling overlap' \
  'serialized:--dataset-scheduling serialized'
```

## Results

The table reports raw minimum / median / maximum across all four observations.
Hashrates are MH/s, duty and busy ratios are percentages, times are seconds,
and temperatures are session peaks.

| variant | effective MH/s | active MH/s | search duty | prefetch wall s | prefetch GPU s | search GPU busy | non-GPU busy s | peak °C |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `overlap` | 11.193 / 11.456 / 11.493 | 11.398 / 11.662 / 11.699 | 98.204 / 98.227 / 98.259 | 492.282 / 504.209 / 517.928 | 479.760 / 491.857 / 505.200 | 99.741 / 99.900 / 99.908 | 1.649 / 1.797 / 4.663 | 77.47 / 79.03 / 80.51 |
| `serialized` | 11.012 / 11.397 / 11.490 | 11.416 / 11.591 / 11.687 | 96.483 / 98.337 / 98.348 | 454.926 / 457.048 / 459.828 | 451.557 / 453.687 / 455.500 | 91.236 / 93.895 / 98.402 | 28.748 / 108.470 / 157.739 | 78.11 / 78.71 / 87.22 |

The raw medians put `overlap` 0.513% ahead in effective hashrate and 0.612%
ahead in active hashrate. The same-round effective-hashrate changes for
`overlap` were +0.593%, -0.240%, +3.974%, and -1.553%; their median is only
+0.176%. The first uncontaminated ABBA pair independently gives +0.175%.

Round 3 `serialized` contained a clear transient: telemetry paused for up to
15.88 s, the session peak rose to 87.22 °C versus at most 80.51 °C in every
other observation, duty fell to 96.48%, and effective hashrate fell to
11.012 MH/s. It remains in the raw results. Removing only that observation
changes the median comparison to +0.270% for `overlap`; comparing the remaining
arithmetic means instead gives `serialized` +0.252%. The sign therefore depends
on estimator, while every robust effect estimate is far below 1%.

`serialized` did make builds faster: median prefetch wall time fell 9.35% and
prefetch GPU time fell 7.76%; the cold-build wall and GPU medians fell 6.75%
and 5.03%. Median peak temperature was effectively unchanged (-0.32 °C).
However, its intentional separation of search and build produced more search
command non-GPU busy time and lower GPU busy coverage. The saved build time did
not turn into a reproducible effective-hashrate gain.

Every measured run completed all 15 activations with zero prefetch waits, zero
cold or prefetch build failures, zero protocol errors, and a final nominal
thermal state.

## Decision

There is no credible effective-hashrate winner in this campaign. The observed
effect is smaller than run/order variation and does not meet the existing 2%
gate for changing a performance default. `overlap` therefore remains the
default. `serialized` remains useful as the isolation reference and as a way to
minimize individual dataset build latency, but this full-table campaign does
not justify switching production mining to it.

## Validation and artifacts

- The Release arm64 Xcode build succeeded.
- All 32 Debug Xcode tests passed; the focused statistics suite passed 8/8.
- `Tests/benchmark-ab.zsh` passed.
- Every campaign JSON and JSONL file parsed successfully and ended with a
  `session_ended` event.
- Release executable SHA-256:
  `6042a31f0b7b4ebe4f0642439bf501647a506c931aed769c4e8fa4efc5732dbe`
- Release `MetalErgoCore` framework SHA-256:
  `0b284111cb46041d01052942b10c7747f633a82c2044610574d00bce29edb663`

The campaign outputs were retained in
`/tmp/ergometal-overlap-serialized-full-20260803` during analysis:

- `results.jsonl`:
  `3f1c48edce083f1c48217642fc3e13b5bb96378527a44d2d74461bef0f468cda`
- `summary.json`:
  `13a3f3133d97eb88c53ec9ace6e15911aee13a430984654cd4cbd8345b3b2643`
