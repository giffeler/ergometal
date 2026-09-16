# Swift 6.4 / Xcode 27: controlled ErgoMetal audit

Completed on 16 September 2026: 49 controlled mining sessions, four additional GPU diagnostic runs, CPU ABBA comparisons, machine-code and allocation analysis, and tested experimental patches.

**Result:** The migration demonstrably accelerates complete CPU hit verification by 3.41×. A mining gain of at least 2% has not been demonstrated; the comparison of unchanged production binaries yields +0.23%. The autotuner's claimed advantage for 4M is not confirmed: both full-Dataset batch ABBA rounds are approximately 1% slower. An additional validated CPU patch improves verification throughput by 8.8%. Production code and defaults were not changed.

## Question and scope

This audit investigates whether the migration improves or degrades miner performance, and whether it enables further demonstrable optimizations. CPU consensus performance, GPU Search, and effective performance under a prescribed job schedule are evaluated separately. Share counts are not a speed metric. No experimental change was adopted during this audit: experiments are retained in separate worktrees or isolated source copies, and reviewable code candidates are preserved as patches.

Starting revision: `28736760cbab5e62c81c2907062c09ad9da4d599`, with an initially clean main worktree. Old source revision: `3e024cc4da34ac21c178be3256c08195ab436e0c`. Production artifacts, existing logs, and the original tuning cache were preserved. No commits, pushes, or releases were made during the measurements. Full Datasets were built exclusively on the GPU; CPU code was used only to verify individual elements and hits.

## Environment and comparison groups

Apple M4, Mac16,1, 10 CPU and 10 GPU cores, 32 GiB; macOS 27.0, build 26A428. AC power, no Low Power Mode. Xcode 27.0, build 27A266a, Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Metal `32023.921`. Swift language mode **6**, SDK **macOS 27.0**, deployment target **macOS 26.5**. These four version settings are not interchangeable. Release uses `-O`, whole-module optimization, complete strict-concurrency checking, and Metal fast math. GPU capture code is excluded from Release. The system-wide Xcode selection was not changed.

A local Swift 6.3.3 / Xcode 26.6 installation is unavailable. The old production build is retained and verified, but cannot be rebuilt here with its original toolchain. The additional B0 group keeps the old Metal library constant; it does not fully isolate the Swift compiler from the SDK, linker, and their build metadata.

The Mach-O load commands confirm **SDK 26.5 and minimum OS 26.5** for A, and **SDK 27.0 and minimum OS 26.5** for B/C/C-production. In particular, the old binary's SDK version cannot be inferred from its Xcode version. Release documentation identifies A as an Xcode 26.6 / Swift 6.3.3 build; both source revisions use language mode 6.

A is also signed with Developer ID and Hardened Runtime, whereas experimental builds are ad-hoc signed. A/B0 therefore is not a pure compiler comparison in this respect either. B0/B and B/C use matching signing modes. The overall evaluation additionally compares A with **unchanged C-production**; the final batch comparison also uses the actual new production binary.

| Group | CPU source revision and build | Embedded Metal library | Purpose |
|---|---|---|---|
| A | Old production binary, 2026-09-12 | Old production | Unchanged reference |
| B0-old-metal | Old source, new toolchain | Extracted from A | Compiler/SDK/linker comparison with a constant Metal library |
| B | Old source, new toolchain | Recompiled | A → B: complete recompilation |
| C | Migrated source, new toolchain | Recompiled | B → C: migration source changes |
| C-production | New production binary, 2026-09-15 | New production | Identity and production comparison |
| D-old-metal | Migrated source, new toolchain | Extracted from A | Additional isolated control artifact |

A has SHA-256 `b18ed68823c6f1fe9837b057395d722392deef97b91e31c99b1a286573743b64`; C-production and `Distribution/ergometal` have `e318af94fc52c7764c4476e542c24c98ab851a5a004c6658ac6e46552a252f79`. C's Metal library exactly matches C-production. Their CPU text segments have the same length and differ only in two bytes of one instruction: the absolute source-path length supplied to `_swift_isEscapingClosureAtFileLocation`. B/B0 and C/D have identical CPU text segments within each pair. Experimental artifacts are ad-hoc signed, not new production releases.

D was built and checked by replay, but was not measured as another performance group. B0/B provides the isolated Metal performance comparison.

Identities and build commands: `raw/comparison-identities.json`, `raw/input-manifest.json`, `raw/build-*.log`, `rebuild.zsh`. Local executable artifacts are retained at `../../DerivedDataToolchainAudit20260916/artifacts`, relative to this report.

The runtime fields `worktree_revision`/`worktree_dirty` describe the checkout found at invocation time. A therefore also reports the current repository HEAD when invoked from this checkout. These fields are not embedded provenance certificates for the binary. This audit relies on executable SHA-256, archived releases, pinned build sources, and separately verified Metal sections.

## Historical logs: verified findings

`analyze_logs.py` groups records by `sessionID`, uses final `session_ended` counters, and checks chronology, base-counter monotonicity, the nonce/batch relationship, and final rates. Each of the four files contains one session. Logs 1/2 were recorded on macOS 26.6.2 and use different threadgroups and pipeline depths; they cannot isolate the OS/driver change.

| Metric | Log 3, A | Log 4, new production |
|---|---:|---:|
| Runtime | 35,337.308 s | 44,485.567 s |
| Active Search throughput | 15.385858 MH/s | 15.124176 MH/s |
| Effective throughput | 11.791118 MH/s | 11.260410 MH/s |
| Search duty cycle | 76.6361% | 74.4530% |
| Cold Dataset work, time budget | 23.3154% | 25.5191% |
| Remaining time budget | 0.0485% | 0.0279% |
| Dataset build, median | 31.452008 s | 33.236942 s |
| Completed / cancelled / resumed builds | 232 / 55 / 3 | 290 / 89 / 5 |
| Median of the highest reported sensor | 64.6749 °C | 73.5104 °C |
| Peak of that sensor statistic | 79.1474 °C | 86.8235 °C |
| Search batch | 1,048,576 | 4,194,304 |

