<!--
SPDX-FileCopyrightText: 2026 Catalan Lover <catalanlover@protonmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Draupnir CI in a Box

CI in a Box is the single execution path for the `mjolnir.yml` test jobs.
It provides the same targets for local execution and GitHub execution:

- `check`
- `build-lint`
- `unit`
- `integration`
- `appservice-integration`
- `all`
- `version`

Published release artifacts are supply-chain hardened and include SBOM/provenance evidence.

## Key guarantees

The Key Guarantees are important to the purpose of why we are doing things the way we do them.

- Strict DinD: the CI runtime starts its own Docker daemon inside the container and allows us full flexibility.
- Cross-OS safe dependencies: host `node_modules` are never used.
- Linux-native install path: dependencies are always installed inside the Linux container runtime.
- Cache-first execution: npm, cargo, and Docker graph are persisted in named volumes to avoid painfully long compile times.

## Prerequisites

- Docker Desktop (Linux containers enabled)
- A local checkout of `Draupnir`

You must explicitly provide the Draupnir checkout path to the launcher.

## Local usage (Windows)

Run from this repository root:

```powershell
./ci-box.ps1 check -Workspace C:\path\to\Draupnir
./ci-box.ps1 build-lint -Workspace C:\path\to\Draupnir
./ci-box.ps1 unit -Workspace C:\path\to\Draupnir
./ci-box.ps1 integration -Workspace C:\path\to\Draupnir
./ci-box.ps1 appservice-integration -Workspace C:\path\to\Draupnir
./ci-box.ps1 all -Workspace C:\path\to\Draupnir
```

Useful flags:

- `-Image draupnir/ci-box:dev`
- `-SourceMode local-build|published-tag`
- `-Rebuild`
- `-PublishedRepository ghcr.io/the-draupnir-project/ci-box`
- `-PublishedTag <tag>`
- `-Version`
- `-DebugLogs`
- `-NoCache`

By default, the launcher reuses an existing local image tag and only builds if the image is missing.
Use `-Rebuild` when you want to force a new image build.

You must explicitly choose a source mode for non-check targets:

- `local-build`: use/build local image
- `published-tag`: pull published image by tag and run by resolved digest

When `-SourceMode published-tag` is set, `-PublishedTag` is required.

For published tags that are not semver-like (for example `latest`, `main`, branch tags), CI in a Box verifies freshness by checking the local digest before pull and after pull, then reports whether the tag digest changed.

Semver-like tags (for example `v1.2.3`, `1.2.3-rc.1`) are treated as immutable pins and are resolved directly to digest after pull.

Registry support policy (current):

- `ghcr.io` is the only supported registry for published-tag workflows.
- Other registries may still be used experimentally, but behavior differences are out-of-scope and related issues are not considered valid bugs for this project.

Integrity gate (default on in `published-tag` mode):

- pulled tags must resolve to `PublishedRepository@sha256:<64-hex>`
- execution fails if digest resolution is missing or repository/digest format does not match
- runtime always executes using resolved digest ref, never a floating tag ref

Example (tag pin):

```powershell
./ci-box.ps1 build-lint -Workspace C:\path\to\Draupnir -SourceMode published-tag -PublishedTag v0.1.0
```

Example (local build mode):

```powershell
./ci-box.ps1 build-lint -Workspace C:\path\to\Draupnir -SourceMode local-build
```

## Local usage (Linux/macOS)

```bash
chmod +x ./ci-box
./ci-box check /path/to/Draupnir
./ci-box build-lint /path/to/Draupnir local-build
./ci-box unit /path/to/Draupnir local-build
./ci-box integration /path/to/Draupnir local-build
./ci-box appservice-integration /path/to/Draupnir local-build
./ci-box all /path/to/Draupnir local-build
```

To force a rebuild in bash mode, set `CI_BOX_REBUILD=1` for the command:

```bash
CI_BOX_REBUILD=1 ./ci-box build-lint /path/to/Draupnir local-build
```

To use a published pinned image in bash mode:

```bash
CI_BOX_PUBLISHED_TAG=v0.1.0 ./ci-box build-lint /path/to/Draupnir published-tag
```

Print launcher version in bash mode:

```bash
./ci-box version
```

For non-semver tags (including `latest`), the launcher checks digest freshness before and after pull and reports if it changed.

## Versioning support

Root launchers read their version from the repository root `VERSION` file.

