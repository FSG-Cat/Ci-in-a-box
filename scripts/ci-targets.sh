#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Catalan Lover <catalanlover@protonmail.com>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Usage: ci-targets.sh <build-lint|unit|integration|appservice-integration|all>" >&2
    exit 2
fi
shift || true

WORKSPACE_SRC="${WORKSPACE_SRC:-/workspace-src}"
WORKSPACE_DST="${WORKSPACE_DST:-/workspace}"
CACHE_ROOT="${CACHE_ROOT:-/cache}"
NPM_CACHE_DIR="${NPM_CACHE_DIR:-${CACHE_ROOT}/npm}"
CARGO_HOME="${CARGO_HOME:-${CACHE_ROOT}/cargo}"
STATE_DIR="${STATE_DIR:-${WORKSPACE_DST}/.ci-box-state}"
MX_TESTER_VERSION="${MX_TESTER_VERSION:-0.3.3}"

WORKSPACE_PREPARED=0
BUILD_DONE_THIS_RUN=0
TARGET_DEP_OUTCOME="not-evaluated"
TARGET_BUILD_OUTCOME="not-evaluated"
DEPENDENCY_INSTALL_COUNT=0
BUILD_RUN_COUNT=0
TIMING_LINES=()
TIMING_VERBOSE="${CI_BOX_TIMING_VERBOSE:-0}"
TARGET_COUNT=0
TARGET_COLD_COUNT=0
TARGET_WARM_COUNT=0

