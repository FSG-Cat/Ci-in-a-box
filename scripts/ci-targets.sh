#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Catalan Lover <catalanlover@protonmail.com>
#
# SPDX-License-Identifier: Apache-2.0

# Defaults (overridable via CI_BOX_* envs or direct env vars)
WORKSPACE_SRC="${WORKSPACE_SRC:-/workspace-src}"
# Default workspace destination inside the container (matches launcher mounts)
WORKSPACE_DST="${WORKSPACE_DST:-/workspace-cache/workspace}"
# STATE_DIR removed: script is stateless by default
SYNAPSE_IMAGE="${CI_BOX_SYNAPSE_IMAGE:-ghcr.io/element-hq/synapse:latest}"
POSTGRES_IMAGE="${CI_BOX_POSTGRES_IMAGE:-postgres:18-alpine}"
REVERSE_PROXY_IMAGE="${CI_BOX_REVERSE_PROXY_IMAGE:-nginx:stable-alpine}"
SUPPORT_NETWORK="${CI_BOX_SUPPORT_NETWORK:-ci-box-support}"
POSTGRES_CONTAINER="${CI_BOX_POSTGRES_CONTAINER:-ci-box-postgres}"
SYNAPSE_CONTAINER="${CI_BOX_SYNAPSE_CONTAINER:-ci-box-synapse}"
REVERSE_PROXY_CONTAINER="${CI_BOX_REVERSE_PROXY_CONTAINER:-ci-box-reverse-proxy}"
POSTGRES_USER="${CI_BOX_POSTGRES_USER:-mjolnir-tester}"
POSTGRES_PASSWORD="${CI_BOX_POSTGRES_PASSWORD:-mjolnir-test}"
POSTGRES_DB="${CI_BOX_POSTGRES_DB:-mjolnir-test-db}"
SYNAPSE_POSTGRES_DB="${CI_BOX_SYNAPSE_POSTGRES_DB:-synapse-test-db}"
POSTGRES_HOST_PORT="${CI_BOX_POSTGRES_HOST_PORT:-8083}"
POSTGRES_BIND_ADDRESS="${CI_BOX_POSTGRES_BIND_ADDRESS:-127.0.0.1}"
SYNAPSE_CONFIG_PATH="${CI_BOX_SYNAPSE_CONFIG_PATH:-}"
SYNAPSE_DATA_DIR="${CI_BOX_SYNAPSE_DATA_DIR:-/tmp/ci-box-synapse-data}"
SYNAPSE_HOST_PORT="${CI_BOX_SYNAPSE_HOST_PORT:-9999}"
SYNAPSE_HTTP_PORT="${CI_BOX_SYNAPSE_HTTP_PORT:-8008}"
SYNAPSE_BIND_ADDRESS="${CI_BOX_SYNAPSE_BIND_ADDRESS:-127.0.0.1}"
SYNAPSE_SERVER_NAME="${CI_BOX_SYNAPSE_SERVER_NAME:-localhost:9999}"
SYNAPSE_PUBLIC_BASEURL="${CI_BOX_SYNAPSE_PUBLIC_BASEURL:-http://localhost:9999}"
SYNAPSE_HTTP_ANTISPAM_SOURCE="${CI_BOX_SYNAPSE_HTTP_ANTISPAM_SOURCE:-/workspace-antispam-src}"
SYNAPSE_ANTISPAM_BASE_URL="${CI_BOX_SYNAPSE_ANTISPAM_BASE_URL:-http://host.docker.internal:8082/api/1/spam_check}"
SYNAPSE_IN_CONTAINER_PY_PACKAGES_PATH="${CI_BOX_SYNAPSE_IN_CONTAINER_PY_PACKAGES_PATH:-/usr/local/lib/python3.13/site-packages}"
SYNAPSE_OVERRIDES_FILE="${CI_BOX_SYNAPSE_OVERRIDES_FILE:-/usr/local/share/ci-box/scripts/synapse/homeserver.overrides.yaml}"
REVERSE_PROXY_CONFIG_PATH="${CI_BOX_REVERSE_PROXY_CONFIG_PATH:-${WORKSPACE_DST}/apps/draupnir/test/nginx.conf}"
REVERSE_PROXY_NEWS_PATH="${CI_BOX_REVERSE_PROXY_NEWS_PATH:-${WORKSPACE_DST}/apps/draupnir/test/draupnir_news.json}"
REVERSE_PROXY_NETWORK_MODE="${CI_BOX_REVERSE_PROXY_NETWORK_MODE:-host}"
REVERSE_PROXY_BIND="${CI_BOX_REVERSE_PROXY_BIND:-127.0.0.1:8081:80}"
DRAUPNIR_REGISTRATION_SOURCE="${CI_BOX_DRAUPNIR_REGISTRATION_SOURCE:-/usr/local/share/ci-box/scripts/appservice/draupnir-registration.yaml}"
DRAUPNIR_REGISTRATION_TARGET="${CI_BOX_DRAUPNIR_REGISTRATION_TARGET:-${WORKSPACE_DST}/apps/draupnir/draupnir-registration.yaml}"
DRAUPNIR_APPSERVICE_URL="${CI_BOX_DRAUPNIR_APPSERVICE_URL:-http://host.docker.internal:9000}"
INTEGRATION_COMMAND="${CI_BOX_INTEGRATION_COMMAND:-corepack npm run -w apps/draupnir test:integration}"
APPSERVICE_INTEGRATION_COMMAND="${CI_BOX_APPSERVICE_INTEGRATION_COMMAND:-corepack npm run -w apps/draupnir test:appservice:integration}"
SUPPORT_STACK_TIMEOUT_SEC="${CI_BOX_SUPPORT_STACK_TIMEOUT_SEC:-1200}"
ANTISPAM_ENABLED=1
ANTISPAM_HOST_FILE=""
CI_BOX_SMOKE_CHECK_ANTISPAM="${CI_BOX_SMOKE_CHECK_ANTISPAM:-0}"

