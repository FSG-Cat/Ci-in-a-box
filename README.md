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

## Prerequisites

- Docker Desktop (Linux containers enabled)
- A local checkout of `Draupnir`
- A local checkout of `synapse-http-antispam` for integration targets

You must explicitly provide the Draupnir checkout path to the launcher.
For integration targets, also provide the `synapse-http-antispam` checkout path.

## Local usage (Windows)

Run from this repository root:

```powershell
./ci-box.ps1 check -Workspace C:\path\to\Draupnir
./ci-box.ps1 build-lint -Workspace C:\path\to\Draupnir
./ci-box.ps1 unit -Workspace C:\path\to\Draupnir
./ci-box.ps1 integration -Workspace C:\path\to\Draupnir -SynapseHttpAntispamWorkspace C:\path\to\synapse-http-antispam
./ci-box.ps1 appservice-integration -Workspace C:\path\to\Draupnir -SynapseHttpAntispamWorkspace C:\path\to\synapse-http-antispam
./ci-box.ps1 all -Workspace C:\path\to\Draupnir -SynapseHttpAntispamWorkspace C:\path\to\synapse-http-antispam
```

Useful flags:

- `-Image ghcr.io/FSG-Cat/ci-in-a-box:dev`
If you want to run orchestration only (bring up Postgres/Synapse/nginx), run the orchestrator image (built from `Dockerfile`).

If you want to run Draupnir/Draupnir tests (Node toolchain), use the runner image (built from `Dockerfile.runner`) and pass `-Role runner` to the launcher so the runtime executes Node targets.

Example runner image usage (local-build):

```bash
./ci-box build-lint /path/to/Draupnir local-build --verbose-timing
# or
./ci-box build-lint /path/to/Draupnir local-build --verbose-timing
CI_BOX_ROLE=runner ./ci-box build-lint /path/to/Draupnir local-build
```

Examples — orchestrator vs runner


2. Start the orchestrator to bring up the support stack (keeps running until Ctrl+C):

```bash
CI_BOX_ROLE=orchestrator ./ci-box integration /path/to/Draupnir local-build
```

3a. Run the runner image (CI) to execute tests against the orchestrator’s stack. Per the Gen2 rules we do not use a custom baked runner image; the orchestrator will use an upstream Node image by default. You can override which upstream image to use with `CI_BOX_RUNNER_IMAGE`.

```bash
CI_BOX_RUNNER_IMAGE=node:24-slim CI_BOX_ROLE=runner ./ci-box integration /path/to/Draupnir local-build
```

3b. Or, for local development, run your local Draupnir checkout (outside the container) and point it at the exposed ports documented by the orchestrator logs.

Configuration knobs for orchestrator/runner behavior

- `CI_BOX_RUNNER_IMAGE`: image to use when the orchestrator auto-spawns the runner (default: `node:24-slim`).
- `CI_BOX_AUTO_RUNNER`: when `1` (default), the orchestrator automatically launches the runner after the support stack becomes available. Set to `0` to disable automatic runner spawning.
- `CI_BOX_ORCHESTRATOR_PERSIST_AFTER_RUN`: when `1`, the orchestrator will keep the support stack running after the runner exits (useful for iterative local development). Default is `0` (orchestrator tears down the stack after the runner completes).
- `CI_BOX_SYNAPSE_SERVER_NAME`: Synapse `server_name` rendered into the generated config (default: `localhost:9999`).
- `CI_BOX_SYNAPSE_PUBLIC_BASEURL`: Synapse `public_baseurl` rendered into the generated config (default: `http://localhost:9999`).
- `CI_BOX_SYNAPSE_ANTISPAM_BASE_URL`: antispam callback URL rendered into Synapse config (default: `http://host.docker.internal:8082/api/1/spam_check`).
- `CI_BOX_DRAUPNIR_APPSERVICE_URL`: appservice URL rendered into the generated registration file (default: `http://host.docker.internal:9000`).
- `CI_BOX_POSTGRES_*`: Postgres connection and host-port settings for the support stack.

Runtime notes:

- The orchestrator will ensure minimal runtime tools are available inside the upstream runner image: if `git` or `bash` are missing the orchestrator will install them at container start using the image's package manager (Debian `apt`). This keeps images upstream-first while ensuring the workspace-mounted scripts can run.

- `-SourceMode local-build|published-tag`
- `-Rebuild`
- `-PublishedRepository ghcr.io/FSG-Cat/ci-in-a-box`
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

### Workflows used for artifacts

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

## Timing metrics output

Each non-`check` target run prints one compact timing total line by default.

Default line format:

- `timing total_ms=<milliseconds> targets=<count> cold_targets=<count> warm_targets=<count>`

Enable verbose timing output when you want per-target details:

- Windows PowerShell: pass `-VerboseTiming`
- Linux/macOS bash: pass `--verbose-timing` as the optional fourth argument, or set `CI_BOX_TIMING_VERBOSE=1`

## To be worked on

- Add GitHub workflow wrapper that calls one CI box target per `mjolnir.yml` job.
- Keep a shared remote cache scope for now; branch-aware remote cache keys are not currently considered necessary for this repository's expected activity level, but this assumption may be wrong and should be revisited if concurrency or cache churn increases.
- Implement proper changelogs like keep a log or whatever system we determine should be used.

## Status of the repository

This repository is currently just a experimental project that if it succeeds will be ascended to a full production version. But until that happens this note will remain.

After the experimental phase documentation will be moved out of this repo and into the draupnir docs repository and proper docs will be written. This file and the limited docs in it are not intended to be the final docs.
