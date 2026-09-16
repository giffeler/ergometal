---
name: publish-ergometal-release
description: Build, sign and notarize an ErgoMetal macOS release, publish its download and release information through EmDash on ios.gekko.de, and update the matching GitHub source when requested.
---

# Publish an ErgoMetal release

## Scope and authorization

Use for an authorized ErgoMetal release or download update on ios.gekko.de.
The user has established the infrastructure below; do not ask them to explain
the MCP connection, SSH alias, repository or download route again. A request
to deploy/publish covers the necessary artifact upload, download-route update,
CMS publication and site build/restart. Reuse that authorization throughout
the task. Commit/push when requested; a local code fix alone does not authorize
a release. Preserve unrelated changes, especially `Artwork/` and mining logs.

## Documentation language

Write all documentation in English, including release notes, benchmark reports,
agent and skill instructions, explanatory comments, and chart labels. Translate
existing German documentation while preserving technical meaning, measurements,
identifiers, and commands. Keep original logs and raw measurement records unchanged.
This rule applies regardless of the conversation language.

## Established locations

| Item | Location |
|---|---|
| Source checkout | `/Users/denis/Developer/ergometal` |
| Public source | `https://github.com/giffeler/ergometal` |
| Packaging | `Scripts/package-release.zsh notarized VERSION` |
| Local artifacts | `Distribution/ergometal-macos-arm64-VERSION-notarized.zip` and adjacent `.sha256` |
| Production shell | `ssh gekko` (root) |
| Site checkout | `/var/www/ios-emdash` |
| Site repository | `git@github.com:giffeler/ios-emdash.git` |
| Service | `emdash-ios.service`, unit user `emdash-ios`, loopback port `4323` |
| CMS | `mcp__emdash_ios__*`, collection `pages`, slug `ergometal` |
| Public page | `https://ios.gekko.de/ergometal` |
| Download endpoint | `https://ios.gekko.de/apps/ergometal/download` |
| Route source | `src/pages/apps/ergometal/download.ts` in the site checkout |
| Static archives | `public/apps/ergometal/` in the site checkout |

Recheck live state before relying on these locations. Read `/var/www/AGENTS.md`
and `/var/www/ios-emdash/AGENTS.md` on gekko first, then inspect both Git worktrees,
the route, service and current CMS entry. Remote `rg` may be absent; use `grep`.
The CMS page and `/apps/ergometal/download` are different routes.

## Build and verify locally

1. Choose an unused release version, normally `YYYY-MM-DD`. Keep existing
   versioned archives intact. Run the tests appropriate to the source changes;
   optimized tests use `ENABLE_TESTABILITY=YES`, but the separately packaged
   production executable must not use that override.
2. Inspect the packaging script, Xcode/Swift/Metal versions and actual compiler
   commands. The production build uses Swift `-O`, whole-module optimization,
   Metal fast math, embedded `__TEXT,__metallib`, no Swift/Metal debug or source
   recording information, and stripping. Do not change kernels or tuning merely
   to produce a release.
3. Use the existing Developer ID Application identity and keychain notary
   profile `ergometal-notary` (overrides are documented in the packaging script).
   Never print credentials. Packaging signs with Hardened Runtime and a secure
   timestamp, submits the ZIP, and waits for Apple `Accepted`.
4. Independently verify arm64-only architecture, the embedded Metal library,
   absence of `__DWARF` and source/function debug symbols, strict code signature, only
   system dynamic dependencies, ZIP contents and executable permissions.
   Fetch the notary log and compare its CDHash with the signed binary. A bare
   Mach-O CLI/ZIP cannot be stapled; Gatekeeper's "code is valid but does not
   seem to be an app" result is expected only alongside the accepted ticket.
   Apple's `strip` may insert the `N_OPT` marker `radr://5614542`; it is a
   dynamic-linker compatibility placeholder, not retained source debug data.
   See [Apple's strip implementation](https://github.com/apple-oss-distributions/cctools/blob/main/misc/strip.c).
5. Recompute ZIP and executable SHA-256; never reuse an older release's hashes.
   Run the packaged executable's `devices`, replay fixture and isolated small
   Metal benchmark. Refresh `Distribution/ergometal` from that verified archive.
6. Add `Releases/VERSION.md` with behavior, validation, toolchain and artifact
   identity, and update `README.md` with the current download/checksum/release
   links. Preserve source/license access for GPLv3 redistribution.

## Publish the verified artifact and CMS content

1. Read `content_get(collection: "pages", id: "ergometal")` and
   `content_compare` first. Preserve existing drafts and unrelated blocks.
   Save the read result and old route as rollback evidence outside Git.
2. Upload the versioned ZIP and checksum with SSH/SCP to
   `public/apps/ergometal/`, and verify remote SHA-256 before switching the route.
   Keep prior archives. The route's `binaryArtifact.filename` and `sha256`
   control the download filename and ETag; update both together.
3. Prefer the existing authenticated MCP connection for content. Update only
   the relevant fields of the current `marketing.download` block: release date,
   actual ZIP size, checksum URL and source link. Match blocks by their current
   `_type`/`_key`, preserving other content. Describe implemented behavior in
   English; do not invent performance gains. Link to the exact published source
   commit for this binary when Git publication is part of the request.
4. Use `content_get` -> `content_update` with its fresh `_rev` ->
   `content_compare` -> `content_get` -> `content_publish` with the fresh `_rev`.
   A conflict requires rereading and reconciling the new revision. Do not use
   direct SQLite content/revision edits or create temporary access tokens.
5. For route changes, preserve the previous build for rollback, run site
   `pnpm run typecheck` and `pnpm run build`, then restart only
   `emdash-ios.service`. Do not upgrade dependencies or modify the other sites
   as part of an artifact release. Publish CMS content only when its referenced
   files are reachable. A CMS-only copy edit does not require a rebuild/restart.
6. Verify the public page, stable download and versioned checksum with HTTP 200;
   download the public ZIP and compare its SHA-256 byte-for-byte. Verify HTTP
   206, `Content-Range`, ZIP MIME type, filename and ETag. The legacy
   `?artifact=source` route should still redirect to GitHub with HTTP 308.
   Check service health and the journal. Confirm the CMS has no remaining draft.
   Check the download section on desktop and a 390px mobile viewport when copy
   or layout changes; report the verification actually performed.

## Git publication and completion

Commit only the intended paths in each affected repository when authorized.
The app repository excludes `Distribution/`; the site repository tracks the
versioned ZIP/checksum and route. Publish matching source before exposing the
new binary. After each push verify `HEAD`, `origin/main` and `git ls-remote`
agree. Do not force push or stage unrelated work. Report the live download,
release/checksum, notarization result and both commit IDs.

Stop publication if signing/notarization, artifact checks or deployment checks
fail; repair within the requested scope or restore the previous route/build.
Do not disable verification gates or publish an unverified fallback artifact.