Both runs use a 7,272,058,080-byte Dataset, Search/Dataset threadgroups of 64/256, pipeline depths of 2/2, a build chunk of 2,097,152, and prebuild disabled. The prefetch chunk size also differs, but is unused with prebuild disabled. Neither run has rejected shares, protocol errors, or build failures. Completed builds per hour are similar (23.64 versus 23.47), while cancellations per hour increase from 5.60 to 7.20. Different job schedules and temperatures prevent a controlled version comparison. The larger build time budget explains the lower Search duty cycle; it does not establish the binary as the sole cause.

Timestamps do not move backwards; base counters and final rates are consistent. In log 4, the **derived** counter `gpu_build_command_non_gpu_seconds_total` decreases twice, by 7.96 and 1.46 µs. It is computed from the difference between accumulated wall and GPU times and is therefore not monotonic by construction. This is not an observed reset of the underlying counters. Summed GPU times of overlapping commands must not be treated as serial wall time; utilization must use the union of occupied intervals.

Temperatures come from the existing best-effort IOHID sensor reader. The highest of 24 sensors is not a temperature exclusively attributable to the GPU. `nominal` is an operating-system status, not evidence of constant GPU frequency.

The new, more frequently sampled measurements also show small decreases in `gpu_search_command_non_gpu_busy_seconds_total`. This value is likewise `max(0, Wall-Busy-Union − GPU-Busy-Union)`, not an independently accumulated counter. All final rate, nonce, and busy-time identities remain exactly consistent in the first two 4M runs; their largest observed decreases are approximately 108 µs for the derived build value and 127 µs for the derived Search busy-time value. Every decrease remains visible in the validation output. Declaring these three difference values as Prometheus `counter` metrics is a separate observability concern; their differences should not be interpreted as a CPU time profile without further checking. This audit changes neither those values nor hashrate measurement.

Raw data: `raw/historical-logs.json`, `raw/historical-time-budget.json`.

## CPU code and practical contribution

The CPU comparison builds both source revisions with Swift 6.4 and identical production optimization settings. Three ABBA cycles per comparison provide six observations per variant. Checksums agree.

| Operation | Old source | Migrated source | Speedup |
|---|---:|---:|---:|
| BLAKE2b, 32 bytes, 262,144 iterations | 83.518 ms | 48.386 ms | 1.73× |
| BLAKE2b, 128 bytes, 262,144 iterations | 112.055 ms | 49.508 ms | 2.26× |
| BLAKE2b, 8,200 bytes, 8,192 iterations | 189.795 ms | 52.550 ms | 3.61× |
| Complete Autolykos hit, 256 iterations | 195.308 ms | 56.439 ms | 3.46× |

This confirms real CPU gains from source changes, explicitly not an isolated Swift compiler gain. One hit takes approximately 763 versus 220 µs here, requires 33 individual Dataset-element calculations, and performs 2,148 BLAKE compressions and 32 UInt256 additions. This CPU verification does not construct a complete Dataset.

The pool target in logs 3/4 corresponds to a hit probability of approximately `5.7298e-11`. The built-in short benchmark uses a target that is about **266,305 times easier**, producing a completely different CPU verification workload. Applying the measured CPU costs to the 23 and 35 observed valid hits yields only 12.5 and 19.0 ms of saved verification time across approximately 10 and 12 hours, respectively: less than 0.00005% of runtime in each case. This extrapolates costs for observed valid hits; it does not directly profile every potentially discarded GPU candidate. The miner also refills its GPU pipeline before CPU verification, allowing the work to overlap. A 3.46× CPU verification speedup cannot explain a mining gain of several percent in this workload.

Targeted machine-code and allocation findings:

- BLAKE compression: a 336-byte stack frame and no heap allocation inside the compression body. RawSpan words are actually read with native 64-bit loads. Remaining index checks are visible and were not globally disabled. A Sigma row is read directly from the constant table rather than copied into a complete temporary array.
- RawSpan loads have no alignment requirement and retain bounds checks. Explicit little-endian conversion preserves hash semantics. Spans remain within synchronous accesses to their owners; they are not retained for asynchronous Metal work.
- UInt256: `InlineArray<8, UInt32>` has size/stride 32 and alignment 4. The 32-byte conversion uses direct word loads and byte swapping. The public `limbs` array boundary now allocates an array; this change requires separate assessment. The internal value retains value semantics. Its binary struct representation changes from an array reference to 32 bytes; this is not a published ABI-stable framework.
- MiningWork `borrow`: an isolated replacement with `get` produces a **byte-identical** optimized CPU text segment. No additional ownership/ARC runtime benefit is demonstrated for this WMO build.
- Metal arguments: eight UInt32 words are passed as 32 bytes; `setBytes` copies synchronously, and no Swift array header is passed to Metal. The five calls use lengths of 32/32/8/4/16 bytes in optimized code as well, for the message, target, base nonce, table size, and modulo parameters. The latter are UInt64/UInt32/UInt32 in both Swift and Metal, including explicit padding. CPU/Metal tests verify their actual shared interpretation. Submission is not allocation-free: optimized code still contains three Swift allocation call sites for other objects/closures. The Dataset, result buffers, and selected pipeline remain captured until completion, despite the command buffers using unretained references.
- Allocation diagnostics count only `swift_allocObject` and requested bytes after warmup, not all process/driver allocations. Instrumentation and timing run separately. BLAKE-8,200 falls from 67 objects/10,560 bytes to 1/64. A hit falls from 2,431/630,207 to 176/278,583.

Evidence: `raw/cpu.csv`, `raw/cpu-summary.json`, `raw/cpu-runtime-bound.json`, `raw/allocations.csv`, `raw/blake-compress-arm64.s`, `raw/enqueueSearch-arm64.txt`, `raw/uint256-from-bytes-arm64.txt`, `raw/borrow-codegen.txt`.

At approximately 15 MH/s, a 1,048,576-nonce batch produces about 14.3 Search submissions/completions per active second; 4,194,304 produces about 3.6. The five `setBytes` calls per submission therefore occur approximately 72 or 18 times per active second. This CPU work is more frequent than hit verification but remains small: in the first controlled series, the entire miner, including startup and telemetry, uses approximately 0.4–0.8% of one CPU core. Reducing this cost is a useful CPU improvement, but does not establish a mining gain of several percent without corresponding GPU measurements. Measured non-GPU busy time of Search commands is not a pure CPU profile either.

## Metal compiler and new language capabilities