- Bash launcher: `./ci-box version` or `./ci-box --version`
- PowerShell launcher: `./ci-box.ps1 version` or `./ci-box.ps1 -Version`

Release process integration:

- bump the value in `VERSION` (for example `0.2.0`)
- commit/tag/release as normal
- both launchers will report the new version automatically

## Published artifacts (GitHub Actions)

For images that are distributed this repository publishes GHCR artifacts:

- Multi-architecture image builds (`linux/amd64`, `linux/arm64`)
- SBOM generation during build/push
- Build provenance attestation attached and pushed to the registry

Workflows:

- `.github/workflows/ghcr-all-dev-branches.yml`: publishes branch and sha tags for dev usage
- `.github/workflows/ghcr-latest.yml`: publishes `latest` on release `released`
- `.github/workflows/ghcr-release.yml`: publishes immutable release tag on release `published`

Local `local-build` mode remains optimized for developer trust in a local environment and does not depend on remote artifact attestations.

## Target contract

Primary command surface:

- `ci-box check`
- `ci-box build-lint`
- `ci-box unit`
- `ci-box integration`
- `ci-box appservice-integration`
- `ci-box all`

Exit codes:

- `0` success
- `1` target failed
- `2` invalid usage
- `3` runtime bootstrap failure

## Running before Docker is installed

Use preflight mode to verify workspace and see dependency readiness:

```powershell
./ci-box.ps1 check -Workspace C:\path\to\Draupnir
```

After Docker is installed and running, execute targets directly:

```powershell
./ci-box.ps1 build-lint -Workspace C:\path\to\Draupnir -SourceMode local-build
```

## Dependency isolation design

- Source is mounted read-only at `/workspace-src`.
- Source is copied into `/workspace` via `rsync`.
- `node_modules` is excluded from sync.
- install runs via `corepack npm ci` (or `corepack npm install` if `CI_BOX_INSTALL_MODE=install`).
- native module check fails if Windows binaries are detected in active dependency tree.

## Cache strategy

- Workspace cache volume: `ci-box-workspace-cache`
- NPM cache volume: `ci-box-npm-cache`
- Cargo cache volume: `ci-box-cargo-cache`
- Docker data volume: `ci-box-docker-data`

This keeps repeated local and GitHub-style runs warm. This becomes especially important in local dev because running 20 runs in a row makes it VERY annoying to have delays of any kind.

On unchanged reruns, CI in a Box skips dependency install and `build:all` by using lockfile/source signatures against the cached workspace.
If you need a clean run, use `-NoCache`.

Being able to skip build:all becomes very nice when you have already done a build for some reason. For example you did a build:all to run unit tests then proceed to run integration tests or any other combination of running tests without code changes.

## Timing metrics output

Each non-`check` target run prints one compact timing total line by default.

Default line format:

- `timing total_ms=<milliseconds> targets=<count> cold_targets=<count> warm_targets=<count>`

Enable verbose timing output when you want per-target details:

- Windows PowerShell: pass `-VerboseTiming`
- Linux/macOS bash: pass `--verbose-timing` as the optional fourth argument, or set `CI_BOX_TIMING_VERBOSE=1`

Verbose per-target line format:

- `target=<name> duration_ms=<milliseconds> cache_profile=<cold|warm> deps=<state> build=<state>`

State meanings:

- `cache_profile=cold`: the target had to perform dependency install and/or `build:all`
- `cache_profile=warm`: the target reused prior work for dependency/build phases
- `deps`: `hit`, `miss`, `forced-miss`, or `not-evaluated`
- `build`: `hit`, `miss`, `forced-miss`, `already-built`, or `not-evaluated`

This is intended to make cold-vs-warm behavior visible for local runs and GitHub-style runs.

## To be worked on

- Add GitHub workflow wrapper that calls one CI box target per `mjolnir.yml` job.
- Keep a shared remote cache scope for now; branch-aware remote cache keys are not currently considered necessary for this repository's expected activity level, but this assumption may be wrong and should be revisited if concurrency or cache churn increases.
- Implement proper changelogs like keep a log or whatever system we determine should be used.

## Status of the repository

This repository is currently just a experimental project that if it succeeds will be accended to a full production version. But until that happens this note will remain.

After the experimental phase documentation will be moved out of this repo and into the draupnir docs repository and proper docs will be written. This file and the limited docs in it are not intended to be the final docs.