TIMING_VERBOSE="${CI_BOX_TIMING_VERBOSE:-0}"
TARGET_COUNT=0
TARGET_COLD_COUNT=0
TARGET_WARM_COUNT=0
SUPPORT_STACK_REQUIRED=0
CI_BOX_EXIT_CODE=""

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

smoke_check_antispam_enabled() {
    case "${CI_BOX_SMOKE_CHECK_ANTISPAM}" in
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

TARGET="${1:-${TARGET:-}}"
if [[ -z "${TARGET}" ]]; then
    fail_usage "missing target"
fi

init_run_log_dir() {
    if [[ -n "${RUN_LOG_DIR}" ]]; then
        return
    fi
    RUN_LOG_DIR="${CI_BOX_LOG_DIR}"
    mkdir -p "${RUN_LOG_DIR}"
}

init_run_log_dir



log() {
    echo "[ci-box] $*"
}

CI_BOX_ROLE="${CI_BOX_ROLE:-orchestrator}"

is_runner() {
    [[ "${CI_BOX_ROLE}" == "runner" ]]
}

# Auto-runner controls
CI_BOX_RUNNER_IMAGE="${CI_BOX_RUNNER_IMAGE:-node:24-slim}"
CI_BOX_AUTO_RUNNER="${CI_BOX_AUTO_RUNNER:-1}"
# Match mx-tester harness assumptions (localhost-bound services).
CI_BOX_RUNNER_NETWORK_MODE="${CI_BOX_RUNNER_NETWORK_MODE:-host}"
# If set to 1, orchestrator will keep the stack up after the runner finishes (dev mode)
CI_BOX_ORCHESTRATOR_PERSIST_AFTER_RUN="${CI_BOX_ORCHESTRATOR_PERSIST_AFTER_RUN:-0}"
# Prefer the clearer container-name variable, but keep the old env var as a fallback.
CI_BOX_RUNNER_CONTAINER_NAME="${CI_BOX_RUNNER_CONTAINER_NAME:-${CI_BOX_RUNNER_CONTAINER:-ci-box-runner}}"

CI_BOX_LOG_DIR="${CI_BOX_LOG_DIR:-${WORKSPACE_DST}/.ci-box-logs}"
CI_BOX_DIAGNOSTICS_DIR="${CI_BOX_DIAGNOSTICS_DIR:-${CI_BOX_LOG_DIR}}"
CI_BOX_DIAGNOSTICS_ON_FAILURE="${CI_BOX_DIAGNOSTICS_ON_FAILURE:-1}"
RUN_LOG_DIR=""

diagnostics_enabled() {
    case "${CI_BOX_DIAGNOSTICS_ON_FAILURE}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

dump_support_stack_diagnostics() {
    local dir
    dir="${RUN_LOG_DIR}"
    if [[ -z "${dir}" ]]; then
        dir="${CI_BOX_DIAGNOSTICS_DIR}/$(date +%Y%m%d-%H%M%S)"
    fi

    mkdir -p "${dir}"
    log "orchestrator: writing diagnostics to ${dir}"

    docker ps -a >"${dir}/docker-ps.txt" 2>&1 || true
    docker network ls >"${dir}/docker-networks.txt" 2>&1 || true
    docker network inspect "${SUPPORT_NETWORK}" >"${dir}/network-${SUPPORT_NETWORK}.json" 2>&1 || true

    printf '%s\n' \
        "SYNAPSE_CONFIG_PATH=${SYNAPSE_CONFIG_PATH}" \
        "SYNAPSE_DATA_DIR=${SYNAPSE_DATA_DIR}" \
        "SYNAPSE_CONTAINER=${SYNAPSE_CONTAINER}" \
        "POSTGRES_CONTAINER=${POSTGRES_CONTAINER}" \
        "REVERSE_PROXY_CONTAINER=${REVERSE_PROXY_CONTAINER}" \
        "SYNAPSE_SERVER_NAME=${SYNAPSE_SERVER_NAME}" \
        "SYNAPSE_PUBLIC_BASEURL=${SYNAPSE_PUBLIC_BASEURL}" \
        "SYNAPSE_ANTISPAM_BASE_URL=${SYNAPSE_ANTISPAM_BASE_URL}" \
        "DRAUPNIR_APPSERVICE_URL=${DRAUPNIR_APPSERVICE_URL}" \
        "POSTGRES_BIND_ADDRESS=${POSTGRES_BIND_ADDRESS}" \
        "POSTGRES_HOST_PORT=${POSTGRES_HOST_PORT}" \
        "POSTGRES_DB=${POSTGRES_DB}" \
        "SYNAPSE_POSTGRES_DB=${SYNAPSE_POSTGRES_DB}" \
        "POSTGRES_USER=${POSTGRES_USER}" \
        "SUPPORT_NETWORK=${SUPPORT_NETWORK}" \
        "SYNAPSE_HTTP_PORT=${SYNAPSE_HTTP_PORT}" \
        "SYNAPSE_HOST_PORT=${SYNAPSE_HOST_PORT}" \
        >"${dir}/runtime-values.txt" 2>&1 || true

    if [[ -n "${SYNAPSE_CONFIG_PATH}" && -f "${SYNAPSE_CONFIG_PATH}" ]]; then
        cp "${SYNAPSE_CONFIG_PATH}" "${dir}/homeserver.yaml" 2>/dev/null || true
    fi

    if [[ -f "${DRAUPNIR_REGISTRATION_TARGET}" ]]; then
        cp "${DRAUPNIR_REGISTRATION_TARGET}" "${dir}/draupnir-registration.yaml" 2>/dev/null || true
    fi

    if [[ -f "${SYNAPSE_DATA_DIR}/homeserver.yaml" ]]; then
        cp "${SYNAPSE_DATA_DIR}/homeserver.yaml" "${dir}/homeserver.data.yaml" 2>/dev/null || true
    fi

    if [[ -f "${SYNAPSE_DATA_DIR}/homeserver.overrides.rendered.yaml" ]]; then
        cp "${SYNAPSE_DATA_DIR}/homeserver.overrides.rendered.yaml" "${dir}/homeserver.overrides.rendered.yaml" 2>/dev/null || true
    fi

    if [[ -d "${SYNAPSE_DATA_DIR}" ]]; then
        (cd "${SYNAPSE_DATA_DIR}" && ls -la) >"${dir}/synapse-data-dir.txt" 2>&1 || true
    fi

    for name in "${POSTGRES_CONTAINER}" "${SYNAPSE_CONTAINER}" "${REVERSE_PROXY_CONTAINER}"; do
        if docker ps -a --format '{{.Names}}' | grep -Fxq "${name}"; then
            docker inspect "${name}" >"${dir}/${name}.inspect.json" 2>&1 || true
            docker logs "${name}" >"${dir}/${name}.log" 2>&1 || true
        fi
    done
}

diagnostics_on_exit() {
    local rc=$?
    trap - EXIT
    if [[ -n "${CI_BOX_EXIT_CODE}" ]]; then
        rc="${CI_BOX_EXIT_CODE}"
    fi
    if is_runner; then
        log "runner: exiting with code ${rc}"
    else
        log "orchestrator: exiting with code ${rc}"
    fi
    if ! is_runner; then
        dump_support_stack_diagnostics || true
    fi
    exit ${rc}
}

trap diagnostics_on_exit EXIT

start_runner_container() {
    local runner_image="${CI_BOX_RUNNER_IMAGE}"

    require_file "${DRAUPNIR_REGISTRATION_SOURCE}" "CI_BOX_DRAUPNIR_REGISTRATION_SOURCE"

    if docker ps -a --format '{{.Names}}' | grep -Fxq "${CI_BOX_RUNNER_CONTAINER_NAME}"; then
        if ! docker ps --format '{{.Names}}' | grep -Fxq "${CI_BOX_RUNNER_CONTAINER_NAME}"; then
            docker start "${CI_BOX_RUNNER_CONTAINER_NAME}" >/dev/null
        fi
        return 0
    fi

    log "orchestrator: starting persistent runner container ${CI_BOX_RUNNER_CONTAINER_NAME} from ${runner_image}"
    docker run -d --name "${CI_BOX_RUNNER_CONTAINER_NAME}" \
        --network "${CI_BOX_RUNNER_NETWORK_MODE}" \
        --add-host=host.docker.internal:host-gateway \
        -e CI=1 \
        -e NPM_CONFIG_AUDIT=0 \
        -e NPM_CONFIG_LOGLEVEL=error \
        -e NPM_CONFIG_FUND=false \
        -e CI_BOX_MODE=local \
        -e CI_BOX_ROLE=runner \
        -e CI_BOX_NO_CACHE="${CI_BOX_NO_CACHE:-0}" \
        -e CI_BOX_TIMING_VERBOSE="${TIMING_VERBOSE}" \
        -e WORKSPACE_SRC=/workspace \
        -e WORKSPACE_DST=/workspace \
        -e CI_BOX_DRAUPNIR_REGISTRATION_PATH="${DRAUPNIR_REGISTRATION_TARGET}" \
        -v "${DRAUPNIR_REGISTRATION_SOURCE}:${DRAUPNIR_REGISTRATION_TARGET}:ro" \
        -v "${WORKSPACE_DST}:/workspace:rw" \
        "${runner_image}" sh -lc 'sleep infinity' >/dev/null
}

stop_runner_container() {
    docker rm -f "${CI_BOX_RUNNER_CONTAINER_NAME}" >/dev/null 2>&1 || true
}

run_runner_container() {
    local rc
    local runner_npm_command
    local runner_log

    start_runner_container
    rc=0
    runner_log="${RUN_LOG_DIR}/runner.log"

    if ! docker exec --user root "${CI_BOX_RUNNER_CONTAINER_NAME}" sh -lc 'command -v git >/dev/null 2>&1 && command -v bash >/dev/null 2>&1'; then
        log "orchestrator: installing git/bash in persistent runner ${CI_BOX_RUNNER_CONTAINER_NAME}"
        docker exec --user root "${CI_BOX_RUNNER_CONTAINER_NAME}" sh -lc 'set -e; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends git bash; elif command -v apk >/dev/null 2>&1; then apk add --no-cache git bash; else echo "No supported package manager found to install git/bash" >&2; exit 2; fi'
    fi

    case "${TARGET}" in
        integration)
            runner_npm_command="${INTEGRATION_COMMAND}"
            ;;
        appservice-integration)
            runner_npm_command="${APPSERVICE_INTEGRATION_COMMAND}"
            ;;
        *)
            log "orchestrator: no runner command available for target ${TARGET}"
            stop_runner_container
            return 2
            ;;
    esac

    log "orchestrator: running target ${TARGET} in persistent runner ${CI_BOX_RUNNER_CONTAINER_NAME}"
    set -o pipefail
    docker exec --user root \
        -e CI=1 \
        -e NPM_CONFIG_AUDIT=0 \
        -e NPM_CONFIG_LOGLEVEL=error \
        -e NPM_CONFIG_FUND=false \
        -e CI_BOX_MODE=local \
        -e CI_BOX_ROLE=runner \
        -e CI_BOX_NO_CACHE="${CI_BOX_NO_CACHE:-0}" \
        -e CI_BOX_TIMING_VERBOSE="${TIMING_VERBOSE}" \
        -e WORKSPACE_SRC=/workspace \
        -e WORKSPACE_DST=/workspace \
        -e CI_BOX_DRAUPNIR_REGISTRATION_PATH="${DRAUPNIR_REGISTRATION_TARGET}" \
        "${CI_BOX_RUNNER_CONTAINER_NAME}" \
        sh -lc "set -e; cd /workspace && ${runner_npm_command}" 2>&1 | tee -a "${runner_log}"
    rc=${PIPESTATUS[0]}
    set +o pipefail

    stop_runner_container
    return ${rc}
}

