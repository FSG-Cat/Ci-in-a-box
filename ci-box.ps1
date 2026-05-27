# SPDX-FileCopyrightText: 2026 Catalan Lover <catalanlover@protonmail.com>
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Runs Draupnir CI targets in the CI in a Box container runtime.

.DESCRIPTION
ci-box.ps1 provides a PowerShell entrypoint for running Draupnir CI targets
inside a Linux container environment. It supports local image builds,
published image tags resolved to immutable digests, cache controls, preflight
checks, and version reporting for release automation.

.PARAMETER Target
CI target to run: check, build-lint, unit, integration,
appservice-integration, all, or version.

.PARAMETER Workspace
Path to a Draupnir checkout. Required for all non-version targets.

.PARAMETER SynapseHttpAntispamWorkspace
Path to an externally checked out synapse-http-antispam repository.
Required for integration, appservice-integration, and all.

.PARAMETER Version
Prints the launcher version and exits.

.PARAMETER Image
Container image reference used in local-build mode.

.PARAMETER SynapseImage
Optional Synapse image reference forwarded to the runtime container.

.PARAMETER PostgresImage
Optional Postgres image reference forwarded to the runtime container.

.PARAMETER ReverseProxyImage
Optional reverse proxy image reference forwarded to the runtime container.

.PARAMETER SourceMode
Image source mode for non-check targets: local-build or published-tag.

.PARAMETER Rebuild
For local-build mode, force rebuilding the local image.

.PARAMETER PublishedRepository
Registry repository to use in published-tag mode.

.PARAMETER PublishedTag
Tag to resolve and run in published-tag mode.

.PARAMETER NoCache
Runs container target with CI_BOX_NO_CACHE=1.

.PARAMETER DebugLogs
Enables verbose runtime/bootstrap logs in the container.

.PARAMETER VerboseTiming
Enables detailed per-target timing output in the container.

.PARAMETER IntegrationCommand
Overrides the integration test command inside the runtime container.

.PARAMETER AppserviceIntegrationCommand
Overrides the appservice-integration test command inside the runtime container.

.EXAMPLE
./ci-box.ps1 check -Workspace C:\path\to\Draupnir

.EXAMPLE
./ci-box.ps1 build-lint -Workspace C:\path\to\Draupnir -SourceMode local-build

.EXAMPLE
./ci-box.ps1 build-lint -Workspace C:\path\to\Draupnir -SourceMode published-tag -PublishedTag v0.1.0

.EXAMPLE
./ci-box.ps1 all -Workspace C:\path\to\Draupnir -SourceMode local-build -VerboseTiming

.EXAMPLE
./ci-box.ps1 -Version
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "build-lint", "unit", "integration", "appservice-integration", "all", "version")]
    [string]$Target = "check",

    [Parameter()]
    [string]$Workspace,

    [Parameter()]
    [string]$LogDir,

    [Parameter()]
    [string]$SynapseHttpAntispamWorkspace,

    [Parameter()]
    [switch]$Version,

    [Parameter()]
    [string]$Image = "draupnir/ci-in-a-box:dev",

    [Parameter()]
    [string]$Role = "orchestrator",

    [Parameter()]
    [string]$SynapseImage,

    [Parameter()]
    [string]$PostgresImage,

    [Parameter()]
    [string]$ReverseProxyImage,

    [Parameter()]
    [ValidateSet("local-build", "published-tag")]
    [string]$SourceMode,

    [Parameter()]
    [switch]$Rebuild,

    [Parameter()]
    [string]$PublishedRepository = "ghcr.io/fsg-cat/ci-in-a-box",

    [Parameter()]
    [string]$PublishedTag,

    [Parameter()]
    [switch]$NoCache,

    [Parameter()]
    [switch]$DebugLogs,

    [Parameter()]
    [switch]$VerboseTiming,

    [Parameter()]
    [string]$IntegrationCommand,

    [Parameter()]
    [string]$AppserviceIntegrationCommand,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionFile = Join-Path $scriptRoot "VERSION"
$ciBoxVersion = ""

if ([string]::IsNullOrWhiteSpace($ciBoxVersion) -and (Test-Path $versionFile)) {
    $ciBoxVersion = (Get-Content -Path $versionFile -TotalCount 1).Trim()
}

if ([string]::IsNullOrWhiteSpace($ciBoxVersion)) {
    $ciBoxVersion = "0.0.0-dev"
}

if ($Version.IsPresent -or $Target -eq "version") {
    Write-Host "ci-box $ciBoxVersion"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    throw "Workspace path is required"
}

if (-not (Test-Path $Workspace)) {
    throw "Workspace path not found: $Workspace"
}

if (-not (Test-Path (Join-Path $Workspace "package.json"))) {
    throw "Workspace does not look like a Draupnir checkout (missing package.json): $Workspace"
}

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $scriptRoot ".ci-box-logs"
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runLogDir = Join-Path $LogDir $runId
if (-not (Test-Path $runLogDir)) {
    New-Item -ItemType Directory -Path $runLogDir | Out-Null
}

