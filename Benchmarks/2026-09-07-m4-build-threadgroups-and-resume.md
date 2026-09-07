# M4 full-table build threadgroups and reconnect resumption — 2026-09-07

## Scope

This campaign checks the newly available 32-thread Dataset candidate against
64, 128, and the existing 256-thread fallback using the production-sized table.
A separate local Stratum test verifies that a reconnect reuses completed cold-
build chunks while invalidating the old pool job.

The tested executable is the notarized 7 September 2026 release, SHA-256
`4f6e5c38ec45eab6f0ec48b75bf4b43898b5adcd4951dcd78210e122eaf9abdb`.
It was built from the local changes on top of `ce81d0e`. The host is an Apple
M4, `applegpu_g16g`, Apple GPU family 9, with a 32-thread execution width and
32 GiB unified memory. The embedded Metal library is byte-identical to the
5 September release.

## Full-table campaign

The height is 1,867,794, matching the end of the supplied production log. Its
consensus Dataset contains 227,251,815 elements and occupies 7,272,058,080 bytes.
Each observation performs one complete cold build followed by five seconds of
Search, with prebuild disabled. Autotuning is disabled and all execution values
are explicit. Every build uses 2,097,152-element chunks and pipeline depth 2;
the Search threadgroup is 128, the batch is 1,048,576 nonces, and Search depth
is 2. The candidate size is also applied to the compute pipeline descriptor.

```sh
BINARY=Distribution/ergometal HEIGHT=1867794 DURATION=5 WARMUP_RUNS=1 \
START_TEMPERATURE_CELSIUS=50 GATE_TIMEOUT_SECONDS=300 \
Scripts/benchmark-ab.zsh /tmp/ergometal-build-threadgroups-20260907 4 \
  'tg256:--dataset-threadgroup-size 256 --prebuild off' \
  'tg32:--dataset-threadgroup-size 32 --prebuild off' \
  'tg64:--dataset-threadgroup-size 64 --prebuild off' \
  'tg128:--dataset-threadgroup-size 128 --prebuild off'
```

One excluded warmup preceded 16 measured builds. The measured orders were
256/32/64/128, 128/64/32/256, 32/64/128/256, and 256/128/64/32. Every start,
including warmup, passed the 50 °C maximum-sensor gate; none timed out.

For each central time below, the two observations in each forward/reverse
round pair were reduced to a median, then the median of those two pair values
was used. Minima and maxima are the four raw observations. Throughput gains
are the median of the two paired baseline/candidate time ratios.

| Dataset threads | wall min / paired median / max, s | paired GPU time, s | paired throughput gain vs 256 |
|---|---:|---:|---:|
| 256 | 31.642 / 31.664 / 31.686 | 31.453 | baseline |
| 32 | 31.549 / 31.597 / 31.615 | 31.407 | +0.212% |
| 64 | 31.625 / 31.639 / 31.651 | 31.441 | +0.078% |
| 128 | 31.614 / 31.633 / 31.659 | 31.438 | +0.097% |

The 32-thread gains in the two separate round pairs were +0.195% and +0.229%.
No alternative meets the existing 2% adoption gate. Keep 256 as the conservative
fallback; 32 remains available to the device-specific tuner and explicit CLI
selection. The short automatic preflight retains its bounded 4,194,304-element
probe rather than introducing full-table work at every startup.

A final smoke test exercised that automatic preflight with the other seven
execution values fixed and a separate temporary cache. It completed all
Dataset comparisons in 7.128 seconds, including the new 32-thread candidate.
The 32-thread throughput ratio was 1.007509; the 64- and 128-thread candidates
were slightly slower. The tuner correctly retained 256 and wrote only its
isolated test cache.

All 16 observations completed exactly 109 build commands, one cold build,
zero cancelled or failed cold builds, and a final nominal thermal state. Every
event log parsed successfully, contained one chronological session, used the
expected executable SHA-256, and ended with exactly one `session_ended`.
These are build-latency measurements; the five-second Search window is not a
long-term effective-mining-throughput comparison.

## Full-table reconnect test

A loopback-only Stratum server authorized a job at the same height, disconnected
six seconds after offering it, then authorized a new job at that height after
reconnection. The released executable used `--prebuild off`, 256 Dataset
threads, 2,097,152-element chunks, build depth 2, and 4,194,304-nonce Search
batches. A target of 1 prevented ordinary share submissions; no public pool was
contacted. The process received SIGINT after it resumed Search.

| Observation | Result |
|---|---:|
| reconnects | 1 |
| cancelled / resumed / completed cold-build attempts | 1 / 1 / 1 |
| reused completed elements | 46,137,344 |
| reused complete chunks | 22 |
| total build commands across both attempts | 109 |
| cumulative Dataset build work | 31.667 s |
| final activation call | 25.092 s |
| completed Search nonces | 88,080,384 |
| protocol errors / failed builds | 0 / 0 |

The 109 commands are exactly the number required to build this table once:
none of the 22 retained chunks was recomputed. All 21 completed Search commands
were present in the final nonce counter. The log ended with exactly one final
event and the process exited successfully. Dataset build work excludes the
reconnection pause and includes both attempts without double-counting.

Automated tests separately verify exact CPU/Metal Dataset agreement on both
sides of resumed chunk boundaries, all build pipeline depths from 1 through 4,
repeated interruptions, changed heights and sizes, opting out of preservation,
and rejection of partial data by Search. A coordinator test confirms that the
old pool job remains invalid after the Dataset has been resumed.

## Artifacts

The measured raw artifacts remain local and are not committed:

- `/tmp/ergometal-build-threadgroups-20260907/results.jsonl`:
  `f6cf57da1240931712016bf21d5a77210a23e1ffb045a8a7f6d19715711c1f01`
- `/tmp/ergometal-build-threadgroups-20260907/summary.json`:
  `441a3f2932abc54f10e336de479fc9aa1c0d82f31e9755f03973eaa908b90ef4`
- `/tmp/ergometal-20260907-reconnect/`: local integration log and result JSON.

The production archive and its checksum are listed in
[the release notes](../Releases/2026-09-07.md).