run_draupnir_command() {
    local cmd="$1"
    start_runner_container

    if ! docker exec --user root "${CI_BOX_RUNNER_CONTAINER_NAME}" sh -lc 'command -v git >/dev/null 2>&1 && command -v bash >/dev/null 2>&1'; then
        log "orchestrator: installing git/bash in persistent runner ${CI_BOX_RUNNER_CONTAINER_NAME}"
        docker exec --user root "${CI_BOX_RUNNER_CONTAINER_NAME}" sh -lc 'set -e; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends git bash; elif command -v apk >/dev/null 2>&1; then apk add --no-cache git bash; else echo "No supported package manager found to install git/bash" >&2; exit 2; fi'
    fi

    log "orchestrator: running Draupnir command in persistent runner ${CI_BOX_RUNNER_CONTAINER_NAME}: ${cmd}"
    set -o pipefail
    docker exec --user root \
        -e CI=1 \
        -e NPM_CONFIG_AUDIT=0 \
        -e NPM_CONFIG_LOGLEVEL=error \
        -e NPM_CONFIG_FUND=false \
        -e CI_BOX_MODE=local \
        -e CI_BOX_ROLE=runner \
        -e CI_BOX_NO_CACHE="${CI_BOX_NO_CACHE:-0}" \
        -e CI_BOX_TIMING_VERBOSE="${TIMING_VERBOSE}" \
        -e WORKSPACE_SRC=/workspace \
        -e WORKSPACE_DST=/workspace \
        -e CI_BOX_DRAUPNIR_REGISTRATION_PATH="${DRAUPNIR_REGISTRATION_TARGET}" \
        "${CI_BOX_RUNNER_CONTAINER_NAME}" sh -lc "set -e; cd /workspace && corepack enable >/dev/null && corepack npm ci && ${cmd}" 2>&1 | tee -a "${RUN_LOG_DIR}/runner.log"
    local rc=${PIPESTATUS[0]}
    set +o pipefail
    return ${rc}
}
# Determine whether this target requires support services for orchestration.
validate_mode_role() {
    SUPPORT_STACK_REQUIRED=0

    case "${TARGET}" in
        integration|appservice-integration|all)
            SUPPORT_STACK_REQUIRED=1
            # Runner mode for integration targets is a shortcut that expects an external orchestrator stack.
            if is_runner; then
                wait_for_orchestrator_stack
            fi
            ;;
        *)
            ;;
    esac
}