timing_verbose_enabled() {
    case "${TIMING_VERBOSE}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

now_ms() {
    date +%s%3N
}

RUN_START_MS="$(now_ms)"

export PATH="${CARGO_HOME}/bin:${PATH}"
export CARGO_HOME

log() {
    echo "[ci-box] $*"
}

configure_git_context() {
    if git -C "${WORKSPACE_SRC}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        export GIT_DIR="${WORKSPACE_SRC}/.git"
        export GIT_WORK_TREE="${WORKSPACE_SRC}"
        return
    fi

    unset GIT_DIR || true
    unset GIT_WORK_TREE || true
}

fail_usage() {
    log "$1"
    exit 2
}

sync_workspace() {
    if [[ ! -d "${WORKSPACE_SRC}" ]]; then
        log "workspace source path does not exist: ${WORKSPACE_SRC}"
        exit 2
    fi

    mkdir -p "${WORKSPACE_DST}" "${NPM_CACHE_DIR}" "${CARGO_HOME}" "${STATE_DIR}"

    # Ignore host and generated artifacts so Linux-native dependencies can be reused safely.
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='.ci-box-state/' \
        --exclude='node_modules/' \
        --exclude='**/node_modules/' \
        --exclude='dist/' \
        --exclude='**/dist/' \
        --exclude='*.tsbuildinfo' \
        --exclude='**/*.tsbuildinfo' \
        "${WORKSPACE_SRC}/" "${WORKSPACE_DST}/"
}

preflight_dependency_isolation() {
    if [[ -L "${WORKSPACE_DST}/node_modules" ]]; then
        log "node_modules is a symlink; refusing to use non-container dependency path"
        exit 1
    fi
}

configure_npm_cache() {
    npm config set cache "${NPM_CACHE_DIR}" --global >/dev/null
}

install_dependencies() {
    local lock_hash lock_hash_file install_start install_end install_ms

    cd "${WORKSPACE_DST}"
    corepack enable >/dev/null
    configure_npm_cache

    lock_hash="$(sha256sum "${WORKSPACE_DST}/package-lock.json" | awk '{print $1}')"
    lock_hash_file="${STATE_DIR}/lock.hash"

    if [[ "${CI_BOX_NO_CACHE:-0}" == "1" ]]; then
        log "CI_BOX_NO_CACHE=1; running clean dependency install"
        install_start="$(now_ms)"
        corepack npm ci
        install_end="$(now_ms)"
        install_ms=$((install_end - install_start))
        if timing_verbose_enabled; then
            log "timing phase=npm-ci duration_ms=${install_ms}"
        fi
        printf "%s\n" "${lock_hash}" >"${lock_hash_file}"
        TARGET_DEP_OUTCOME="forced-miss"
        DEPENDENCY_INSTALL_COUNT=$((DEPENDENCY_INSTALL_COUNT + 1))
        return
    fi

    if [[ ! -d "${WORKSPACE_DST}/node_modules" ]]; then
        log "node_modules cache missing; running dependency install"
        install_start="$(now_ms)"
        corepack npm ci
        install_end="$(now_ms)"
        install_ms=$((install_end - install_start))
        if timing_verbose_enabled; then
            log "timing phase=npm-ci duration_ms=${install_ms}"
        fi
        printf "%s\n" "${lock_hash}" >"${lock_hash_file}"
        TARGET_DEP_OUTCOME="miss"
        DEPENDENCY_INSTALL_COUNT=$((DEPENDENCY_INSTALL_COUNT + 1))
        return
    fi

    if [[ ! -f "${lock_hash_file}" ]] || [[ "$(cat "${lock_hash_file}")" != "${lock_hash}" ]]; then
        log "lockfile changed; running dependency install"
        install_start="$(now_ms)"
        corepack npm ci
        install_end="$(now_ms)"
        install_ms=$((install_end - install_start))
        if timing_verbose_enabled; then
            log "timing phase=npm-ci duration_ms=${install_ms}"
        fi
        printf "%s\n" "${lock_hash}" >"${lock_hash_file}"
        TARGET_DEP_OUTCOME="miss"
        DEPENDENCY_INSTALL_COUNT=$((DEPENDENCY_INSTALL_COUNT + 1))
        return
    fi

    log "dependency cache hit; skipping npm install"
    TARGET_DEP_OUTCOME="hit"
}

verify_native_modules_linux() {
    local native_nodes
    native_nodes=$(find "${WORKSPACE_DST}/node_modules" -type f -name '*.node' 2>/dev/null || true)
    if [[ -z "${native_nodes}" ]]; then
        return 0
    fi

    if echo "${native_nodes}" | xargs -r file | grep -Eqi 'PE32|MS Windows'; then
        log "detected non-linux native modules in active dependency tree"
        exit 1
    fi
}

ensure_mx_tester() {
    if command -v mx-tester >/dev/null 2>&1; then
        return 0
    fi

    log "installing mx-tester ${MX_TESTER_VERSION}"
    cargo install --locked --version "${MX_TESTER_VERSION}" mx-tester
}

preclean_mx_tester_state() {
    # Ensure we always start integration targets from a clean slate, even after interrupted runs.
    docker rm -f \
        mjolnir-test-postgres \
        mjolnir-test-reverse-proxy \
        mx-tester-synapse-setup-mjolnir \
        mx-tester-synapse-run-mjolnir >/dev/null 2>&1 || true

    docker network rm net-mx-tester-synapse-matrixdotorg/synapse:latest-mjolnir >/dev/null 2>&1 || true
}

prepare_workspace() {
    if [[ "${WORKSPACE_PREPARED}" == "1" ]]; then
        return
    fi

    sync_workspace
    configure_git_context
    preflight_dependency_isolation
    install_dependencies
    verify_native_modules_linux

    WORKSPACE_PREPARED=1
}

current_source_signature() {
    local head_ref status_hash

    if git -C "${WORKSPACE_SRC}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        head_ref="$(git -C "${WORKSPACE_SRC}" rev-parse HEAD 2>/dev/null || echo no-head)"
        status_hash="$(git -C "${WORKSPACE_SRC}" status --porcelain --untracked-files=normal 2>/dev/null | sha256sum | awk '{print $1}')"
        printf "%s-%s\n" "${head_ref}" "${status_hash}"
        return
    fi

    find "${WORKSPACE_DST}" -type f \
        ! -path '*/node_modules/*' \
        ! -path '*/dist/*' \
        ! -name '*.tsbuildinfo' \
        -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sha256sum \
        | awk '{print $1}'
}

ensure_version_branch_files() {
    local app_dir version_file branch_file version_value branch_value
    app_dir="${WORKSPACE_DST}/apps/draupnir"
    version_file="${app_dir}/version.txt"
    branch_file="${app_dir}/branch.txt"

    mkdir -p "${app_dir}"

    if git -C "${WORKSPACE_SRC}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        version_value="$(git -C "${WORKSPACE_SRC}" describe 2>/dev/null || echo ci-box-local)"
        branch_value="$(git -C "${WORKSPACE_SRC}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)"
    else
        version_value="ci-box-local"
        branch_value="local"
    fi

    printf "%s\n" "${version_value}" >"${version_file}"
    printf "%s\n" "${branch_value}" >"${branch_file}"
}

ensure_build_all() {
    local build_sig build_sig_file build_start build_end build_ms

    if [[ "${BUILD_DONE_THIS_RUN}" == "1" ]]; then
        TARGET_BUILD_OUTCOME="already-built"
        return
    fi

    build_sig="$(current_source_signature)"
    build_sig_file="${STATE_DIR}/build.signature"

    if [[ "${CI_BOX_NO_CACHE:-0}" == "1" ]]; then
        log "CI_BOX_NO_CACHE=1; forcing build"
        cd "${WORKSPACE_DST}"
        build_start="$(now_ms)"
        corepack npm run build:all
        build_end="$(now_ms)"
        build_ms=$((build_end - build_start))
        if timing_verbose_enabled; then
            log "timing phase=build-all duration_ms=${build_ms}"
        fi
        printf "%s\n" "${build_sig}" >"${build_sig_file}"
        BUILD_DONE_THIS_RUN=1
        TARGET_BUILD_OUTCOME="forced-miss"
        BUILD_RUN_COUNT=$((BUILD_RUN_COUNT + 1))
        return
    fi

    if [[ -f "${build_sig_file}" ]] \
        && [[ "$(cat "${build_sig_file}")" == "${build_sig}" ]] \
        && [[ -f "${WORKSPACE_DST}/apps/draupnir/dist/index.js" ]]; then
        log "build cache hit; skipping build:all"
        BUILD_DONE_THIS_RUN=1
        TARGET_BUILD_OUTCOME="hit"
        return
    fi

    log "build cache miss; running build:all"
    cd "${WORKSPACE_DST}"
    build_start="$(now_ms)"
    corepack npm run build:all
    build_end="$(now_ms)"
    build_ms=$((build_end - build_start))
    if timing_verbose_enabled; then
        log "timing phase=build-all duration_ms=${build_ms}"
    fi
    printf "%s\n" "${build_sig}" >"${build_sig_file}"
    BUILD_DONE_THIS_RUN=1
    TARGET_BUILD_OUTCOME="miss"
    BUILD_RUN_COUNT=$((BUILD_RUN_COUNT + 1))
}

