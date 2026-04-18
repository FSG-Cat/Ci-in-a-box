# SPDX-FileCopyrightText: 2026 Catalan Lover <catalanlover@protonmail.com>
#
# SPDX-License-Identifier: Apache-2.0

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV CI=1
ENV CI_BOX_MODE=local

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        cargo \
        curl \
        file \
        git \
        iproute2 \
        iptables \
        jq \
        libssl-dev \
        pkg-config \
        postgresql-client \
        python3 \
        rsync \
        rustc \
        tini \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace-src /workspace /cache/npm /cache/cargo /var/lib/docker

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/ci-targets.sh /usr/local/bin/ci-targets.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/ci-targets.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
