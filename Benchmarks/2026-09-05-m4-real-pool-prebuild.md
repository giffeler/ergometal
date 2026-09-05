# M4 real-pool prebuild observation — 2026-09-05

## Goal and evidence boundary

This report compares long-running real-pool mining with `--prebuild auto` and
`--prebuild off` on one Apple M4. It evaluates effective wall-clock throughput,
Dataset cost, thermal stability, connection behavior, and whether daytime and
overnight observations differ materially.

The runs used the same executable and resolved execution values, but they were
not an order-balanced A/B campaign. Pool jobs and chain heights arrived at
different rates. The results therefore support a device- and configuration-
specific operating recommendation, not a new cross-device default.

## Configuration

All three sessions used the notarized 4 September 2026 arm64 executable from
revision `d2041dfee1bdc6d488f0dd5391150dbcead64eee`. Its executable SHA-256 was
`9e6ed664d97a2290cfa23cfa41d9554d64fdd8726f7f1721b13dce3e438fb14b`.
The worktree was clean and every session reported the same Apple M4,
`applegpu_g16g`, Apple GPU family 9, and macOS 26.6.2 (25G83).

The fixed resolved values were:

| setting | value |
|---|---:|
| profile | `peak` |
| Search threadgroup | 128 |
| Dataset threadgroup | 256 |
| normal batch nonces | 524,288 |
| prebuild batch nonces | 65,536 |
| cold-build chunk elements | 2,097,152 |
| prefetch chunk elements | 1,048,576 |
| Search pipeline depth | 4 |
| Dataset pipeline depth | 2 |

The sessions connected over certificate-validated TLS to the same public pool,
used no donation window, and wrote cumulative statistics every 240 seconds.
Wallet and pool credentials were absent from all event logs.

## Production results

Times below are Europe/Berlin local time. Active hashrate divides completed
nonces by actual Search time. Effective hashrate divides them by complete
session wall time and therefore includes Dataset work and reconnects.

| run | local window | duration | active MH/s | effective MH/s | Search duty | distinct heights/h | accepted / expected | reconnects | sample mean / peak °C |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `auto` | 4 Sep, 07:00–09:51 | 2:50:55 | 11.128 | 10.714 | 96.28% | 34.40 | 7 / 6.30 | 2 | 57.81 / 78.99 |
| `off`, daytime | 4 Sep, 12:43–15:29 | 2:46:01 | 15.435 | 11.556 | 74.87% | 31.80 | 6 / 6.60 | 3 | 56.77 / 78.51 |
| `off`, overnight | 4 Sep 20:47–5 Sep 05:58 | 9:10:39 | 15.396 | 11.629 | 75.53% | 29.86 | 25 / 22.01 | 7 | 55.84 / 78.43 |

The two `off` sessions totalled 11 h 57 min, 499,320,356,864 nonces, and
32,413.63 seconds of Search. Their weighted result was 15.405 MH/s active,
11.612 MH/s effective, and 75.38% Search duty. Against the single `auto`
session, the observed effective difference was +8.39% for `off`.

The daytime and overnight `off` sessions differed by -0.25% active hashrate
and +0.63% effective hashrate. The overnight duty cycle was 0.66 percentage
points higher while its distinct-height rate was 6.12% lower. The evidence does
not show a meaningful time-of-day effect on Search throughput; the change in
effective throughput is better explained by how often new height-specific
Datasets were required.

## Dataset accounting

| counter | `auto` | `off`, daytime | `off`, overnight |
|---|---:|---:|---:|
| Dataset activations | 125 | 112 | 324 |
| prefetched activations | 95 | 0 | 0 |
| cached activations | 28 | 44 | 90 |
| completed cold builds | 2 | 68 | 234 |
| cancelled cold builds | 1 | 21 | 41 |
| failed cold builds | 0 | 0 | 0 |
| prefetch waits | 23 | 0 | 0 |
| total prefetch wait | 295.25 s | 0 | 0 |

The overnight `off` run's 234 completed cold builds had a 31.413-second median,
31.548-second 90th percentile, and 32.595-second maximum. Completed builds used
7,361.62 seconds. Cancelled builds added 706.13 seconds, bringing total cold-
build wall time to 8,067.75 seconds, or 24.42% of the session.

Its wall-time accounting left no unexplained stall: 33,038.76 elapsed seconds
minus 24,955.66 Search seconds and 8,067.75 cold-build seconds leaves 15.35
seconds for startup, reconnects, and shutdown. The weakest four-minute window
was 6.10 MH/s effective, but it contained 127.61 seconds of Dataset work across
three completed and two cancelled builds. It was not a thermal decline.

During `auto`, background prefetch kept Search duty high but strongly contended
with the active Search kernel. Statistics sampled while a prefetch was active
reported 1.33–2.03 MH/s current Search, versus 14.35–15.77 MH/s without an
active prefetch. That contention reduced the active average enough that the
higher duty cycle did not recover the observed effective throughput.

## Thermal and connection behavior

Every thermal sample in all three sessions was `nominal`. The daytime and
overnight `off` runs had nearly identical session peaks, and the overnight
Search median was unchanged between its first and second halves. There is no
observed thermal-throttling or long-term Search degradation signal.

Across the three sessions, all 12 `remote closed connection` events occurred
exactly 1,800 seconds after the latest accepted share or connection. New jobs
had arrived 2–320 seconds before those closes, and every reconnect plus pool
authorization completed within one or two seconds. This is consistent with an
intentional pool-side share-idle policy, not a silently dead TCP path. There
were no protocol errors and no rejected or stale shares.

## Decision

For this exact M4, executable, `peak` profile, and pool, use `--prebuild off`
when maximum measured effective throughput is the priority. The two `off`
observations agree across daytime and overnight operation, and the longer run
contains no unexplained stalls or thermal decline.

Keep `--prebuild auto` as the general default. Its overlapping Dataset path is
still the safer cross-device behavior, and the real-pool comparison did not
control height cadence or alternate variants in the same time windows. Before
changing the program default, repeat a long crossover campaign with both modes
in reversed time-of-day order and extend it to other Apple GPU generations and
the `efficiency` profile.

Judge future mining comparisons by effective hashrate, Search duty, Dataset
build/cancellation time, and distinct heights per hour. Accepted shares are too
sparse and random to serve as the performance metric.

## Local observation artifacts

The raw JSONL files remain ignored under `Distribution/` and are not committed.
Their hashes identify the exact inputs used for this report:

- `ergometal.jsonl`: 504 lines,
  SHA-256 `4b5ac386e96b683d94781c8ceacc1a0c0d08531b3835a3c782cdcfd2c198064e`
- `ergometal_noprebuild.jsonl`: 305 lines,
  SHA-256 `77fd3bc4ca0c51e6397727c1cea5dffcc1bd13ce3f4526df0bd61829cac8dd33`
- `ergometal_noprebuild2.jsonl`: 877 lines,
  SHA-256 `b864d3bc4b5b1e0fdebf7728f45ff93427197cc1e441bf0c3a496e530969a5ff`

Each file parsed as JSONL, contained one chronologically ordered session, and
ended with `session_ended`. Combined results contained 38 accepted shares,
zero rejected or stale shares, zero protocol errors, and zero Dataset build
failures.
