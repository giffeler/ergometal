# MetalErgoMiner

MetalErgoMiner is an independent, research-oriented Autolykos v2 miner for Apple Silicon. It is a native macOS command-line Xcode project whose executable is named `ergometal`.

Autolykos v2 is a memory-hard k-sum construction.

## Status and safety

This is experimental mining software, not financial advice. It can sustain high GPU and unified-memory load, increase power use, and reduce foreground graphics performance. The default `efficiency` profile uses responsive batches and pauses in serious or critical thermal state. The miner records the public macOS thermal state and, when available, best-effort unprivileged Apple Silicon SoC die temperatures. These readings are identified by their source and are not presented as a model-specific GPU sensor.

Only a public payout address is required. Private keys and wallet seed phrases are never accepted. Pool passwords can be supplied through `ERGOMETAL_POOL_PASSWORD`; URLs, addresses, and passwords are excluded from metrics and event data.

## Build

Requirements: Xcode 26.6, macOS 26.5 or later, and an Apple Silicon Mac. Builds target arm64 only; Intel Macs and universal builds are not supported.

Current mainnet datasets require substantial unified memory. Mining uses one height-specific dataset; the default `--prebuild auto` strategy keeps it active while building the next height in a second buffer. It automatically falls back to a single buffer if Metal's recommended working set cannot hold both datasets plus at least 512 MB or 10% headroom.

If Xcode reports a missing Metal compiler, install Apple's matching component once with `xcodebuild -downloadComponent MetalToolchain`.

```sh
xcodegen generate
xcodebuild -project MetalErgoMiner.xcodeproj -scheme MetalErgoMiner build
xcodebuild -project MetalErgoMiner.xcodeproj -scheme MetalErgoMiner test
```

The generated executable is available under Xcode's build products. From Xcode, select the `MetalErgoMiner` scheme and set one of these argument sets:

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

The miner builds datasets in cancellable chunks, discards stale work when the pool advances, and promotes a completed next-height dataset without rebuilding it. Search-only BLAKE2b messages use a fixed-block scalar Metal path, while two independent result-buffer sets keep the next GPU search queued during CPU verification and share handling. After two interrupted cold builds, catch-up mode deliberately prepares height + 1 so a run cannot remain permanently behind during a burst of short blocks. While prebuilding, search batches are kept short and GPU work is fairly time-sliced so the next dataset meets the block-height deadline; afterwards, the selected profile's larger batch size is restored. The default prebuild search cap is 65,536 nonces and can be tuned with `--prebuild-batch-nonces`. Use `--prebuild off` to force single-buffer operation or `--prebuild on` to require enough memory for two buffers.

## Observability

Long-running modes expose a read-only server on `127.0.0.1:4078` by default:

- `/v1/status` — versioned JSON session snapshot
- `/v1/devices` — Metal capability and memory limits
- `/metrics` — Prometheus text format
- `/healthz` — process and solver health

The terminal shows current, active-average, and effective wall-clock hashrate alongside prebuild progress. Status and metrics also expose dataset activation, source, and prebuild progress. The server refuses non-loopback binds. `--stats-file run.jsonl` adds append-only, ISO-8601 event history. During mining, a `statistics_sample` is written every 60 seconds even while a dataset is building; `--stats-interval SECONDS` changes that cadence. Each sample and the final `session_ended` record contain cumulative nonce, timing, dataset, connection, thermal, and share counters, so a long run can be evaluated directly from the JSONL file. Numeric thermal telemetry is stored as `soc_temperature_average_celsius`, `soc_temperature_maximum_celsius`, `soc_temperature_sensor_count`, and `temperature_source`; unsupported systems report `temperature_source=unavailable` without failing the run. A history write failure is reported but never stops mining.

## Independent implementation and provenance

Production code in this repository was designed specifically for Metal and was not copied or translated from an existing CUDA/OpenCL miner. Consensus behavior is checked against:

- the Ergo `AutolykosPowScheme` reference specification;
- the published Autolykos/Ergo PoW paper;
- independently generated BLAKE2b and compact replay vectors committed under `Fixtures/`.

The focused test target covers consensus boundaries, byte order, UInt256 arithmetic, CPU/Metal agreement, metrics redaction, and JSONL validity. It deliberately avoids brittle performance assertions and does not contact public pools.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