$requiresSupportStack = @("integration", "appservice-integration", "all") -contains $Target
if ($requiresSupportStack -and [string]::IsNullOrWhiteSpace($SynapseHttpAntispamWorkspace)) {
    throw "-SynapseHttpAntispamWorkspace is required for target '$Target'"
}

if (-not [string]::IsNullOrWhiteSpace($SynapseHttpAntispamWorkspace)) {
    if (-not (Test-Path $SynapseHttpAntispamWorkspace)) {
        throw "Synapse antispam workspace path not found: $SynapseHttpAntispamWorkspace"
    }

    if (-not (Test-Path (Join-Path $SynapseHttpAntispamWorkspace "synapse_http_antispam.py"))) {
        throw "Synapse antispam workspace must contain synapse_http_antispam.py: $SynapseHttpAntispamWorkspace"
    }
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-DockerOrFail {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args,
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & docker @Args | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Get-RepoDigestForTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $tagRef = "${Repository}:${Tag}"
    $inspect = & docker image inspect --format "{{json .RepoDigests}}" $tagRef 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($inspect)) {
        return $null
    }

    $repoDigests = $inspect | ConvertFrom-Json
    foreach ($digestRef in $repoDigests) {
        if ($digestRef -like "${Repository}@sha256:*") {
            return $digestRef
        }
    }

    return $null
}

function Assert-ValidRepoDigestRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DigestRef,
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $pattern = "^" + [regex]::Escape($Repository) + "@sha256:[0-9a-f]{64}$"
    if ($DigestRef -notmatch $pattern) {
        throw "Integrity gate failed: digest ref '$DigestRef' is not a valid ${Repository}@sha256:<64-hex> reference"
    }
}

function Test-SemVerLikeTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    return $Tag -match '^(v)?\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$'
}

function Resolve-PublishedTagImageRef {
    if ([string]::IsNullOrWhiteSpace($PublishedTag)) {
        throw "-SourceMode published-tag requires -PublishedTag"
    }

    if (-not $PublishedRepository.StartsWith("ghcr.io/")) {
        Write-Host "[ci-box] warning: non-ghcr registry '${PublishedRepository}' is outside the supported policy boundary"
        Write-Host "[ci-box] warning: behavior may differ and related issues are considered out-of-scope"
    }

    $tagRef = "${PublishedRepository}:${PublishedTag}"
    $checkFreshness = -not (Test-SemVerLikeTag -Tag $PublishedTag)
    $beforeDigest = $null

    if ($checkFreshness) {
        $beforeDigest = Get-RepoDigestForTag -Repository $PublishedRepository -Tag $PublishedTag
    }

    Write-Host "[ci-box] pulling published tag $tagRef"
    Invoke-DockerOrFail -Args @("pull", $tagRef) -FailureMessage "Failed to pull published image tag: $tagRef"

    $afterDigest = Get-RepoDigestForTag -Repository $PublishedRepository -Tag $PublishedTag
    if ([string]::IsNullOrWhiteSpace($afterDigest)) {
        throw "Unable to resolve pulled tag to digest: $tagRef"
    }

    Assert-ValidRepoDigestRef -DigestRef $afterDigest -Repository $PublishedRepository

    if ($checkFreshness) {
        if ($beforeDigest -eq $afterDigest) {
            Write-Host "[ci-box] non-semver tag digest unchanged (${PublishedTag}): $afterDigest"
        } elseif ([string]::IsNullOrWhiteSpace($beforeDigest)) {
            Write-Host "[ci-box] non-semver tag digest resolved (${PublishedTag}): $afterDigest"
        } else {
            Write-Host "[ci-box] non-semver tag digest updated (${PublishedTag}): $beforeDigest -> $afterDigest"
        }
    } else {
        Write-Host "[ci-box] semver-like tag resolved to digest (${PublishedTag}): $afterDigest"
    }

    return $afterDigest
}

function Invoke-Preflight {
    param([bool]$RequireDocker)

    $ok = $true
    Write-Host "[ci-box] workspace: $Workspace"
    Write-Host "[ci-box] target: $Target"

    if (-not (Test-CommandExists "docker")) {
        Write-Host "[ci-box] docker: MISSING"
        Write-Host "[ci-box] install Docker Desktop and enable Linux containers before running CI targets"
        if ($RequireDocker) {
            return $false
        }
        return $false
    }

    Write-Host "[ci-box] docker: found"

    docker version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ci-box] docker daemon: not reachable"
        Write-Host "[ci-box] start Docker Desktop and wait for engine ready"
        $ok = $false
    } else {
        Write-Host "[ci-box] docker daemon: reachable"
    }

    return $ok
}

