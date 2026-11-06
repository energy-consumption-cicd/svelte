# syntax=docker/dockerfile:1

# The Lint and Tests jobs of ci.yml check out the reference commit, install
# Node 24 with actions/setup-node, pnpm from packageManager and the lockfile
# tree; the Tests job also downloads Chromium. The image holds all of it and a
# tree with no build output, so both measured stages start where the jobs start.
FROM ubuntu@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

# The latest Node 24 patch on the date of the tag's reference run, which is what
# actions/setup-node resolves for node-version 24 in the Tests job; the run logs have expired.
ARG NODE_VERSION=24.13.0
ARG NODE_SHA256=e798599612f4bb71333a3397ab0d095fd62214e115aea45aa858a145fc72d67e
# The Lint job, which holds the build step, runs on node-version 18 at this tag:
# the last Node 18 release, installed apart and selected by the build stage only.
ARG NODE18_VERSION=18.20.8
ARG NODE18_SHA256=5467ee62d6af1411d46b6a10e3fb5cacc92734dbcef465fea14e7b90993001c9
ARG SVELTE_SHA=c1fab8caae8334ebc1db7fb37d618ca204e461ab

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils git; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  node-v${NODE_VERSION}-linux-x64.tar.xz" | sha256sum -c -; \
    tar -xJf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    node --version

RUN set -eux; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE18_VERSION}/node-v${NODE18_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE18_SHA256}  node-v${NODE18_VERSION}-linux-x64.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/node18; \
    tar -xJf "node-v${NODE18_VERSION}-linux-x64.tar.xz" -C /opt/node18 --strip-components=1 --no-same-owner; \
    rm -f "node-v${NODE18_VERSION}-linux-x64.tar.xz"; \
    /opt/node18/bin/node --version

# The workflow-level variable of ci.yml: Chromium enters only through its own step.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0

RUN corepack enable pnpm && PATH=/opt/node18/bin:$PATH corepack enable pnpm

# The hosted runner is unprivileged; uid 1000 matches the bench user, so the
# timing volume run_pipeline.sh mounts is writable. The base image holds that uid.
RUN userdel -r ubuntu && useradd -m -u 1000 runner \
    && mkdir -p /workspace && chown runner:runner /workspace

ENV HOME=/home/runner
USER runner
WORKDIR /workspace

# actions/checkout of the reference commit.
RUN git clone https://github.com/sveltejs/svelte.git . \
    && git checkout --detach "$SVELTE_SHA" \
    && test "$(git rev-parse HEAD)" = "$SVELTE_SHA"

# pnpm/action-setup reads packageManager; at this tag it carries no hash.
RUN corepack install && pnpm --version \
    && PATH=/opt/node18/bin:$PATH corepack install && PATH=/opt/node18/bin:$PATH pnpm --version

RUN pnpm install --frozen-lockfile

# Chromium system libraries: the hosted runner ships them, this base does not.
USER root
RUN ./node_modules/.bin/playwright install-deps chromium \
    && rm -rf /var/lib/apt/lists/*
USER runner

# Tests job, step "pnpm playwright install chromium".
RUN pnpm playwright install chromium

# No build output in the tree: both stages start from the checkout, as the jobs do.
RUN test -z "$(git status --porcelain)" \
    && test ! -e packages/svelte/compiler/index.js \
    && test ! -e packages/svelte/index.d.ts \
    && test ! -e packages/svelte/types/compiler \
    && test ! -e node_modules/.vite