run_target_with_timing() {
    local name fn start end duration
    local dep_installs_before dep_installs_after build_runs_before build_runs_after cache_profile

    name="$1"
    fn="$2"

    TARGET_DEP_OUTCOME="not-evaluated"
    TARGET_BUILD_OUTCOME="not-evaluated"
    dep_installs_before="${DEPENDENCY_INSTALL_COUNT}"
    build_runs_before="${BUILD_RUN_COUNT}"

    start="$(now_ms)"
    "${fn}"
    end="$(now_ms)"

    dep_installs_after="${DEPENDENCY_INSTALL_COUNT}"
    build_runs_after="${BUILD_RUN_COUNT}"
    duration=$((end - start))

    if [[ "${dep_installs_after}" -gt "${dep_installs_before}" ]] || [[ "${build_runs_after}" -gt "${build_runs_before}" ]]; then
        cache_profile="cold"
        TARGET_COLD_COUNT=$((TARGET_COLD_COUNT + 1))
    else
        cache_profile="warm"
        TARGET_WARM_COUNT=$((TARGET_WARM_COUNT + 1))
    fi

    TARGET_COUNT=$((TARGET_COUNT + 1))
    TIMING_LINES+=("target=${name} duration_ms=${duration} cache_profile=${cache_profile} deps=${TARGET_DEP_OUTCOME} build=${TARGET_BUILD_OUTCOME}")
}

print_timing_summary() {
    local run_end_ms run_total_ms line

    run_end_ms="$(now_ms)"
    run_total_ms=$((run_end_ms - RUN_START_MS))
    log "timing total_ms=${run_total_ms} targets=${TARGET_COUNT} cold_targets=${TARGET_COLD_COUNT} warm_targets=${TARGET_WARM_COUNT}"

    if timing_verbose_enabled; then
        for line in "${TIMING_LINES[@]}"; do
            log "timing ${line}"
        done
    fi
}

run_build_lint() {
    prepare_workspace
    ensure_version_branch_files
    ensure_build_all
    cd "${WORKSPACE_DST}"
    corepack npm run lint
}

run_unit() {
    prepare_workspace
    ensure_version_branch_files
    ensure_build_all
    cd "${WORKSPACE_DST}"
    corepack npm run test
}

run_integration_common() {
    prepare_workspace
    ensure_version_branch_files
    ensure_mx_tester
    preclean_mx_tester_state
    ensure_build_all
}

run_integration() {
    run_integration_common

    teardown() {
        mx-tester down || true
    }

    trap teardown EXIT INT TERM
    env -u GIT_DIR -u GIT_WORK_TREE RUST_LOG="${RUST_LOG:-debug,hyper=info,rusttls=info}" mx-tester build up
    env -u GIT_DIR -u GIT_WORK_TREE RUST_LOG="${RUST_LOG:-debug,hyper=info,rusttls=info}" mx-tester run
    teardown
    trap - EXIT INT TERM
}

run_appservice_integration() {
    run_integration_common

    teardown() {
        mx-tester down || true
    }

    trap teardown EXIT INT TERM
    env -u GIT_DIR -u GIT_WORK_TREE RUST_LOG="${RUST_LOG:-debug,hyper=info,rusttls=info}" mx-tester build up
    corepack npm run -w apps/draupnir test:appservice:integration
    teardown
    trap - EXIT INT TERM
}

case "${TARGET}" in
    build-lint)
        run_target_with_timing "build-lint" run_build_lint
        ;;
    unit)
        run_target_with_timing "unit" run_unit
        ;;
    integration)
        run_target_with_timing "integration" run_integration
        ;;
    appservice-integration)
        run_target_with_timing "appservice-integration" run_appservice_integration
        ;;
    all)
        run_target_with_timing "build-lint" run_build_lint
        run_target_with_timing "unit" run_unit
        run_target_with_timing "integration" run_integration
        run_target_with_timing "appservice-integration" run_appservice_integration
        ;;
    *)
        fail_usage "unknown target '${TARGET}'"
        ;;
esac

print_timing_summary
