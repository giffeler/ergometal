# MetalErgoMiner

MetalErgoMiner is an independent, research-oriented Autolykos v2 miner for Apple Silicon. It is a native macOS command-line Xcode project whose executable is named `ergometal`.

Autolykos v2 is a memory-hard k-sum construction.

## Status and safety

This is experimental mining software, not financial advice. It can sustain high GPU and unified-memory load, increase power use, and reduce foreground graphics performance. The default `efficiency` profile uses responsive batches and pauses in serious or critical thermal state. The miner records the public macOS thermal state and, when available, best-effort unprivileged Apple Silicon SoC die temperatures. These readings are identified by their source and are not presented as a model-specific GPU sensor.

Only a public payout address is required. Private keys and wallet seed phrases are never accepted. Pool passwords can be supplied through `ERGOMETAL_POOL_PASSWORD`; URLs, addresses, and passwords are excluded from metrics and event data.

## Build

Requirements: Xcode 26.6 with Swift 6.3, macOS 26.5 or later, and an Apple Silicon Mac. The project uses Swift 6 language mode with complete strict-concurrency checking. Builds target arm64 only; Intel Macs and universal builds are not supported.

Current mainnet datasets require substantial unified memory. Mining uses one height-specific dataset; the default `--prebuild auto` strategy keeps it active while building the next height in a second buffer. It automatically falls back to a single buffer if Metal's recommended working set cannot hold both datasets plus at least 512 MB or 10% headroom.

If Xcode reports a missing Metal compiler, install Apple's matching component once with `xcodebuild -downloadComponent MetalToolchain`.

```sh
xcodegen generate
xcodebuild -project MetalErgoMiner.xcodeproj -scheme MetalErgoMiner \
  -configuration Release -derivedDataPath DerivedData \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MetalErgoMiner.xcodeproj -scheme MetalErgoMiner \
  -configuration Debug -derivedDataPath /tmp/ergometal-tests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The canonical release executable is `DerivedData/Build/Products/Release/ergometal`; its sibling `MetalErgoCore.framework` is also required at runtime. Release builds always use `-derivedDataPath DerivedData`, while disposable test products stay under `/tmp`, preventing parallel stale executables inside the repository. From Xcode, select the `MetalErgoMiner` scheme and set one of these argument sets:

```sh
ergometal devices
ergometal replay --fixture Fixtures/autolykos-v2-small.json
ergometal benchmark --duration 60 --height 614399
ergometal mine --pool stratum+tls://POOL:PORT --wallet ERGO_ADDRESS --worker m4 --prebuild auto
```

`benchmark` uses the consensus table size unless `--table-size` is explicitly supplied for a small diagnostic run. `mine` has no default pool and supports Miningcore-compatible Ergo Stratum v1 over TCP or certificate-validated TLS.

For a replayable Metal GPU trace, enable capture and select either the dataset build or the first search batch:

```sh
MTL_CAPTURE_ENABLED=1 ergometal benchmark --duration 10 --height 614400 \
  --gpu-trace search.gputrace --gpu-trace-phase search
```

The output can be large and the destination must not already exist. Open the `.gputrace` file in Xcode's Metal debugger for replay and counter profiling.

`benchmark --search-kernel gather-only` selects a non-consensus microbenchmark that retains the normal index seed, reciprocal-modulo index distribution, and 32 random dataset gathers per nonce but omits the final `searchSum` BLAKE2b compression. The default `--search-kernel search` remains the only search kernel used by mining and replay.

The miner builds datasets in cancellable chunks, discards stale work when the pool advances, and promotes a completed next-height dataset without rebuilding it. Two build command buffers are kept in flight to remove host submission gaps; cancellation stops further submissions and drains already queued chunks before releasing their resources. The default dataset kernel represents exact BLAKE2b 64-bit values as pairs of 32-bit words, which better matches Apple GPU integer hardware without changing consensus output. Dataset prefetch uses a separate Metal command queue so nonce search can continue while the inactive next-height buffer is built. Search-only BLAKE2b messages use a fixed-block scalar Metal path, while two independent result-buffer sets keep the next GPU search queued during CPU verification and share handling.

After two interrupted cold builds, catch-up mode deliberately prepares height + 1 so a run cannot remain permanently behind during a burst of short blocks. While prebuilding, search batches are kept short; afterwards, the selected profile's larger batch size is restored. Measured defaults are 2,097,152 elements per cold-build slice and 1,048,576 per prefetch slice; `--build-chunk-elements` and `--prefetch-chunk-elements` remain available for reproducible hardware-specific A/B tests. The default prebuild search cap is 65,536 nonces and can be tuned with `--prebuild-batch-nonces`. `--dataset-threadgroup-size 128|256`, `--dataset-kernel u32pair-inline-m|u32pair-scalar-m|u32pair|baseline`, and `--dataset-scheduling overlap|serialized` expose the build choices for controlled comparisons. `u32pair-inline-m` is the validated default: it derives the fixed Autolykos M words arithmetically and uses two aligned `uint4` stores per element. `u32pair-scalar-m` additionally exposes the repeated BLAKE2b state and message words as named scalars for controlled A/B measurement. `u32pair` retains the buffer-loaded implementation as an A/B reference, while `baseline` uses native 64-bit BLAKE2b arithmetic. Use `--prebuild off` to force single-buffer operation or `--prebuild on` to require enough memory for two buffers.

For balanced multi-run comparisons, the repository includes a campaign driver that uses rotating forward/reverse (ABBA) round pairs and preserves the raw snapshot and JSONL event history of every run:

```sh
DURATION=30 TABLE_SIZE=33554432 Scripts/benchmark-ab.zsh /tmp/ergometal-ab 3 \
  'overlap:--dataset-scheduling overlap' \
  'serialized:--dataset-scheduling serialized'
