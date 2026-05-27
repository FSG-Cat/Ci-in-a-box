#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Catalan Lover <catalanlover@protonmail.com>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Usage: ci-box <build-lint|unit|integration|appservice-integration|all>" >&2
    exit 2
fi

shift || true

export CI=1
export CI_BOX_MODE="${CI_BOX_MODE:-local}"
export CI_BOX_ROLE="${CI_BOX_ROLE:-orchestrator}"
export DOCKER_HOST="unix:///var/run/docker.sock"

if [[ "${CI_BOX_ROLE}" == "runner" ]]; then
    exec /usr/local/bin/ci-targets.sh "$TARGET" "$@"
fi

DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/var/lib/docker}"
DOCKERD_LOG="/tmp/dockerd.log"

mkdir -p "${DOCKER_DATA_ROOT}"

if [[ "${CI_BOX_VERBOSE:-0}" == "1" ]]; then
    echo "[ci-box] starting dockerd with data root ${DOCKER_DATA_ROOT}"
fi

nohup dockerd \
    --host="${DOCKER_HOST}" \
    --data-root="${DOCKER_DATA_ROOT}" \
    --storage-driver=overlay2 \
    >"${DOCKERD_LOG}" 2>&1 &

for i in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! docker info >/dev/null 2>&1; then
    echo "[ci-box] dockerd failed to start" >&2
    tail -n 200 "${DOCKERD_LOG}" >&2 || true
    exit 3
fi

if docker buildx version >/dev/null 2>&1; then
    docker buildx create --name ci-box-builder --driver docker-container --use >/dev/null 2>&1 || true
    docker buildx use ci-box-builder >/dev/null 2>&1 || true
fi

exec /usr/local/bin/ci-targets.sh "$TARGET" "$@"
