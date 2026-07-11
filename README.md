# MetalErgoMiner

MetalErgoMiner is an independent, research-oriented Autolykos v2 miner for Apple Silicon. It is a native macOS command-line Xcode project whose executable is named `ergometal`.

The project began as an investigation into FLUX/ZelHash. FLUX stopped external proof-of-work mining at block 2,020,000 in October 2025, so the live mining target was changed to Ergo. Autolykos v2 is a memory-hard k-sum construction; it is not an Equihash bucket solver.

## Status and safety

This is experimental mining software, not financial advice. It can sustain high GPU and unified-memory load, increase power use, and reduce foreground graphics performance. The default `efficiency` profile uses shorter batches and pauses in critical thermal state. macOS does not expose stable unprivileged GPU temperature, fan, or power readings, so the miner does not invent those values.

Only a public payout address is required. Private keys and wallet seed phrases are never accepted. Pool passwords can be supplied through `ERGOMETAL_POOL_PASSWORD`; URLs, addresses, and passwords are excluded from metrics and event data.

## Build

Requirements: Xcode 26 or later, macOS 15+, and an Apple Silicon Mac. Current mainnet datasets require substantial unified memory; the miner calculates the exact requirement and refuses allocation unless the Metal recommended working set leaves at least 512 MB or 10% headroom.

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
ergometal mine --pool stratum+tls://POOL:PORT --wallet ERGO_ADDRESS --worker m4
```

`benchmark` uses the consensus table size unless `--table-size` is explicitly supplied for a small diagnostic run. `mine` has no default pool and supports Miningcore-compatible Ergo Stratum v1 over TCP or certificate-validated TLS.

## Observability

Long-running modes expose a read-only server on `127.0.0.1:4078` by default:

- `/v1/status` — versioned JSON session snapshot
- `/v1/devices` — Metal capability and memory limits
- `/metrics` — Prometheus text format
- `/healthz` — process and solver health

The server refuses non-loopback binds. `--stats-file run.jsonl` adds append-only, ISO-8601 event history. A history write failure is reported but never stops mining.

## Independent implementation and provenance

Production code in this repository was designed specifically for Metal and was not copied or translated from an existing CUDA/OpenCL miner. Consensus behavior is checked against:

- the Ergo `AutolykosPowScheme` reference specification;
- the published Autolykos/Ergo PoW paper;
- independently generated BLAKE2b and compact replay vectors committed under `Fixtures/`.

The focused test target covers consensus boundaries, byte order, UInt256 arithmetic, CPU/Metal agreement, metrics redaction, and JSONL validity. It deliberately avoids brittle performance assertions and does not contact public pools.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
