#!/bin/bash
# Persist agent CLI credentials on the /paperclip volume so they survive
# redeploys, AND share them between the SSH user and the `node` user (which
# Paperclip's internal agents run as).
#
# Strategy: credentials live in /paperclip/shared-creds. Each agent CLI
# directory in BOTH home dirs (~node and the SSH user's) is a symlink into
# that shared location. One OAuth login covers everything.
set -eu

# Railway mounts the volume at /paperclip as root-owned by default. The
# upstream Paperclip template's entrypoint chowned the entire /paperclip tree
# to node:node before starting the app — we must do the same here, otherwise
# Paperclip crashes with EACCES trying to mkdir /paperclip/instances/...
mkdir -p /paperclip/instances/default/logs
chown -R node:node /paperclip

SHARED=/paperclip/shared-creds
mkdir -p "$SHARED/claude" "$SHARED/codex" "$SHARED/opencode" "$SHARED/gh" "$SHARED/git"

# Make sure node can read/write the shared dir specifically.
chown -R node:node "$SHARED"
chmod 750 "$SHARED"

# Helper: replace a target dir with a symlink to the shared location, but
# preserve any existing data on first run by moving it over.
relink() {
    local target="$1"  # e.g. /paperclip/.claude
    local source="$2"  # e.g. /paperclip/shared-creds/claude
    local owner="$3"   # e.g. node:node

    # If target is already the right symlink, do nothing
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
        return 0
    fi

    # If target exists and isn't a symlink, migrate its contents into source
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        # Only migrate if the shared source is empty
        if [ -z "$(ls -A "$source" 2>/dev/null)" ]; then
            cp -a "$target/." "$source/" 2>/dev/null || true
        fi
        rm -rf "$target"
    fi

    # If it's a wrong symlink, remove it
    if [ -L "$target" ]; then
        rm -f "$target"
    fi

    ln -s "$source" "$target"
    chown -h "$owner" "$target"
}

# Set up node user (Paperclip's process user). HOME=/paperclip per Dockerfile.
relink /paperclip/.claude          "$SHARED/claude"   node:node
relink /paperclip/.codex           "$SHARED/codex"    node:node
mkdir -p /paperclip/.config && chown node:node /paperclip/.config
relink /paperclip/.config/opencode "$SHARED/opencode" node:node
relink /paperclip/.config/gh       "$SHARED/gh"       node:node
relink /paperclip/.gitconfig-shared "$SHARED/git/gitconfig" node:node 2>/dev/null || true

echo "[persist-credentials] shared credential directories ready at $SHARED"