# Wait for an orchestrator-managed support stack to be reachable from the runner.
wait_for_orchestrator_stack() {
    local deadline now
    local host_target="host.docker.internal"
    deadline=$((SECONDS + SUPPORT_STACK_TIMEOUT_SEC))

    log "runner: waiting up to ${SUPPORT_STACK_TIMEOUT_SEC}s for orchestrator stack at ${host_target}:${SYNAPSE_HOST_PORT} and ${host_target}:${POSTGRES_HOST_PORT}"

    while [[ ${SECONDS} -lt ${deadline} ]]; do
        if curl --fail --silent "http://${host_target}:${SYNAPSE_HOST_PORT}" >/dev/null 2>&1; then
            if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${host_target}" -p "${POSTGRES_HOST_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c '\q' >/dev/null 2>&1; then
                log "runner: detected orchestrator support stack reachable"
                return 0
            fi
        fi
        sleep 2
    done

    log "runner: timed out waiting for orchestrator support stack"
    exit 3
}

configure_git_context() {
    # Keep git environment unscoped so each git invocation can target its own repository.
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

    if [[ -z "${WORKSPACE_DST}" || "${WORKSPACE_DST}" == "/" ]]; then
        log "refusing to sync into unsafe workspace destination: ${WORKSPACE_DST}"
        exit 2
    fi

    mkdir -p "${WORKSPACE_DST}"

    if ! is_runner && command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' | grep -Fxq "${CI_BOX_RUNNER_CONTAINER_NAME}"; then
            log "workspace sync: runner container ${CI_BOX_RUNNER_CONTAINER_NAME} is active; preserving workspace root inode"
        else
            log "workspace sync: runner container ${CI_BOX_RUNNER_CONTAINER_NAME} is not active"
        fi
    fi

    # Keep the mount root inode stable, but clear prior contents for clean-slate behavior.
    shopt -s dotglob nullglob
    for entry in "${WORKSPACE_DST}"/*; do
        rm -rf -- "${entry}"
    done
    shopt -u dotglob nullglob

    # Rehydrate from source under the sync exclusion contract.
    rsync -a --delete \
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

install_dependencies() {
    local lock_hash lock_hash_file install_start install_end install_ms

    if ! is_runner; then
        log "orchestrator: skipping dependency install; runner image must perform installs"
        return
    fi

    cd "${WORKSPACE_DST}"
    corepack enable >/dev/null

    # Stateless mode: always perform a clean install inside the runner
    install_start="$(now_ms)"
    corepack npm ci
    install_end="$(now_ms)"
    install_ms=$((install_end - install_start))
    if timing_verbose_enabled; then
        log "timing phase=npm-ci duration_ms=${install_ms}"
    fi
    TARGET_DEP_OUTCOME="miss"
    DEPENDENCY_INSTALL_COUNT=$((DEPENDENCY_INSTALL_COUNT + 1))
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

log_support_stack_config() {
    log "support network=${SUPPORT_NETWORK} synapse_image=${SYNAPSE_IMAGE} postgres_image=${POSTGRES_IMAGE} reverse_proxy_image=${REVERSE_PROXY_IMAGE}"
    log "support config synapse_config_path=${SYNAPSE_CONFIG_PATH} synapse_data_dir=${SYNAPSE_DATA_DIR} synapse_config_template=${SYNAPSE_OVERRIDES_FILE}"
    log "support config reverse_proxy_config_path=${REVERSE_PROXY_CONFIG_PATH} reverse_proxy_network_mode=${REVERSE_PROXY_NETWORK_MODE}"
}

log_effective_runtime_values() {
    log "effective synapse_server_name=${SYNAPSE_SERVER_NAME} synapse_public_baseurl=${SYNAPSE_PUBLIC_BASEURL}"
    log "effective synapse_antispam_base_url=${SYNAPSE_ANTISPAM_BASE_URL} draupnir_appservice_url=${DRAUPNIR_APPSERVICE_URL}"
    log "effective postgres_bind=${POSTGRES_BIND_ADDRESS}:${POSTGRES_HOST_PORT} postgres_db=${POSTGRES_DB} synapse_db=${SYNAPSE_POSTGRES_DB} postgres_user=${POSTGRES_USER}"
    log "effective registration_target=${DRAUPNIR_REGISTRATION_TARGET} synapse_config_path=${SYNAPSE_CONFIG_PATH}"
}

require_file() {
    local path="$1"
    local label="$2"

    if [[ -z "${path}" ]]; then
        log "${label} is required"
        exit 2
    fi

    if [[ ! -f "${path}" ]]; then
        log "${label} not found: ${path}"
        exit 2
    fi
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

render_template_file() {
    local source="$1"
    local target="$2"
    local escaped_synapse_server_name
    local escaped_synapse_public_baseurl
    local escaped_synapse_antispam_base_url
    local escaped_draupnir_appservice_url
    local escaped_synapse_db

    require_file "${source}" "template source"
    mkdir -p "$(dirname "${target}")"

    escaped_synapse_server_name="$(escape_sed_replacement "${SYNAPSE_SERVER_NAME}")"
    escaped_synapse_public_baseurl="$(escape_sed_replacement "${SYNAPSE_PUBLIC_BASEURL}")"
    escaped_synapse_antispam_base_url="$(escape_sed_replacement "${SYNAPSE_ANTISPAM_BASE_URL}")"
    escaped_draupnir_appservice_url="$(escape_sed_replacement "${DRAUPNIR_APPSERVICE_URL}")"
    escaped_synapse_db="$(escape_sed_replacement "${SYNAPSE_POSTGRES_DB}")"

    sed \
        -e "s|__CI_BOX_SYNAPSE_SERVER_NAME__|${escaped_synapse_server_name}|g" \
        -e "s|__CI_BOX_SYNAPSE_PUBLIC_BASEURL__|${escaped_synapse_public_baseurl}|g" \
        -e "s|__CI_BOX_SYNAPSE_ANTISPAM_BASE_URL__|${escaped_synapse_antispam_base_url}|g" \
        -e "s|__CI_BOX_DRAUPNIR_APPSERVICE_URL__|${escaped_draupnir_appservice_url}|g" \
        -e "s|__CI_BOX_SYNAPSE_DB__|${escaped_synapse_db}|g" \
        "${source}" >"${target}"
}

ensure_postgres_databases() {
    local db_locale

    db_locale=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
        sh -lc "psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -tAc \"SELECT datcollate || '|' || datctype FROM pg_database WHERE datname='${SYNAPSE_POSTGRES_DB}'\"" \
        2>/dev/null || true)
    db_locale="$(printf '%s' "${db_locale}" | tr -d '[:space:]')"

    if [[ -z "${db_locale}" ]]; then
        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
            sh -lc "psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -v ON_ERROR_STOP=1 -c \"CREATE DATABASE \\\"${SYNAPSE_POSTGRES_DB}\\\" LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0\"" >/dev/null
        return 0
    fi

    if [[ "${db_locale}" != "C|C" ]]; then
        if [[ "${SYNAPSE_POSTGRES_DB}" == "${POSTGRES_DB}" ]]; then
            log "synapse postgres db collation is ${db_locale}; expected C|C"
            log "recreate ${SYNAPSE_POSTGRES_DB} with LC_COLLATE=C and LC_CTYPE=C (template0)"
            exit 3
        fi

        log "synapse postgres db has collation ${db_locale}; recreating with LC_COLLATE=C"
        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
            sh -lc "psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -v ON_ERROR_STOP=1 -c \"DROP DATABASE \\\"${SYNAPSE_POSTGRES_DB}\\\"\"" >/dev/null
        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
            sh -lc "psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -v ON_ERROR_STOP=1 -c \"CREATE DATABASE \\\"${SYNAPSE_POSTGRES_DB}\\\" LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0\"" >/dev/null
        return 0
    fi
}

ensure_draupnir_registration() {
    mkdir -p "$(dirname "${DRAUPNIR_REGISTRATION_TARGET}")"
    render_template_file "${DRAUPNIR_REGISTRATION_SOURCE}" "${DRAUPNIR_REGISTRATION_TARGET}"
}

ensure_direct_docker_support_stack() {
    if [[ -n "${SYNAPSE_CONFIG_PATH}" ]]; then
        require_file "${SYNAPSE_CONFIG_PATH}" "CI_BOX_SYNAPSE_CONFIG_PATH"
    fi

    if [[ -n "${REVERSE_PROXY_CONFIG_PATH}" ]]; then
        require_file "${REVERSE_PROXY_CONFIG_PATH}" "CI_BOX_REVERSE_PROXY_CONFIG_PATH"
        require_file "${REVERSE_PROXY_NEWS_PATH}" "CI_BOX_REVERSE_PROXY_NEWS_PATH"
    fi
}

ensure_synapse_config() {
    if [[ -n "${SYNAPSE_CONFIG_PATH}" ]]; then
        return
    fi

    mkdir -p "${SYNAPSE_DATA_DIR}"

    require_file "${SYNAPSE_OVERRIDES_FILE}" "CI_BOX_SYNAPSE_OVERRIDES_FILE"

    docker run --rm \
        -e SYNAPSE_SERVER_NAME="${SYNAPSE_SERVER_NAME}" \
        -e SYNAPSE_REPORT_STATS=no \
        -e SYNAPSE_CONFIG_PATH="/data/homeserver.yaml" \
        -v "${SYNAPSE_DATA_DIR}:/data" \
        "${SYNAPSE_IMAGE}" generate >/dev/null

    SYNAPSE_CONFIG_PATH="${SYNAPSE_DATA_DIR}/homeserver.yaml"
    render_template_file "${SYNAPSE_OVERRIDES_FILE}" "${SYNAPSE_CONFIG_PATH}"
}

ensure_synapse_http_antispam() {
    if [[ -z "${SYNAPSE_HTTP_ANTISPAM_SOURCE}" ]]; then
        log "CI_BOX_SYNAPSE_HTTP_ANTISPAM_SOURCE is required and must point to an external synapse-http-antispam checkout"
        exit 2
    fi

    if [[ -f "${SYNAPSE_HTTP_ANTISPAM_SOURCE}" ]]; then
        ANTISPAM_HOST_FILE="${SYNAPSE_HTTP_ANTISPAM_SOURCE}"
    else
        ANTISPAM_HOST_FILE="${SYNAPSE_HTTP_ANTISPAM_SOURCE}/synapse_http_antispam.py"
    fi

    if [[ ! -f "${ANTISPAM_HOST_FILE}" ]]; then
        log "CI_BOX_SYNAPSE_HTTP_ANTISPAM_SOURCE must contain synapse_http_antispam.py: ${ANTISPAM_HOST_FILE}"
        exit 2
    fi
}

sync_synapse_config_into_data_dir() {
    local target

    target="${SYNAPSE_DATA_DIR}/homeserver.yaml"
    mkdir -p "${SYNAPSE_DATA_DIR}"
    if [[ "${SYNAPSE_CONFIG_PATH}" != "${target}" ]]; then
        cp "${SYNAPSE_CONFIG_PATH}" "${target}"
        SYNAPSE_CONFIG_PATH="${target}"
    fi

    # Normalize the generated listener port even if the config already exists
        if [[ -f "${target}" ]]; then
            sed -i -E "s/^[[:space:]]*-[[:space:]]*port:[[:space:]]*[0-9]+/  - port: ${SYNAPSE_HTTP_PORT}/" "${target}" || true
        fi
}

ensure_integration_support_stack() {
    ensure_direct_docker_support_stack
    ensure_draupnir_registration
    require_file "${DRAUPNIR_REGISTRATION_SOURCE}" "CI_BOX_DRAUPNIR_REGISTRATION_SOURCE"
}

preclean_integration_support_state() {
    # Ensure we always start integration targets from a clean slate, even after interrupted runs.
    docker rm -f \
        "${POSTGRES_CONTAINER}" \
        "${SYNAPSE_CONTAINER}" \
        "${REVERSE_PROXY_CONTAINER}" >/dev/null 2>&1 || true
    docker network rm "${SUPPORT_NETWORK}" >/dev/null 2>&1 || true
}

wait_for_postgres() {
    local deadline
    deadline=$((SECONDS + SUPPORT_STACK_TIMEOUT_SEC))

    while [[ ${SECONDS} -lt ${deadline} ]]; do
        if docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1 && \
            docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" sh -lc "psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -tAc 'SELECT 1'" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    log "postgres did not become ready in ${SUPPORT_STACK_TIMEOUT_SEC}s"
    docker logs "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
    exit 3
}

wait_for_synapse() {
    local deadline
    deadline=$((SECONDS + SUPPORT_STACK_TIMEOUT_SEC))

    while [[ ${SECONDS} -lt ${deadline} ]]; do
        if curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:${SYNAPSE_HOST_PORT}/_synapse/admin/v1/server_version" >/dev/null 2>&1 || \
            curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:${SYNAPSE_HOST_PORT}/health" >/dev/null 2>&1 || \
            curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:${SYNAPSE_HOST_PORT}/_matrix/client/versions" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    log "synapse did not become ready in ${SUPPORT_STACK_TIMEOUT_SEC}s"
    docker logs "${SYNAPSE_CONTAINER}" >/dev/null 2>&1 || true
    exit 3
}

support_stack_up_direct_docker() {
    ensure_synapse_http_antispam
    ensure_draupnir_registration
    ensure_synapse_config
    sync_synapse_config_into_data_dir
    require_file "${DRAUPNIR_REGISTRATION_SOURCE}" "CI_BOX_DRAUPNIR_REGISTRATION_SOURCE"
    docker network create "${SUPPORT_NETWORK}" >/dev/null 2>&1 || true

    docker run -d --name "${POSTGRES_CONTAINER}" --network "${SUPPORT_NETWORK}" \
        -p "${POSTGRES_BIND_ADDRESS}:${POSTGRES_HOST_PORT}:5432" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e POSTGRES_DB="${POSTGRES_DB}" \
        "${POSTGRES_IMAGE}" >/dev/null

    wait_for_postgres
    ensure_postgres_databases

    if [[ -n "${REVERSE_PROXY_CONFIG_PATH}" ]]; then
        if [[ "${REVERSE_PROXY_NETWORK_MODE}" == "host" ]]; then
            docker run -d --name "${REVERSE_PROXY_CONTAINER}" --network host \
                -v "${REVERSE_PROXY_CONFIG_PATH}:/etc/nginx/nginx.conf:ro" \
                -v "${REVERSE_PROXY_NEWS_PATH}:/var/www/test/draupnir_news.json:ro" \
                "${REVERSE_PROXY_IMAGE}" >/dev/null
        else
            docker run -d --name "${REVERSE_PROXY_CONTAINER}" --network "${SUPPORT_NETWORK}" \
                -p "${REVERSE_PROXY_BIND}" \
                -v "${REVERSE_PROXY_CONFIG_PATH}:/etc/nginx/nginx.conf:ro" \
                -v "${REVERSE_PROXY_NEWS_PATH}:/var/www/test/draupnir_news.json:ro" \
                "${REVERSE_PROXY_IMAGE}" >/dev/null
        fi
    fi

    if [[ "${ANTISPAM_ENABLED}" == "1" && -f "${ANTISPAM_HOST_FILE}" ]]; then
        ANTISPAM_EXTRA_VOLUMES="-v ${ANTISPAM_HOST_FILE}:${SYNAPSE_IN_CONTAINER_PY_PACKAGES_PATH}/synapse_http_antispam.py:ro"
    else
        ANTISPAM_EXTRA_VOLUMES=""
    fi

    docker run -d --name "${SYNAPSE_CONTAINER}" --network "${SUPPORT_NETWORK}" \
        -p "${SYNAPSE_BIND_ADDRESS}:${SYNAPSE_HOST_PORT}:${SYNAPSE_HTTP_PORT}" \
        --add-host=host.docker.internal:host-gateway \
        -v "${SYNAPSE_DATA_DIR}:/data" \
        -v "${DRAUPNIR_REGISTRATION_TARGET}:/data/draupnir-registration.yaml:ro" \
        ${ANTISPAM_EXTRA_VOLUMES} \
        -e SYNAPSE_SERVER_NAME="${SYNAPSE_SERVER_NAME}" \
        -e SYNAPSE_REPORT_STATS=no \
        -e SYNAPSE_CONFIG_PATH="/data/$(basename "${SYNAPSE_CONFIG_PATH}")" \
        "${SYNAPSE_IMAGE}" >/dev/null

    wait_for_synapse
}

smoke_check_support_stack() {
    local synapse_host_target

    log_effective_runtime_values

    if is_runner; then
        synapse_host_target="host.docker.internal"
    else
        synapse_host_target="127.0.0.1"
    fi

    if [[ -f "${SYNAPSE_CONFIG_PATH}" ]]; then
        if ! grep -Fq "server_name: \"${SYNAPSE_SERVER_NAME}\"" "${SYNAPSE_CONFIG_PATH}"; then
            log "rendered synapse config does not contain the expected server_name"
            exit 3
        fi

        if ! grep -Fq "public_baseurl: \"${SYNAPSE_PUBLIC_BASEURL}\"" "${SYNAPSE_CONFIG_PATH}"; then
            log "rendered synapse config does not contain the expected public_baseurl"
            exit 3
        fi

        if ! grep -Fq "base_url: ${SYNAPSE_ANTISPAM_BASE_URL}" "${SYNAPSE_CONFIG_PATH}"; then
            log "rendered synapse config does not contain the expected antispam base_url"
            exit 3
        fi
    fi

    if [[ -f "${DRAUPNIR_REGISTRATION_TARGET}" ]] && ! grep -Fq "url: \"${DRAUPNIR_APPSERVICE_URL}\"" "${DRAUPNIR_REGISTRATION_TARGET}"; then
        log "rendered appservice registration does not contain the expected appservice url"
        exit 3
    fi

    if ! curl --fail --silent --show-error --max-time 5 "http://${synapse_host_target}:${SYNAPSE_HOST_PORT}/_matrix/client/versions" >/dev/null 2>&1; then
        log "synapse versions endpoint not reachable on ${synapse_host_target}:${SYNAPSE_HOST_PORT}"
        exit 3
    fi

    if ! is_runner; then
        if ! docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" sh -lc "psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -tAc 'SELECT 1'" >/dev/null 2>&1; then
            log "postgres SELECT 1 smoke check failed inside ${POSTGRES_CONTAINER}"
            exit 3
        fi

        if [[ "${SYNAPSE_POSTGRES_DB}" != "${POSTGRES_DB}" ]]; then
            if ! docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" sh -lc "psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${SYNAPSE_POSTGRES_DB}' -tAc 'SELECT 1'" >/dev/null 2>&1; then
                log "synapse postgres SELECT 1 smoke check failed inside ${POSTGRES_CONTAINER}"
                exit 3
            fi
        fi

        if smoke_check_antispam_enabled && [[ -f "${ANTISPAM_HOST_FILE}" ]]; then
            if ! docker exec -i -e ANTISPAM_URL="${SYNAPSE_ANTISPAM_BASE_URL}" "${SYNAPSE_CONTAINER}" python - <<'PY' >/dev/null 2>&1
import os
import urllib.request

with urllib.request.urlopen(os.environ["ANTISPAM_URL"], timeout=5) as response:
    response.read()
PY
            then
                log "antispam endpoint not reachable from ${SYNAPSE_CONTAINER} at ${SYNAPSE_ANTISPAM_BASE_URL}"
                exit 3
            fi
        fi
    fi
}

support_stack_down_direct_docker() {
    docker rm -f \
        "${REVERSE_PROXY_CONTAINER}" \
        "${SYNAPSE_CONTAINER}" \
        "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
    docker network rm "${SUPPORT_NETWORK}" >/dev/null 2>&1 || true
}

support_stack_up() {
    support_stack_up_direct_docker
}

support_stack_down() {
    support_stack_down_direct_docker
}

run_workspace_command() {
    local command="$1"

    if ! is_runner; then
        log "orchestrator: refusing to run workspace commands; delegate to runner"
        exit 2
    fi

    if [[ -z "${command}" ]]; then
        log "command is required"
        exit 2
    fi

    cd "${WORKSPACE_DST}"
    bash -lc "${command}"
}

run_integration_tests() {
    if [[ -z "${INTEGRATION_COMMAND}" ]]; then
        log "CI_BOX_INTEGRATION_COMMAND is required"
        exit 2
    fi

    if is_runner; then
        run_workspace_command "${INTEGRATION_COMMAND}"
    else
        run_draupnir_command "${INTEGRATION_COMMAND}"
    fi
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
    if [[ "${BUILD_ALL_DONE_THIS_RUN}" == "1" ]]; then
        TARGET_BUILD_OUTCOME="already-built"
        return
    fi

    if is_runner; then
        cd "${WORKSPACE_DST}"
        build_start="$(now_ms)"
        corepack npm run build:all
        build_end="$(now_ms)"
        build_ms=$((build_end - build_start))
        if timing_verbose_enabled; then
            log "timing phase=build-all duration_ms=${build_ms}"
        fi
        BUILD_ALL_DONE_THIS_RUN=1
        TARGET_BUILD_OUTCOME="miss"
        BUILD_RUN_COUNT=$((BUILD_RUN_COUNT + 1))
        return
    else
        run_draupnir_command "corepack npm run build:all"
        BUILD_ALL_DONE_THIS_RUN=1
        TARGET_BUILD_OUTCOME="miss"
        BUILD_RUN_COUNT=$((BUILD_RUN_COUNT + 1))
        return
    fi
}

ensure_build() {
    local build_start build_end build_ms

    if [[ "${BUILD_DONE_THIS_RUN}" == "1" ]]; then
        TARGET_BUILD_OUTCOME="already-built"
        return
    fi

    if is_runner; then
        cd "${WORKSPACE_DST}"
        build_start="$(now_ms)"
        corepack npm run build
        build_end="$(now_ms)"
        build_ms=$((build_end - build_start))
        if timing_verbose_enabled; then
            log "timing phase=build duration_ms=${build_ms}"
        fi
        BUILD_DONE_THIS_RUN=1
        TARGET_BUILD_OUTCOME="miss"
        BUILD_RUN_COUNT=$((BUILD_RUN_COUNT + 1))
        return
    else
        run_draupnir_command "corepack npm run build"
        BUILD_DONE_THIS_RUN=1
        TARGET_BUILD_OUTCOME="miss"
        BUILD_RUN_COUNT=$((BUILD_RUN_COUNT + 1))
        return
    fi
}

run_target_with_timing() {
    local name fn start end duration fn_rc
    local dep_installs_before dep_installs_after build_runs_before build_runs_after cache_profile

    name="$1"
    fn="$2"

    TARGET_DEP_OUTCOME="not-evaluated"
    TARGET_BUILD_OUTCOME="not-evaluated"
    dep_installs_before="${DEPENDENCY_INSTALL_COUNT}"
    build_runs_before="${BUILD_RUN_COUNT}"

    start="$(now_ms)"
    "${fn}"
    fn_rc=$?
    if [[ "${fn_rc}" -ne 0 ]]; then
        CI_BOX_EXIT_CODE="${fn_rc}"
    fi
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
    return ${fn_rc}
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
    if is_runner; then
        prepare_workspace
        ensure_version_branch_files
        ensure_build
        cd "${WORKSPACE_DST}"
        corepack npm run lint
    else
        run_draupnir_command "corepack npm run build && corepack npm run lint"
    fi
}

run_unit() {
    if is_runner; then
        prepare_workspace
        ensure_version_branch_files
        ensure_build_all
        cd "${WORKSPACE_DST}"
        corepack npm run test
    else
        run_draupnir_command "corepack npm run build:all && corepack npm run test"
    fi
}

run_integration_common() {
    prepare_workspace
    ensure_version_branch_files
    log_support_stack_config
    ensure_integration_support_stack
    preclean_integration_support_state
    ensure_build_all
}

run_integration() {
    if is_runner; then
        prepare_workspace
        ensure_version_branch_files
        ensure_build_all
        smoke_check_support_stack
        run_integration_tests
    else
        local runner_rc=0

        run_integration_common
        support_stack_up
        log "orchestrator: support stack is up and exposed on host (postgres:${POSTGRES_HOST_PORT}, synapse:${SYNAPSE_HOST_PORT})."
        smoke_check_support_stack

        if [[ "${CI_BOX_AUTO_RUNNER}" == "1" ]]; then
            run_runner_container || runner_rc=$?
        else
            log "orchestrator: auto-runner disabled (CI_BOX_AUTO_RUNNER!=1); not launching runner"
        fi

        if [[ "${CI_BOX_ORCHESTRATOR_PERSIST_AFTER_RUN}" == "1" ]]; then
            log "orchestrator: persistent mode enabled; leaving support stack running after runner exits"
            log "Press Ctrl+C to tear down the stack manually."

            teardown() {
                support_stack_down
                exit 0
            }

            trap teardown INT TERM
            while true; do
                sleep 3600
            done
        else
            dump_support_stack_diagnostics || true
            log "orchestrator: runner finished; tearing down support stack"
            support_stack_down
        fi

        if [[ "${runner_rc}" -ne 0 ]]; then
            log "orchestrator: runner failed with exit code ${runner_rc}"
            return "${runner_rc}"
        fi
    fi
}

run_appservice_integration() {
    if is_runner; then
        prepare_workspace
        ensure_version_branch_files
        ensure_build_all
        smoke_check_support_stack
        run_workspace_command "${APPSERVICE_INTEGRATION_COMMAND}"
    else
        local runner_rc=0

        run_integration_common
        support_stack_up
        log "orchestrator: support stack is up and exposed on host (postgres:${POSTGRES_HOST_PORT}, synapse:${SYNAPSE_HOST_PORT})."
        smoke_check_support_stack

        if [[ "${CI_BOX_AUTO_RUNNER}" == "1" ]]; then
            run_runner_container || runner_rc=$?
        else
            log "orchestrator: auto-runner disabled (CI_BOX_AUTO_RUNNER!=1); not launching runner"
        fi

        if [[ "${CI_BOX_ORCHESTRATOR_PERSIST_AFTER_RUN}" == "1" ]]; then
            log "orchestrator: persistent mode enabled; leaving support stack running after runner exits"
            log "Press Ctrl+C to tear down the stack manually."

            teardown() {
                support_stack_down
                exit 0
            }

            trap teardown INT TERM
            while true; do
                sleep 3600
            done
        else
            dump_support_stack_diagnostics || true
            log "orchestrator: runner finished; tearing down support stack"
            support_stack_down
        fi

        if [[ "${runner_rc}" -ne 0 ]]; then
            log "orchestrator: runner failed with exit code ${runner_rc}"
            return "${runner_rc}"
        fi
    fi
}

validate_mode_role

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
        TARGET="build-lint"
        run_target_with_timing "build-lint" run_build_lint
        TARGET="unit"
        run_target_with_timing "unit" run_unit
        TARGET="integration"
        run_target_with_timing "integration" run_integration
        TARGET="appservice-integration"
        run_target_with_timing "appservice-integration" run_appservice_integration
        ;;
    *)
        fail_usage "unknown target '${TARGET}'"
        ;;
esac

print_timing_summary