The old and new embedded Metal libraries differ byte for byte. After disassembly, however, all AIR instructions, globals, and attributes are identical; differences concern SDK/compiler identifiers, filenames, and container offsets. Normalizing only these differences produces the same SHA-256. This compares AIR intermediate code, **not** the final GPU machine code generated by the macOS driver. The empirical B0/B comparison therefore remains necessary. A separate build with explicit Metal `-O3` also left AIR instructions unchanged.

Feature chronology matters: InlineArray and Span originate in Swift 6.2; this migration introduces their use in this project. Swift 6.4 adds or extends borrow accessors, safe RawSpan loading, and iteration over noncopyable values; `@inline(always)` is new in 6.4, while `@specialized` dates to 6.3. New syntax does not establish a performance gain. Iterating over `InlineArray` using its new Iterable conformance requires macOS 27 in the tested toolchain, while the product supports macOS 26.5.

Official sources: [Swift 6.4](https://www.swift.org/blog/swift-6.4-released/), [Apple: What's new in Swift](https://developer.apple.com/videos/play/wwdc2026/262/), [Borrow accessors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0507-borrow-accessors.md), [RawSpan Safe Loading](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0525-rawspan-safe-loading-api.md), [Borrowing Sequence / Iterable](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md), [Xcode 27 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes).

Other capabilities were assessed against measured costs. Swift 6.4 provides safe temporary scratch storage through `withTemporaryAllocation`; E already tests the more substantial step of avoiding the large temporary input and shows no timing gain despite a large allocation reduction. There is therefore no measured reason here to perform another scratch-API rewrite. [Swift describes the new API and its association with SE-0524](https://www.swift.org/blog/swift-6.4-released/).

Metal 4 supports reusable command buffers and reduces CPU/memory submission overhead. This API dates to 2025. The current miner already uses unretained command buffers with resources explicitly retained until completion, and its measured CPU cost is small. A full Metal 4 port was therefore neither presented as a demonstrated optimization nor implemented here. It would be a separate experiment in submission cost and resource lifetime. [Apple: Metal 4 core API](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api), [WWDC25 introduction](https://developer.apple.com/videos/play/wwdc2025/205/).

GPU-private storage and Dataset reuse are not overlooked opportunities either: `MetalSolver` already uses private Dataset buffers, caches matching heights, supports resumed builds, and releases the active Dataset before a new allocation. No new CPU Dataset path was tested. Compilation retained deployment target 26.5; actual execution on 26.5 was not tested on this machine and cannot be inferred from the deployment setting alone.

The GPU Search kernel already uses named BLAKE state scalars and twelve explicit `SEARCH_ROUND` calls for its three fixed message formats. U's additional CPU unrolling gain therefore cannot simply be claimed again as the same GPU optimization. Dataset building and Search also use different specialized hash paths.

## Tuning: a verified weakness in the decision

The tuner itself did not change during migration. Its identity includes the binary hash, so the new binary triggers fresh measurements. Search probes use only 4,194,304 Dataset elements: **128 MiB instead of 7.272 GB**, at height 614,400. At pipeline depth 2, at most 262,144 warmup nonces are followed by just four commands. At the observed approximately 35 MH/s, the 1M probe lasts about 0.12 s and the 4M probe about 0.48 s. One ABBA block with two observations per arm and a required median gain of at least 2% does not test repeatability across independent rounds. The median of two observations is their mean.

| Cache decision | 1M reference | 4M candidate | Ratio |
|---|---:|---:|---:|
| Old binary on macOS 27 | 34.6610 MH/s | 34.7464 MH/s | 1.0025; rejected |
| New binary on macOS 27 | 33.5992 MH/s | 34.6975 MH/s | 1.0327; adopted |

The new binary's absolute 4M probe is actually about 0.14% slower; the positive decision comes from its weaker 1M reference. This demonstrates a fragile decision basis, not yet a causal disadvantage of 4M under sustained load. ABBA mitigates linear time trends but does not eliminate changing load, unequal probe durations, or brief thermal states. The cache stores neither individual A1/B1/B2/A2 observations nor temperatures. Checking for `serious`/`critical` thermal state is not a substitute for a steady-load test. Adoption still requires a measured advantage with the full Dataset under sustained load.

## Controlled mining methodology

A local Stratum peer supplies a deterministic job schedule with the realistic pool target; no external pool is contacted. Each variant starts as a new process. Full Dataset, height 1,873,775, Search/Dataset threadgroups 64/256, depths 2/2, build chunk 2,097,152, prefetch chunk 1,048,576, `u32pair-inline-m`, `overlap` scheduling, prebuild disabled, autotuning disabled, and an explicit batch size. Every measurement uses a new, unused cache path. The first series contains 24 runs in six ABBA blocks, each with 120 s of prescribed job duration including the cold build. Shutdown drains pending work and the final session counters are evaluated.

Before each run, three consecutive temperature samples five seconds apart must be at or below 55 °C. The measurement aborts after 600 s of unsuccessful cooldown. No builds, tests, or other GPU jobs started by this audit run during mining measurements. All variants receive the same telemetry: process CPU time, temperature, one-second Powermetrics samples, and a process inventory every ten seconds. The diagnostic tools themselves add a small, consistently applied overhead.

Existing unrelated processes were not terminated. Notably, `appstoreagent` used approximately one CPU core; terminal, WindowServer, and simulator applications were also active. Powermetrics reports aggregate GPU frequency, residency, and power, not a reliable attribution solely to the miner. The highest active GPU frequency was usually 1,578 MHz. Background load limits the separation of small effects and is retained in the raw data. Positive and negative deviations are judged by the same standard.

Background load was not constant: `appstoreagent` generally used about 95–97% of one CPU core through run 14, declined on its own during run 15, and was at 0% from run 16 onwards. Some slower runs, particularly 14–17, also show approximately 8.9–9.2 W of aggregate GPU power during Search, versus mostly 7.4–8.2 W, while still reporting 1,578 MHz. This is an observed association, not proof of a specific cause. The lower rate cannot automatically be attributed either to a compiler regression or to unrelated GPU work.

`phase_metrics.py` approximately aligns Powermetrics with telemetry phases, excluding a three-second margin around state changes. It uses only the GPU sampler's power figure, not the second GPU estimate also printed by the CPU sampler. Integrated joules estimate energy for the **entire GPU, including background work**; they are not an isolated energy measurement of the miner. Timestamp resolution and sampling intervals limit accuracy.

The effective rate of this controlled cold-build/job scenario is **not long-term pool hashrate**. Two initial smoke tests are retained separately and excluded from analysis; the first required terminating only this audit's own Powermetrics child after a cleanup timeout. Cleanup was corrected before the main series began.

## Controlled results and variability

The table reports the change in the mean of the two B runs relative to the mean of the two A runs within a **complete ABBA block**. Favorable individual samples are not selected, and multiple time windows from one run are not counted as independent replicates.

| Transition | Series / block | Active performance | Effective scenario performance |
|---|---|---:|---:|
| A → B0, new CPU toolchain with old Metal library | 120 s / 1 | −1.994% | −1.951% |
| A → B0 | 120 s / 4 | −2.896% | −3.060% |
| A → B0, cooler starts | 180 s / 1 | +0.213% | +0.577% |
| B0 → B, recompiled Metal library | 120 s / 3 | +0.194% | +0.164% |
| B0 → B | 120 s / 6 | −0.244% | −0.281% |
| B → C, migration source changes | 120 s / 2 | +0.624% | +0.456% |
| B → C | 120 s / 5 | +2.083% | +2.313% |
| A → C, overall comparison of rebuilt artifacts | 180 s / 2 | +0.437% | +0.461% |
| C → H, additional pipeline guarantee | 180 s / 3 | +0.010% | −0.013% |

The initially negative A/B0 blocks remain part of the results. Their regression does not reproduce in the cooler repeat. Similarly, the single positive B/C block above 2% is insufficient to claim that the adoption threshold has been met: the other block is well below it. Neither a gain nor a regression has been demonstrated for the Metal library change.

Descriptive variability in the first series follows; this is not a causal estimate from pooling unbalanced groups:

| Group | n | Active MH/s, median | Minimum–maximum | Standard deviation between runs |
|---|---:|---:|---:|---:|
| A | 4 | 14.97361 | 14.60707–15.07483 | 0.20592 |
| B0 | 8 | 14.96871 | 14.29691–15.06884 | 0.33903 |
| B | 8 | 14.99045 | 14.52730–15.30124 | 0.21481 |
| C | 4 | 15.12279 | 14.94437–15.24352 | 0.13393 |

The build medians for these groups are 32.309 / 32.273 / 32.171 / 32.321 s. The longer 180-second series uses a predefined start limit below 45 °C, with actual starts at 43.3–44.8 °C and build times of approximately 31.66–32.73 s. An earlier single A sample starting at 43.09 °C is retained separately as preparation (`raw/followup-mine`); the tighter temperature policy was established before evaluating its result (`raw/followup-policy.json`). This sample was not retrospectively assigned to an ABBA block.

The small samples and changing background load do not support a narrow equivalence claim or causal attribution to tenths of a percent. The supported conclusion is narrower: **none of the mining advantages examined here repeatedly exceeds the 2% threshold.** All individual values and block comparisons are retained.

### Unmodified production binaries and complete batch comparison

The final series uses both verified production binaries, a 45 °C start limit, five minutes per run, and the same job change after 150 s. Each run builds two complete Datasets. This captures both a cool start and a build following Search. All jobs and final counters are archived.

“Warm” here means a build at the next height following GPU load, not a cache hit or a shortened Dataset build.

| ABBA comparison | Active change | Effective change |
|---|---:|---:|
| Old → new production binary, both 1M | +0.234% | +0.239% |
| New binary: 1M → 4M, round 1 | −0.972% | −1.078% |
| New binary: 1M → 4M, round 2 | −0.993% | −1.151% |

| Group within its comparison | n | Active MH/s: median; min–max; SD | Effective MH/s: median; min–max; SD |
|---|---:|---|---|
| Original A, runs 1/4 | 2 | 15.14186; 15.10510–15.17862; 0.05199 | 11.93560; 11.90373–11.96747; 0.04507 |
| Original C, runs 2/3 | 2 | 15.17733; 15.17348–15.18119; 0.00545 | 11.96407; 11.96325–11.96490; 0.00116 |
| C with 1M, runs 5/8/9/12 | 4 | 15.13602; 14.81821–15.21847; 0.17738 | 11.90422; 11.63127–11.99665; 0.16076 |
| C with 4M, runs 6/7/10/11 | 4 | 15.02230; 14.50252–15.16903; 0.29321 | 11.80366; 11.33763–11.96270; 0.27073 |

The production comparison does not reproduce a material Dataset regression: A takes 31.700/31.658 s cold and 31.762/31.758 s warm; C takes 31.654/31.679 s cold and 31.747/31.739 s warm. The corresponding GPU times range from 31.446 to 31.480 s. Under these conditions, the substantially slower historical log 4 cannot be reproduced as a property of the new binary.

The larger batch reduces CPU overhead but provides no advantage on the complete Dataset in either ABBA block. The repeated negative direction of approximately 1% is a warning about the tuning decision, but with substantial variability and two blocks it does not cleanly isolate a thermal effect. Switching back to 1M would not constitute a demonstrated mining gain above 2% here either. The assumed **+3.27% advantage in the cached decision is not confirmed**; this evidence does not support treating 4M as a robust optimization.

Operating conditions change despite similar starting temperatures. With the same 4M binary, the rate rises from 14.503 to 15.169 MH/s between runs 10 and 11; mean aggregate GPU power during Search simultaneously falls from 8.918 to 7.259 W. The reported active GPU frequency remains essentially at 1,578 MHz, with residency close to 100%. In run 10, both the **cold** build (32.681 s) and the subsequent warm build (32.844 s) are slow; in run 11, both are fast again (31.686/31.721 s). The 1M runs 8/9 also have slower builds. This contradicts the simple attribution that “4M slows only the subsequent build.” The miner drains outstanding Search commands before the next Dataset build, so overlapping residual Search work is not a suitable explanation here.

Sensor peaks in the batch runs are 72.67–75.23 °C for 1M and 73.87–75.87 °C for 4M, with medians of 74.19 and 75.03 °C respectively. These remain well below the historical peak of 86.82 °C. Quantitatively explaining the long-term difference between logs 3/4 using this batch measurement alone would therefore be unjustified. Raw data: `raw/production-batch-mine`; derived summaries: `raw/production-batch-summary.json`, `raw/production-batch-phases.json`.

### Sustained load and energy observations

The unchanged new production binary also runs for 900.695 s with a 4M batch and jobs at 0/300/600 s. It processes 12,230,590,464 nonces with 805.352 s of active Search: **15.186646 MH/s active, 13.579056 MH/s effective, 89.414% Search duty cycle**. The higher effective rate compared with the five-minute runs follows from the longer job interval, rather than an additional binary improvement.

| Complete build | Wall time | GPU time |
|---|---:|---:|
| Start | 31.679 s | 31.469 s |
| After 300 s | 31.746 s | 31.450 s |
| After 600 s | 31.753 s | 31.459 s |

The three longer Search sections reach approximately 15.205 / 15.228 / 15.144 MH/s. Their sensor medians rise from 61.16 through 62.68 to 63.40 °C. The rate therefore does not decline sharply and continuously, but a strictly thermally stationary state has not been demonstrated. The overall sensor peak is 75.79 °C, and the median across all statistics samples is 62.76 °C. This run replaces neither a measurement lasting several hours nor the missing directly paired 1M sustained run under the same conditions.

Grouped Search counters are published after 16 completed commands or on a flush. With 4M, that represents about 4.4 s of work per update here. The two-second telemetry can therefore alternate between zero increments and larger jumps. The descriptive time windows use paired nonce/Search-time differences and have only approximate time boundaries; they are not independent repeats. Final `session_ended` values remain authoritative for the whole run. No smoothing, capping, or modification of these counters was introduced in the miner.

In phases that can be assigned reliably, Powermetrics reports mean **GPU power of 18.045 W during builds** and **7.235 W during Search**, both at an active frequency of 1,578 MHz and 100% GPU residency. Builds can therefore materially shape sensor peaks. Across approximately 899.2 s of sampled intervals, the estimate is about **7.51 kJ of aggregate GPU energy**. This estimates energy for the entire GPU, not the miner in isolation or power measured at the wall. The miner itself uses 2.42 CPU-seconds, equivalent to 0.269% of one CPU core over the session.

The Powermetrics task sampler was also enabled here with `--show-process-gpu`, separately from the ABBA performance comparisons. It reports only 0 GPU-ms/s for all 375 observed process names, including the miner in all 886 samples. This output is unusable for attributing GPU load. No specific unrelated process is therefore identified as the cause of the aggregate power changes.

Raw data: `raw/sustained-mine`; analysis: `raw/sustained-summary.json`, `raw/sustained-windows.json`, `raw/process-gpu-summary.json`, `raw/all-phase-metrics.json`. Figure: [PNG](sustained-profile.png), [SVG](sustained-profile.svg), generated by `plot_sustained.py` from these unchanged data. GPU residency measures device active time, not separate ALU or DRAM utilization.

### Validation of all measurements

The mining analysis covers **49 completed sessions**, twelve ABBA blocks plus the sustained run, totaling 9,566.589 s of session time. `raw/all-runs.csv` contains individual rates, wall/GPU build times, CPU times, temperatures, and GPU observations. `raw/all-campaign-summaries.json` contains all variability measures and block effects.

`raw/controlled-session-validation.json` documents consistent final rate/nonce/busy-union identities, monotonic base counters, and consistent chronology for all 49 sessions. There are no protocol errors, rejected shares, or failed cold builds. It also records **1,247 decreases in the three derived difference values**, distributed across all sessions; the largest is 0.467 ms. These findings are explicitly retained and distinguished from the independently accumulated base counters. They are not grounds for discarding negative results.

## Validated additional CPU experiments

All timing comparisons use three ABBA cycles, checksums, and the same toolchain; allocation instrumentation runs separately. All changes below remain experimental.

| Experiment | Result | Assessment |
|---|---|---|
| Two-part BLAKE input without the 8,200-byte concatenation, E | Hit time essentially unchanged; 143 objects/6,927 bytes instead of 176/278,583 | Real allocation reduction; no demonstrated timing or mining gain |
| Replace `borrow` with `get`, G | CPU text segment identical | No demonstrable runtime gain from the accessor syntax in this build |
| Iterable iteration over Sigma rows, F | Hit verification about 0.6% faster; requires macOS 27 deployment | Below 2%; does not justify raising the deployment target |
| Deployment target 27 only | Negligible difference | No demonstrated gain |
| `-target-cpu apple-m4` | Negligible difference | Does not justify restricting the CPU type |
| Swift 6.4 `@inline(always)` on compression | Hit verification about 1.2% faster | Below 2%; do not adopt |
| Twelve explicit BLAKE rounds with constant indices, U | Hit verification 1.094× faster; independent repeat 1.105× | Reproducible additional CPU gain; no GPU/mining demonstration |
| Safe byte-by-byte loads instead of RawSpan words | Hit time 2.298× longer; BLAKE-8,200 time 2.514× longer | RawSpan word access makes a demonstrated substantial contribution |
| Revert only UInt256 to its old Array storage | Hit verification about 0.6% slower | Overall CPU hit cost is dominated by BLAKE; no large isolated UInt256 timing gain demonstrated |

For candidate U, median hit time drops from 55.604 to 50.829 ms per 256 verifications in the first comparison, and from 54.937 to 49.726 ms in the repeat. BLAKE-8,200 throughput improves by 8.9% and 10.8% respectively. Explicit rounds remove dynamic selection from the Sigma table without indiscriminately disabling necessary checks or changing the hash function. The cost is longer, repetitive source code. The original table remains traceable in the patch; independent vectors cover block boundaries in particular. This gain also occurs on the infrequent CPU verification path and does not justify claiming increased mining performance.

These explicit rounds are not a Swift 6.4 innovation. They demonstrate additional source-level potential under the current toolchain; a matching comparison with the old compiler is unavailable because it is not installed.

A stricter cross-check links the harness against the actual `libMetalErgoCore.a` libraries built with production options and without testability. It uses height 1,873,775 and the full index space of 227,251,815 elements, but computes only the elements needed for individual hits on the CPU. Again, three ABBA cycles per comparison produce:

| Comparison using the production-built core | Reference, 256 hits | Candidate, 256 hits | Speedup |
|---|---:|---:|---:|
| Old → migrated source, both Swift 6.4 | 187.080 ms | 54.823 ms | 3.412× |
| Migrated code → explicit rounds U | 54.782 ms | 50.352 ms | 1.088× |

The additional CPU gain therefore persists beyond the microbenchmark built separately from three source files. The linked production cores take approximately 731 versus 214 µs per hit; U takes about 197 µs in the second comparison. BLAKE-8,200 gains 9.1% from U here. Raw values, variability, and checksums are in `raw/cpu-linked.csv` and `raw/cpu-linked-summary.json`; reproduction: `cpu_linked.py` with `benchmark-consensus-full.swift`.

Disassembly of the actual Release binary confirms both the effect and its cost: the compression body grows from 362 instructions/1,448 bytes to 1,599 instructions/6,396 bytes, and its stack frame from 336 to 432 bytes. The number of separate `brk` trap sites falls from 19 to three; constant indices allow the compiler to prove checks unnecessary and remove them. No check was disabled through an unsafe compiler flag. Neither compression body contains a heap allocation; their only call is the exceptional `__stack_chk_fail` path. Evidence: `raw/blake-compress-production-C.s`, `raw/blake-compress-production-U.s`, `raw/production-compress-codegen.json`.

U also passes the CPU/Metal comparison on the complete Dataset using the **production build without testability**: 30 Search cases and five Dataset elements. The more realistic CPU cost extrapolation estimates approximately 11.9/18.1 ms of verification time saved by the migration in logs 3/4. U saves only about another 0.40/0.61 ms for the hits observed there. The previously described bound on the practical mining contribution therefore still holds; see `raw/cpu-runtime-bound-linked.json`.

E and U each pass 97 tests in Debug and optimized Release. Separate probe programs compare 307 different BLAKE input lengths against Python `hashlib.blake2b(digest_size=32)`. E additionally tests many split points in both shared and **physically separate** buffers, ensuring that unaligned RawSpan access is actually exercised. Existing tests cover consensus vectors, UInt256 value semantics/JSON, and CPU/Metal comparisons. All experimental builds retain Swift 6 language mode and deployment target 26.5, except for the explicitly separate Iterable/target-27 experiment.

The separate getter test confirms the public API boundary: `UInt256.limbs` requires no new allocation in the old code, but allocates one object with 64 requested bytes in the new code. An internal caller using this getter frequently should use the fixed word representation; this is not a reason to silently remove the valid public Array API.

The API is also not fully behaviorally identical for **invalid widths**: the old stored public Array property could be set to any length after initialization, whereas the new setter requires eight words. The previous synthesized decoder could likewise decode such invalid arrays; the new decoder throws an error. This strengthens the UInt256 invariant but must be identified as an intentional compatibility change. Valid JSON with eight words, Array return values, single-word mutation, and independent value copies are covered by existing tests.

Patches: `segmented-input.patch`, `unrolled-permutations.patch`, `force-inline-compress.patch`, `manual-word-load-control.patch`, `borrow-accessor-control.patch`. Measurements: `raw/cpu-extra.csv`, `raw/cpu-extra-summary.json`, `raw/cpu-unrolled-repeat.csv`, `raw/cpu-extra-correctness.json`, `raw/allocations-updated.csv`, `raw/test-*.log`.

## Validated Metal pipeline candidate

H enables `threadGroupSizeIsMultipleOfThreadExecutionWidth` only on an additional Search pipeline, selecting it only when the threadgroup size and nonce count satisfy that guarantee. Incomplete or odd-sized groups continue to use the original pipeline. This is an older Metal API, not an Xcode 27 innovation. [Apple documents the required guarantee and undefined results when it is violated](https://developer.apple.com/documentation/metal/mtlcomputepipelinedescriptor/threadgroupsizeismultipleofthreadexecutionwidth).

The patch passes 97 Debug and 97 Release tests, including additional CPU/Metal cases for complete and partial groups. A further test on the complete Dataset passes 30 Search cases and five element comparisons. However, in the controlled 180-second ABBA comparison against C, H achieves only **+0.010% active and −0.013% effective performance**. This does not justify the additional pipeline and selection logic: **reject as a performance change**. The negative experiment is retained in full in `full-simd-pipeline.patch` and `raw/followup45-mine`.

## Additional GPU diagnosis: final hash step

Q uses the same unchanged Metal library as the new production binary. Only the CLI **benchmark** target is set to zero, preventing the differing candidate/CPU verification load of the normal easy benchmark target from determining the comparison. `Q-search` and `Q-gather` are two byte-identical copies of the same Release build; only `--search-kernel` differs. The mining command and consensus verification are unchanged. The controller permits the diagnostic kernel only in benchmark mode.

The experiment uses the complete Dataset and the same parameters as before: four ABBA runs, each with 90 s of Search **after** the cold build, starting at 42.69–43.89 °C. All four final sessions are consistent and report zero verified candidates. Regular Search reaches 15.16871/15.03103 million nonces/s; `gather-only` reaches 15.13762/14.96457. The medians are 15.09987 and 15.05109 respectively, with standard deviations of 0.09735 and 0.12237 million nonces/s. The ABBA effect is **−0.323%**, showing no demonstrated throughput advantage.

`gather-only` retains both index hashes, Dataset access, modulo calculation, and summation; it omits only the final BLAKE hash and compares the sum instead. It is therefore **neither a pure memory bandwidth test nor a valid mining variant**. These figures are diagnostic nonce-processing rates, not an optimization result. The derived effective diagnostic rate is retained in the raw data but is not interpreted as pool performance.

Total GPU power during Search is 7.268/7.606 W in the two full Search runs and 6.716/7.147 W in the diagnostic variants. This shows lower reported power when computation is removed, but system load prevents precise isolated energy attribution. In this experiment, the remaining index/gather pipeline limits throughput more than the mere presence of the final hash step; this is an **inference from the experiment**, not a breakdown of GPU instruction costs or proof of a pure memory limit. For further GPU work, counters or profiling of the remaining index/gather pipeline would be more informative than another CPU BLAKE microbenchmark.

The benchmark records temperatures during the cold build differently from mining mode. Its reported sensor peaks are therefore not compared with mining campaign peaks as equivalent thermal measurements. Both diagnostic arms use the same mode. Artifacts: `benchmark-zero-target-control.patch`, `raw/diagnostic-identities.json`, `raw/diagnostic-gather`, `raw/diagnostic-summary.json`, `raw/diagnostic-validation.json`, `raw/diagnostic-phases.json`. Q is solely a diagnostic artifact, not a candidate for adoption.

## Reproduction

Run from the repository at `/Users/denis/Developer/ergometal`. Check the Xcode version and OS build against `raw/environment.json`; do not change the system-wide Xcode selection. Output directories for mining campaigns must be **new**. Do not overwrite existing results. Run measurements sequentially, without concurrent builds, tests, or GPU work.

```sh
audit=Benchmarks/2026-09-16-toolchain-audit
zsh "$audit/rebuild.zsh" /tmp/ergometal-audit-new

# 24 reference runs: two ABBA blocks for each of three separate transitions.
python3 "$audit/campaign.py" "$audit/raw/reproduction-main-new" \
  --artifacts /tmp/ergometal-audit-new/artifacts --mode mine \
  --sequence A,B0-old-metal,B0-old-metal,A,B,C,C,B,B0-old-metal,B,B,B0-old-metal,A,B0-old-metal,B0-old-metal,A,B,C,C,B,B0-old-metal,B,B,B0-old-metal \
  --duration 120 --max-temperature 55

# Original releases and two ABBA blocks for batch size.
python3 "$audit/campaign.py" "$audit/raw/reproduction-production-batch-new" \
  --artifacts /tmp/ergometal-audit-new/artifacts --mode mine \
  --sequence A,C-production,C-production,A,C-production:1048576,C-production:4194304,C-production:4194304,C-production:1048576,C-production:1048576,C-production:4194304,C-production:4194304,C-production:1048576 \
  --duration 300 --job-interval 150 --max-temperature 45

# Cooler control series, using the retained A/B0/C/H artifacts here.
python3 "$audit/campaign.py" "$audit/raw/reproduction-followup-new" \
  --artifacts DerivedDataToolchainAudit20260916/artifacts --mode mine \
  --sequence A,B0-old-metal,B0-old-metal,A,A,C,C,A,C,H-full-simd,H-full-simd,C \
  --duration 180 --max-temperature 45

# Sustained load with the unchanged new production binary.
python3 "$audit/campaign.py" "$audit/raw/reproduction-sustained-new" \
  --artifacts /tmp/ergometal-audit-new/artifacts --mode mine \
  --sequence C-production:4194304 --duration 900 --job-interval 300 \
  --max-temperature 45 --process-gpu

python3 "$audit/summarize.py" "$audit/raw/reproduction-production-batch-new"
python3 "$audit/phase_metrics.py" "$audit/raw/reproduction-production-batch-new"

# CPU repeat using the retained production-built B/C/U libraries.
python3 "$audit/cpu_linked.py" \
  --work DerivedDataToolchainAudit20260916 \
  --output "$audit/raw/cpu-linked-reproduction-new"

# Build and validate U separately from scratch: tests, complete GPU Dataset,
# individual CPU/Metal comparisons, and independent hashlib vectors.
zsh "$audit/reproduce_unrolled.zsh" /tmp/ergometal-unrolled-new

# Separate GPU diagnosis with target 0; not a valid mining optimization.
zsh "$audit/reproduce_diagnostic.zsh" /tmp/ergometal-diagnostic-new
python3 "$audit/campaign.py" "$audit/raw/reproduction-diagnostic-new" \
  --artifacts /tmp/ergometal-diagnostic-new/artifacts --mode benchmark \
  --sequence Q-search:1048576:search,Q-gather:1048576:gather-only,Q-gather:1048576:gather-only,Q-search:1048576:search \
  --duration 90 --max-temperature 45
```

`campaign.py` sets all other parameters explicitly and leaves the original tuning cache untouched. The local peer, target, test wallet value, messages, and job heights are fully defined in the script. For each run, `*.metadata.json` contains the exact miner invocation and binary hash, `*.events.ndjson` the session telemetry, `*.peer.ndjson` the actual local job timings, `*.gate.ndjson` the cooldown, `*.power.txt` the raw Powermetrics data, `*.processes.txt` the background processes, and `*.stderr` the process timing data.

For experimental patches, create another worktree at `28736760cbab5e62c81c2907062c09ad9da4d599`, apply the relevant patch there with `git apply`, and use the Xcode commands documented in `validate_experiments.zsh` or `post_followup.zsh`. Debug and Release are tested with testability; the subsequent measurement artifact is rebuilt with `ENABLE_TESTABILITY=NO`. The `build-*.log`/`test-*.log` files preserve the commands actually executed and their results. The existing experimental worktrees and artifacts are retained for review.

`post_followup.zsh` records an executed local sequence, including the reversal of experiment G at that time; that reversal has already been completed. Use `reproduce_unrolled.zsh` for a fresh U rebuild. The newly assembled reproduction scripts were checked for syntax and patch applicability; their build/test steps match the separately logged executions. They were not rerun as an entire campaign. Data analysis alone requires only the Python standard library. The optional figure was generated with Matplotlib 3.11.2: `uv run --no-project --with matplotlib==3.11.2 python Benchmarks/2026-09-16-toolchain-audit/plot_sustained.py`.

The original CPU harness is `Scripts/benchmark-consensus.swift`; compiler flags and source combinations are in `cpu_experiments.py`. The stricter check with production libraries and the full index space is in `cpu_linked.py`; this reproduction command requires a new output directory and also places its programs there. For the additional historical CPU controls, `cpu_experiments.py` documents the local audit setup; change its output/artifact paths to new paths before repeating it. `correctness-probe.swift` checks the numerous input lengths; `full-dataset-correctness.swift` compares CPU/Metal results on the complete GPU Dataset. `allocation-counter.c` and `allocation-probe.swift` are diagnostic programs only and do not belong in a mining artifact.

## Assessment and decisions

The migration applies worthwhile CPU optimizations. Their benefit on the consensus path is real, supported by production-built code, independent vectors, allocation diagnostics, and machine code. **A reproducible mining performance gain of at least 2% from Swift 6.4 / Xcode 27 has not been demonstrated on this M4.** This does not imply that further gains are impossible.

| Item | Decision | Rationale |
|---|---|---|
| Existing BLAKE/RawSpan/InlineArray migration | Retain | Complete CPU hit verification is 3.41× faster in the production-built core; substantial allocation reduction; no confirmed mining regression |
| MiningWork `borrow`, direct fixed Metal arguments, Release without capture | Retain, with limited performance claims | Correct implementation; `borrow` generates the same code as `get` here; no separate mining gain demonstrated |
| New Metal library | No rollback based on these data | AIR arithmetic operations are identical; isolated comparisons are near zero; final GPU machine code was not compared |
| CPU patch U: fixed BLAKE rounds | Recommend adoption as a CPU-only optimization | +8.8% throughput even with the production library; validation passed. Costs: +4,948 bytes of compression code, +96 bytes of stack, and more source code. Low priority for the miner; no hashrate promise |
| CPU patch E: segmented input | Defer | Far less requested memory, but no reproducible speedup; additional API/test overhead |
| Metal patch H | Reject as a performance change | +0.010% active performance does not justify an additional pipeline/branch |
| Iterable / deployment 27 / M4 CPU flag / `@inline(always)` | Do not adopt | No robust advantage, with added compatibility costs in some cases |
| Public UInt256 getter | Preserve the API; document the allocation regression | Returning an Array now allocates; already avoided in the hot Metal path |
| Autotuning adoption of 4M | Rework the decision process | Short sample +3.27%; two complete ABBA blocks approximately −1%. Does not robustly meet the existing 2% threshold |

The tuner should validate its finalists on the complete Dataset after warming up and in multiple independent balanced rounds, retain individual values and temperature histories, and keep the reference when the 2% threshold is not met repeatedly. This conclusion does not justify silently changing the existing cache or production defaults. The binary fingerprint should remain; weakening it would merely suppress necessary revalidation.

### What can be causally attributed

- **Source code:** The large CPU gain is isolated because both versions use the same new compiler. Its contribution to this mining workload is very small. The additional source changes do not produce a repeatedly sufficient GPU/mining advantage.
- **Swift compiler:** The A/B0 bridge holds source code and Metal constant but also changes the SDK, linker, and signing type. The old toolchain is unavailable locally. A pure compiler contribution therefore cannot be stated as a separate percentage. The initial negative effect does not reproduce.
- **Metal compiler:** B0/B varies the Metal library with identical CPU text; the two ABBA effects are +0.194% and −0.244%. This demonstrates neither a gain nor a regression. AIR identity does not guarantee identical final GPU instructions.
- **macOS/GPU driver:** Constant in all controlled comparisons. Logs 1/2 contain too many other changes to establish OS causality. The driver's contribution to differences from older operating systems remains undetermined.
- **Autotuning:** The changed binary hash triggers the same short tuning logic again. The documented cached advantage of the larger batch mainly results from a weaker reference sample and is not confirmed in the complete comparisons.
- **Operating conditions:** Variations of several percent occur even with identical binaries and batch sizes. Similar starts, `nominal` status, and nearly identical reported GPU frequency do not rule this out. Job changes, build/Search time budgets, and thermal history matter; their individual causal contributions cannot be fully separated here.

The historical effective difference of −4.501% decomposes mathematically into −1.701% active performance and −2.849% Search duty cycle, combined multiplicatively. This identity (`raw/historical-rate-decomposition.json`) is a **decomposition of performance measures**, not an attribution of those percentages to the compiler, temperature, or tuning.

### Specific measurements still needed

1. Repeat the batch comparison on a system that the user is otherwise leaving idle: at least six complete ABBA blocks, both variants with longer Search phases and the same job schedule. Record starting temperature, fan/power state, and individual rates; do not automatically terminate background processes. The existing controller can repeat the same sequences with new output folders. Objective: determine whether the approximately 1% negative direction of 4M persists with less variability.
2. For **pure compiler separation**, use a separately available Xcode 26.6 installation and compare the same source revision, Metal library, signing, and production flags; treat SDK dependency as another group if necessary. No system-wide selection change is required. This separation cannot be established here without the additional toolchain.
3. If slow builds recur, pair long 1M/4M Search phases immediately before identical builds while collecting useful GPU hardware counters or a separate Metal profile. The already slow cold build in run 10 shows that the preceding Search batch alone is insufficient as an explanation. Perform profiling separately from reference rate measurements.

These unresolved causes do not change the current adoption decision: a positive mining effect must not be selected from variability, just as a compiler regression must not be inferred from two unfavorable blocks.

## Retained artifacts and final verification

- **Individual measurements and variability:** `raw/all-runs.csv`, `raw/all-campaign-summaries.json`; unchanged events, Powermetrics output, process inventories, and invocation metadata in the respective campaign folders.
- **CPU measurements:** `raw/cpu-linked.csv`, `raw/cpu-linked-summary.json`, the other `cpu-*.csv`/JSON files, and allocation diagnostics. These are separate from mining and GPU diagnostic results.
- **Correctness:** `raw/test-*.log`, `raw/independent-correctness.json`, `raw/cpu-extra-correctness.json`, `raw/correctness-H-full-dataset.txt`, `raw/correctness-U-full-dataset.txt`, `raw/controlled-session-validation.json`, and `raw/diagnostic-validation.json`.
- **Review patches:** particularly `unrolled-permutations.patch`, `segmented-input.patch`, and `full-simd-pipeline.patch`; negative control patches are also retained. Q is separately labeled as invalid for production mining.
- **Identities and preservation:** `raw/final-artifact-identities.json`, `raw/preservation-check.json`. At measurement completion, SHA-256 hashes and sizes of the original production binaries/archives and all four logs still matched the input manifest exactly, as did the original tuning cache. HEAD remained `28736760cbab5e62c81c2907062c09ad9da4d599`, and the selected Xcode was unchanged. No tracked production code was changed, and no changes were staged, committed, pushed, or released during the measurements.

The executable comparison artifacts and isolated worktrees remain under `DerivedDataToolchainAudit20260916`. At measurement completion, this new audit folder was the only untracked item in the main worktree. Intermediate files with `partial` in their names, smoke tests, and preparation runs are retained for traceability but are excluded from the 49 mining sessions. `SHA256SUMS` covers the final files in this audit folder; verify it from that directory with `shasum -a 256 -c SHA256SUMS`.

After measurement completion, the report and figure labels were translated into English and the documentation was prepared for the separately requested commit and push. The measurement revision, raw records, production artifacts, and experimental patches remain unchanged. The preservation snapshot above describes the audit's state before this documentation update.