if ($Target -eq "check") {
    if (Invoke-Preflight -RequireDocker:$false) {
        Write-Host "[ci-box] preflight: ready"
        exit 0
    }
    Write-Host "[ci-box] preflight: not ready"
    exit 2
}

if (-not (Invoke-Preflight -RequireDocker:$true)) {
    Write-Host "[ci-box] cannot run target until prerequisites are ready"
    exit 2
}

if ([string]::IsNullOrWhiteSpace($SourceMode)) {
    throw "Select an explicit -SourceMode: local-build or published-tag"
}

if ($SourceMode -eq "published-tag") {
    if ($Rebuild.IsPresent) {
        throw "-Rebuild cannot be used with -SourceMode published-tag"
    }

    $Image = Resolve-PublishedTagImageRef
} else {
    if ([string]::IsNullOrWhiteSpace($Image)) {
        throw "-SourceMode local-build requires a valid -Image"
    }

    if ($Rebuild.IsPresent) {
        Write-Host "[ci-box] rebuilding image $Image"
        Invoke-DockerOrFail -Args @("build", "-t", $Image, $scriptRoot) -FailureMessage "Failed to build image: $Image"
    } else {
        docker image inspect $Image *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ci-box] image not found locally, building $Image"
            Invoke-DockerOrFail -Args @("build", "-t", $Image, $scriptRoot) -FailureMessage "Failed to build image: $Image"
        } else {
            Write-Host "[ci-box] reusing existing image $Image (pass -Rebuild to rebuild)"
        }
    }
}

$orchestratorContainerName = "ci-box-orchestrator"
docker rm -f $orchestratorContainerName *> $null

$dockerArgs = @(
    "run", "--rm", "--name", $orchestratorContainerName, "--privileged", "--cgroupns=host",
    "-e", "CI=1",
    "-e", "CI_BOX_MODE=local",
    "-e", "CI_BOX_NO_CACHE=$(if ($NoCache.IsPresent) { '1' } else { '0' })",
    "-e", "CI_BOX_TIMING_VERBOSE=$(if ($VerboseTiming.IsPresent) { '1' } else { '0' })",
    "-e", "CI_BOX_LOG_DIR=/ci-box-logs/$runId",
    "-e", "WORKSPACE_SRC=/workspace-src",
    "-e", "WORKSPACE_DST=/workspace-cache/workspace",
    "-v", "${Workspace}:/workspace-src:ro",
    "-v", "${LogDir}:/ci-box-logs",
    "-v", "ci-box-workspace-cache:/workspace-cache",
    "-v", "ci-box-npm-cache:/cache/npm",
    "-v", "ci-box-cargo-cache:/cache/cargo",
    "-v", "ci-box-docker-data:/var/lib/docker"
)

if (-not [string]::IsNullOrWhiteSpace($IntegrationCommand)) {
    $dockerArgs += @("-e", "CI_BOX_INTEGRATION_COMMAND=$IntegrationCommand")
}

if (-not [string]::IsNullOrWhiteSpace($AppserviceIntegrationCommand)) {
    $dockerArgs += @("-e", "CI_BOX_APPSERVICE_INTEGRATION_COMMAND=$AppserviceIntegrationCommand")
}

if (-not [string]::IsNullOrWhiteSpace($SynapseHttpAntispamWorkspace)) {
    $dockerArgs += @("-v", "${SynapseHttpAntispamWorkspace}:/workspace-antispam-src:ro")
    $dockerArgs += @("-e", "CI_BOX_SYNAPSE_HTTP_ANTISPAM_SOURCE=/workspace-antispam-src")
}

if (-not [string]::IsNullOrWhiteSpace($SynapseImage)) {
    $dockerArgs += @("-e", "CI_BOX_SYNAPSE_IMAGE=$SynapseImage")
}

if (-not [string]::IsNullOrWhiteSpace($PostgresImage)) {
    $dockerArgs += @("-e", "CI_BOX_POSTGRES_IMAGE=$PostgresImage")
}

if (-not [string]::IsNullOrWhiteSpace($ReverseProxyImage)) {
    $dockerArgs += @("-e", "CI_BOX_REVERSE_PROXY_IMAGE=$ReverseProxyImage")
}

if (-not [string]::IsNullOrWhiteSpace($Role)) {
    $dockerArgs += @("-e", "CI_BOX_ROLE=$Role")
}

$dockerArgs += @($Image, $Target)

if ($ExtraArgs) {
    $dockerArgs += $ExtraArgs
}

Write-Host "[ci-box] running target $Target against workspace $Workspace"
Write-Host "[ci-box] container image ref: $Image"
$orchestratorLog = Join-Path $runLogDir "orchestrator.log"
Write-Host "[ci-box] logs: $runLogDir"
& docker @dockerArgs 2>&1 | Tee-Object -FilePath $orchestratorLog
$exitCode = $LASTEXITCODE
exit $exitCode
