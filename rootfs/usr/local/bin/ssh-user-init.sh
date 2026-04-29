#!/bin/bash
# Provision the SSH user with key-based auth, persist its home dir on the
# /paperclip volume, and symlink agent CLI credentials into the shared location
# so the SSH user shares its OAuth with Paperclip's `node` user.
set -eu

: "${SSH_USERNAME:=dev}"
: "${AUTHORIZED_KEYS:=}"

# DIAGNOSTIC v3: log everything we can about the env situation so we can see
# what's actually present in the running container.
echo "[ssh-user-init] DIAG v3: AUTHORIZED_KEYS direct length=${#AUTHORIZED_KEYS}"
echo "[ssh-user-init] DIAG v3: /proc/1/environ readable: $([ -r /proc/1/environ ] && echo YES || echo NO)"
if [ -r /proc/1/environ ]; then
    echo "[ssh-user-init] DIAG v3: env var names in /proc/1/environ:"
    tr '\0' '\n' < /proc/1/environ | sed 's/=.*$//' | sort | sed 's/^/[ssh-user-init] DIAG v3:   /'
fi

# s6-overlay's with-contenv strips multi-line environment variables when it
# materializes them under /var/run/s6/container_environment. Multi-line values
# (like multiple SSH keys joined by newlines) get truncated or dropped. As a
# workaround, fall back to reading directly from PID 1's /proc/1/environ, which
# preserves the original container env intact.
if [ -z "$AUTHORIZED_KEYS" ] && [ -r /proc/1/environ ]; then
    AUTHORIZED_KEYS=$(awk -v RS='\0' -F= '/^AUTHORIZED_KEYS=/{ sub(/^AUTHORIZED_KEYS=/, ""); print }' /proc/1/environ)
    echo "[ssh-user-init] DIAG v3: after /proc fallback, AUTHORIZED_KEYS length=${#AUTHORIZED_KEYS}"
fi

if [ -z "$AUTHORIZED_KEYS" ]; then
    echo "[ssh-user-init] ERROR: AUTHORIZED_KEYS env var is required (key-only auth)." >&2
    echo "[ssh-user-init] Set AUTHORIZED_KEYS to one or more SSH public keys (newline-separated)." >&2
    # Don't exit — let sshd start anyway so the deploy doesn't fail. Just no one can log in.
    exit 0
fi

SHARED=/paperclip/shared-creds
PERSIST_HOME="/paperclip/home/${SSH_USERNAME}"

# Create the user if it doesn't exist. Home dir lives on the /paperclip volume.
if ! id "$SSH_USERNAME" &>/dev/null; then
    mkdir -p "/paperclip/home"
    useradd \
        --create-home \
        --home-dir "$PERSIST_HOME" \
        --shell /bin/bash \
        --groups sudo \
        "$SSH_USERNAME"
    # Disable password — key-only.
    passwd -l "$SSH_USERNAME" >/dev/null
    # Passwordless sudo (it's their box). Comment out the next line if you want
    # sudo to require nothing at all is too loose for your taste.
    echo "${SSH_USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${SSH_USERNAME}"
    chmod 440 "/etc/sudoers.d/90-${SSH_USERNAME}"
    echo "[ssh-user-init] Created user ${SSH_USERNAME} with home ${PERSIST_HOME}"
else
    # Make sure home dir still points where we expect (volume could've been
    # detached/reattached).
    usermod --home "$PERSIST_HOME" "$SSH_USERNAME" 2>/dev/null || true
fi

# Make sure the home dir exists and is owned correctly (volume may be empty
# on first mount).
mkdir -p "$PERSIST_HOME/.ssh" "$PERSIST_HOME/dev" "$PERSIST_HOME/.config"
chown -R "${SSH_USERNAME}:${SSH_USERNAME}" "$PERSIST_HOME"
chmod 700 "$PERSIST_HOME/.ssh"

# Authorized keys
echo "$AUTHORIZED_KEYS" > "$PERSIST_HOME/.ssh/authorized_keys"
chown "${SSH_USERNAME}:${SSH_USERNAME}" "$PERSIST_HOME/.ssh/authorized_keys"
chmod 600 "$PERSIST_HOME/.ssh/authorized_keys"

# Add SSH user to the `node` group so it can read shared creds
usermod -aG node "$SSH_USERNAME" 2>/dev/null || true
chmod 750 "$SHARED" || true
chmod -R g+rX "$SHARED" || true

# Symlink agent credential dirs in SSH user's home → shared location.
# This is what makes ONE OAuth login cover both Paperclip's agents and the
# SSH user's interactive `claude` / `codex` / `opencode` invocations.
link_shared() {
    local user_path="$1"
    local shared_path="$2"
    if [ -e "$user_path" ] && [ ! -L "$user_path" ]; then
        rm -rf "$user_path"
    fi
    if [ -L "$user_path" ]; then
        rm -f "$user_path"
    fi
    sudo -u "$SSH_USERNAME" ln -s "$shared_path" "$user_path"
}

link_shared "$PERSIST_HOME/.claude"           "$SHARED/claude"
link_shared "$PERSIST_HOME/.codex"            "$SHARED/codex"
link_shared "$PERSIST_HOME/.config/opencode"  "$SHARED/opencode"
link_shared "$PERSIST_HOME/.config/gh"        "$SHARED/gh"

# Friendly bashrc additions (idempotent)
RC="$PERSIST_HOME/.bashrc"
touch "$RC"
chown "${SSH_USERNAME}:${SSH_USERNAME}" "$RC"
if ! grep -q "PAPERCLIP_SSH_INIT" "$RC"; then
    cat >> "$RC" <<'EOF'

# --- PAPERCLIP_SSH_INIT (managed by ssh-user-init.sh) ---
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
# Agent CLI credential dirs are symlinked to /paperclip/shared-creds so OAuth
# is shared with Paperclip's internal agents. Don't move these symlinks.
cd "$HOME/dev" 2>/dev/null || true
# --- end PAPERCLIP_SSH_INIT ---
EOF
fi

# Generate host keys if they don't exist (first boot)
ssh-keygen -A >/dev/null 2>&1 || true

echo "[ssh-user-init] User ${SSH_USERNAME} ready. Home: ${PERSIST_HOME}"
echo "[ssh-user-init] Agent CLI credentials shared at ${SHARED}"
