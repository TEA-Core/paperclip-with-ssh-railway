# =============================================================================
# Paperclip Railway Template + SSH access
#
# Adds an OpenSSH server alongside the Paperclip app process, supervised by
# s6-overlay. Claude Code / Codex / OpenCode credentials are persisted on the
# /paperclip volume and SHARED between the SSH user and Paperclip's internal
# agents (one Max OAuth covers both).
#
# Auth: SSH key only. Provide AUTHORIZED_KEYS at deploy time.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: build upstream Paperclip (unchanged from upstream template)
# -----------------------------------------------------------------------------
FROM node:22-bookworm AS paperclip-build
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

ARG PAPERCLIP_REPO=https://github.com/paperclipai/paperclip.git
ARG PAPERCLIP_REF=v2026.416.0

WORKDIR /paperclip-src
RUN git clone --depth 1 --branch "${PAPERCLIP_REF}" "${PAPERCLIP_REPO}" .
RUN pnpm install --frozen-lockfile
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js

# -----------------------------------------------------------------------------
# Stage 2: runtime
# -----------------------------------------------------------------------------
FROM node:22-bookworm
ENV NODE_ENV=production
ENV CLAUDE_CODE_BUBBLEWRAP=1

# Tell s6-overlay to preserve the container startup environment and make it
# available to services via `with-contenv`. Without this, only PATH leaks
# through to oneshots/longruns and the Railway-injected variables (like
# AUTHORIZED_KEYS, DATABASE_URL, etc.) never reach the init scripts.
ENV S6_KEEP_ENV=1

# Match upstream defaults so Paperclip's agent tooling, OpenCode, and config
# paths behave consistently.
ENV HOME=/paperclip \
    PAPERCLIP_INSTANCE_ID=default \
    PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
    OPENCODE_ALLOW_ALL_MODELS=true

# System deps: Paperclip's needs + sshd + s6-overlay deps + setpriv (util-linux)
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       git \
       jq \
       openssh-client \
       openssh-server \
       ripgrep \
       sudo \
       util-linux \
       xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && chmod 755 /run/sshd \
    && rm -f /etc/motd /etc/update-motd.d/* \
    && touch /etc/motd
RUN corepack enable

# s6-overlay
ARG S6_OVERLAY_VERSION=3.2.0.2
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/s6-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/s6-x86_64.tar.xz
RUN tar -C / -Jxpf /tmp/s6-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-x86_64.tar.xz \
    && rm /tmp/s6-noarch.tar.xz /tmp/s6-x86_64.tar.xz

# Bring in built Paperclip
WORKDIR /app
COPY --from=paperclip-build /paperclip-src /app

# Wrapper (Paperclip's setup UI proxy)
WORKDIR /wrapper
COPY package.json /wrapper/package.json
RUN npm install --omit=dev && npm cache clean --force
COPY src /wrapper/src
COPY scripts/bootstrap-ceo.mjs /wrapper/template/bootstrap-ceo.mjs

# Agent CLIs — installed globally so SSH user can use them too. The CREDENTIALS
# (~/.claude, ~/.codex, ~/.config/opencode) are symlinked to /paperclip volume
# at runtime, so a single OAuth login is shared between the SSH user and
# Paperclip's internal agents.
RUN npm install --global --omit=dev \
       @anthropic-ai/claude-code@latest \
       @openai/codex@latest \
       opencode-ai \
    && npm install --global --omit=dev tsx \
    && npm cache clean --force

# Railway CLI for the SSH user (handy for poking at the deployment from inside)
RUN npm install --global --omit=dev @railway/cli && npm cache clean --force

# Create /paperclip and ensure node owns it
RUN mkdir -p /paperclip \
    && chown -R node:node /app /paperclip /wrapper

# Copy s6 service definitions, sshd config, and init scripts
COPY rootfs /
RUN chmod +x /usr/local/bin/*.sh \
    && chmod +x /etc/s6-overlay/s6-rc.d/init-ssh/up \
    && chmod +x /etc/s6-overlay/s6-rc.d/init-credentials/up \
    && chmod +x /etc/s6-overlay/s6-rc.d/paperclip/run \
    && chmod +x /etc/s6-overlay/s6-rc.d/sshd/run

# 22 = SSH, 3100 = Paperclip web
EXPOSE 22 3100

# s6-overlay takes PID 1 and supervises both processes
ENTRYPOINT ["/init"]