```

To compare the default arithmetically generated Autolykos M words against the retained buffer-loaded reference on full consensus tables:

```sh
DURATION=60 Scripts/benchmark-ab.zsh /tmp/ergometal-kernel-ab 3 \
  'neu:--dataset-kernel u32pair-inline-m' \
  'alt:--dataset-kernel u32pair'
```

Variant options replace same-named campaign defaults, so parameters such as `--threadgroup-size`, `--batch-nonces`, and `--build-chunk-elements` can be compared without duplicate-option failures. For example, this full-table campaign measures search occupancy across threadgroup sizes:

```sh
DURATION=60 Scripts/benchmark-ab.zsh /tmp/ergometal-occupancy-ab 3 \
  'tg64:--threadgroup-size 64' \
  'tg128:--threadgroup-size 128' \
  'tg256:--threadgroup-size 256'
```

Omit `TABLE_SIZE` for consensus-sized datasets. `BINARY` selects a non-canonical executable, `HEIGHT` defaults to 1,841,500, and `COOLDOWN_SECONDS` inserts an optional pause between runs. `WARMUP_RUNS` runs the first variant without including it in `results.jsonl`; `START_TEMPERATURE_CELSIUS` gates each run on the miner's own SoC telemetry, with `GATE_TIMEOUT_SECONDS` defaulting to 300 seconds. The generated `summary.json` reports minimum, median, and maximum values; performance changes should be judged from several thermally comparable runs rather than a single best result.

`benchmark --height-interval SECONDS` simulates consecutive pool heights locally. It drains the old search pipeline, promotes the prefetched dataset, starts the following prefetch, and resumes search without contacting a pool. This is the preferred deterministic thermal and scheduler test:

```sh
ergometal benchmark --duration 1800 --height 1841500 --height-interval 120 \
  --table-size 216430305 --profile peak --prebuild on \
  --stats-file ergometal-cycle.jsonl
```

The same option can be enabled in an A/B campaign with `HEIGHT_INTERVAL=120`.

## Observability

Long-running modes expose a read-only server on `127.0.0.1:4078` by default:

- `/v1/status` — versioned JSON session snapshot
- `/v1/devices` — Metal capability and memory limits
- `/metrics` — Prometheus text format
- `/healthz` — process and solver health

The terminal shows current, active-average, and effective wall-clock hashrate together with search duty, prebuild progress, current/session-peak temperature, expected shares, and accepted-share luck. Status and metrics also expose dataset activation, source, and prebuild progress. The server refuses non-loopback binds. `--stats-file run.jsonl` adds append-only, ISO-8601 event history. During mining, a `statistics_sample` is written every 60 seconds even while a dataset is building; `--stats-interval SECONDS` changes that cadence. Each sample and the final `session_ended` record contain cumulative nonce, timing, dataset, connection, thermal, and share counters, so a long run can be evaluated directly from the JSONL file.

Long-term fields include `search_duty_cycle`, total dataset activations and activation time, cold-build and prefetch completed/cancelled/failed counts, prefetch wait time, GPU build time, and explicitly discarded/wasted prefetch work. Command-level cumulative counters separately record build/search command counts, wall time, GPU time, and their non-GPU difference. For the two-deep build pipeline, wall time is the union of overlapping submission-to-completion intervals, so it remains comparable with summed GPU time and does not double-count queued commands. The summed search command fields deliberately retain the latency of every command and therefore measure concurrency at pipeline depths above one. The JSONL fields `gpu_search_command_wall_busy_seconds_total`, `gpu_search_command_gpu_busy_seconds_total`, and `gpu_search_command_non_gpu_busy_seconds_total` instead use unions of overlapping command intervals, making them wall-comparable quantities; matching `ergometal_*` counters are exposed through Prometheus. The campaign's `search_gpu_busy_ratio` is therefore bounded by one, while `search_gpu_concurrency` reports the average in-flight depth. These fields make queueing and driver overhead visible without emitting one JSONL record per command buffer. Numeric thermal telemetry is stored as `soc_temperature_average_celsius`, `soc_temperature_maximum_celsius`, `soc_temperature_session_peak_celsius`, `soc_temperature_sensor_count`, and `temperature_source`; unsupported systems report `temperature_source=unavailable` without failing the run. Every received job records its full 256-bit pool target as `job_target_hex`. The cumulative `shares_expected` counter adds `nonces × target / 2^256` for each completed search batch; `share_luck_ratio` is accepted shares divided by that expectation. The initial `session_started` record captures the performance parameters, architecture, OS, and executable SHA-256. When launched from a Git worktree it also records the launch-time worktree revision and dirty state; the executable hash remains the authoritative binary identity. A history write failure is reported but never stops mining.

## Independent implementation and provenance

Production code in this repository was designed specifically for Metal and was not copied or translated from an existing CUDA/OpenCL miner. Consensus behavior is checked against:

- the Ergo `AutolykosPowScheme` reference specification;
- the published Autolykos/Ergo PoW paper;
- independently generated BLAKE2b and compact replay vectors committed under `Fixtures/`.

The focused test target covers consensus boundaries, byte order, UInt256 arithmetic, CPU/Metal agreement, metrics redaction, and JSONL validity. It deliberately avoids brittle performance assertions and does not contact public pools.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
