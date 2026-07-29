# MetalErgoMiner

MetalErgoMiner is an independent, research-oriented Autolykos v2 miner for Apple Silicon. It is a native macOS command-line Xcode project whose executable is named `ergometal`.

Autolykos v2 is a memory-hard k-sum construction.

## Status and safety

This is experimental mining software, not financial advice. It can sustain high GPU and unified-memory load, increase power use, and reduce foreground graphics performance. The default `efficiency` profile uses responsive batches and pauses in serious or critical thermal state. macOS does not expose stable unprivileged GPU temperature, fan, or power readings, so the miner does not invent those values.

Only a public payout address is required. Private keys and wallet seed phrases are never accepted. Pool passwords can be supplied through `ERGOMETAL_POOL_PASSWORD`; URLs, addresses, and passwords are excluded from metrics and event data.

## Build

Requirements: Xcode 26.6, macOS 26.6 or later, and an Apple Silicon Mac. Builds target arm64 only; Intel Macs and universal builds are not supported.

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

The miner builds datasets in cancellable chunks, discards stale work when the pool advances, and promotes a completed next-height dataset without rebuilding it. After two interrupted cold builds, catch-up mode deliberately prepares height + 1 so a run cannot remain permanently behind during a burst of short blocks. While prebuilding, search batches are kept short and GPU work is fairly time-sliced so the next dataset meets the block-height deadline; afterwards, the selected profile's larger batch size is restored. Use `--prebuild off` to force single-buffer operation or `--prebuild on` to require enough memory for two buffers.

## Observability

Long-running modes expose a read-only server on `127.0.0.1:4078` by default:

- `/v1/status` — versioned JSON session snapshot
- `/v1/devices` — Metal capability and memory limits
- `/metrics` — Prometheus text format
- `/healthz` — process and solver health

Status and metrics distinguish active search hashrate from effective wall-clock hashrate and expose dataset activation, source, and prebuild progress. The server refuses non-loopback binds. `--stats-file run.jsonl` adds append-only, ISO-8601 event history. A history write failure is reported but never stops mining.

## Independent implementation and provenance

Production code in this repository was designed specifically for Metal and was not copied or translated from an existing CUDA/OpenCL miner. Consensus behavior is checked against:

- the Ergo `AutolykosPowScheme` reference specification;
- the published Autolykos/Ergo PoW paper;
- independently generated BLAKE2b and compact replay vectors committed under `Fixtures/`.

The focused test target covers consensus boundaries, byte order, UInt256 arithmetic, CPU/Metal agreement, metrics redaction, and JSONL validity. It deliberately avoids brittle performance assertions and does not contact public pools.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
