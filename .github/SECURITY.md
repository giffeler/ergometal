# Security Policy

## Supported Versions

ErgoMetal is experimental software and does not currently have a stable release
series. Security fixes are developed against the latest commit on `main`.

| Version | Supported |
| --- | --- |
| Latest commit on `main` | Yes |
| Earlier commits and builds | No |
| Forks and third-party builds | No |

If a vulnerability also affects a previously distributed notarized binary, the
maintainer will identify the affected artifact and replacement when publishing
the fix. A signature or notarization verifies an artifact's origin and
integrity; it does not make the software free of vulnerabilities.

## Reporting a Vulnerability

Please report suspected vulnerabilities privately by emailing
[dg@gekko.de](mailto:dg@gekko.de) with the subject `ErgoMetal security report`.
Do not disclose a suspected vulnerability in a public issue, discussion, or
pull request before it has been assessed and, where necessary, fixed.

Include as much of the following as is practical:

- the affected commit, build, or artifact name and SHA-256;
- macOS, Xcode, and Apple Silicon model details when relevant;
- a concise description of the vulnerability and its expected impact;
- reproducible steps, a minimal proof of concept, logs, or a proposed fix; and
- whether you have disclosed the issue to anyone else and your preferred
  contact details.

Never send private keys, seed phrases, real pool passwords, account credentials,
or other secrets. ErgoMetal does not need or accept wallet secrets. Use dummy
values and redact unrelated data from logs and screenshots.

The maintainer will make a reasonable effort to:

- acknowledge a report within seven calendar days;
- provide an initial assessment within 14 calendar days; and
- send progress updates while a confirmed vulnerability is being addressed.

These are response targets rather than service-level guarantees. Resolution
time depends on severity, reproducibility, upstream dependencies, and the need
to coordinate a safe release. You may be asked for additional information or
for time to prepare and distribute a fix. Please coordinate public disclosure
with the maintainer. Credit will be offered if desired, but this project does
not currently operate a paid bug-bounty program.

## Security-Relevant Areas

Reports are especially useful when they concern:

- memory corruption, code execution, or crashes triggered by untrusted pool or
  network input;
- certificate-validation or transport-security bypasses;
- unintended exposure of the loopback-only status and metrics service;
- disclosure of pool passwords, wallet addresses, pool URLs, or other data that
  the documented redaction boundaries are intended to protect;
- unauthorized redirection of mining work, payouts, or donation time;
- release-package, signature, notarization, or source-to-binary integrity
  failures; or
- a consensus or share-validation flaw with a concrete security or financial
  impact.

The following are normally not security vulnerabilities by themselves:

- expected GPU, unified-memory, thermal, power, or foreground-performance
  impact from running a miner;
- hashrate, profitability, pool availability, or stale-share performance;
- disclosure of a public payout address supplied for mining;
- behavior in modified forks or unsupported historical builds; or
- issues that require an attacker to already have equivalent local control of
  the user's account and do not cross an additional security boundary.

When in doubt, report the issue privately and explain the security boundary you
believe is affected.

## Research Guidelines

Good-faith research should use systems and accounts you own or are explicitly
authorized to test. Prefer the repository's local replay fixtures, tests, and
mock services over public mining infrastructure. Do not degrade a pool or
third-party service, access other people's data, use social engineering, leave
persistence behind, or destroy data. Stop testing and report immediately if you
encounter sensitive data or affect another user.
