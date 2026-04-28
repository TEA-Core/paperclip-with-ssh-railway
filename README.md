# Paperclip + SSH Railway Template

A merge of [Lukem121/paperclip-railway-template](https://github.com/Lukem121/paperclip-railway-template) and [sCOSTAkg/claude-code-railway](https://github.com/sCOSTAkg/claude-code-railway).

You get:

- **Paperclip** running at `https://<your-domain>` (web UI + setup page).
- **OpenSSH** on a Railway TCP proxy — log in as your own user, with `claude` / `codex` / `opencode` / `gh` / `railway` already on `$PATH`.
- **Shared OAuth**: a single `claude` / `codex` / `opencode` login covers both Paperclip's internal agents *and* your interactive SSH shell. Credentials live on the `/paperclip` volume so they survive redeploys.
- **Key-only SSH** (no passwords). You set `AUTHORIZED_KEYS` at deploy time.

## Architecture

One container, two long-running processes, supervised by [s6-overlay](https://github.com/just-containers/s6-overlay):

```
┌─ container ─────────────────────────────────────────────────┐
│  /init  (s6-overlay PID 1)                                  │
│   ├─ init-credentials  (oneshot) → set up /paperclip/shared │
│   ├─ init-ssh          (oneshot) → create SSH user, keys    │
│   ├─ paperclip         (longrun) → node /wrapper/src/server │
│   │                                  (runs as `node` user)  │
│   └─ sshd              (longrun) → /usr/sbin/sshd -D        │
└─────────────────────────────────────────────────────────────┘

/paperclip               ← Railway volume
├── instances/default/   ← Paperclip app data
├── home/<ssh-user>/     ← your SSH home dir (persists)
└── shared-creds/        ← shared agent OAuth tokens
    ├── claude/          ← ~/.claude (both users)
    ├── codex/           ← ~/.codex (both users)
    ├── opencode/        ← ~/.config/opencode (both users)
    └── gh/              ← GitHub CLI
```

The `node` user (which Paperclip's agents run as) has `HOME=/paperclip`, so its `~/.claude` is `/paperclip/.claude`. The SSH user's `~/.claude` is symlinked into the same `/paperclip/shared-creds/claude` directory. One `claude /login`, two users authenticated.

## Deploy

1. Push this repo to GitHub.
2. Create a new Railway project from the GitHub repo, alongside a Postgres service.
3. On the **Paperclip** service:
   - Add a **volume** mounted at `/paperclip` (recommended: 5+ GB).
   - Enable **HTTP proxy** on port **3100**, healthcheck path **`/setup/healthz`**.
   - Enable a **TCP proxy** on port **22** (this gives you a `tcp.railway.app:<random-port>` SSH endpoint).
   - Set the variables from `.env.example` (most important: `AUTHORIZED_KEYS`).

## Variables

See `.env.example` for the full list. The new ones (vs. upstream Paperclip template):

| Variable | Required | Purpose |
|---|---|---|
| `AUTHORIZED_KEYS` | **yes** | Your SSH public key(s), newline-separated. Without this, sshd starts but no one can log in. |
| `SSH_USERNAME` | no | Defaults to `dev`. Username you'll `ssh dev@…` as. |

## First-time login

Once deployed, find your TCP proxy domain + port in Railway (Service → Settings → Networking).

```bash
ssh dev@tcp.railway.app -p <PORT>
```

You'll land in `~/dev`. Try:

```bash
claude --version
codex --version
opencode --version
railway whoami
```

## Authenticating Claude / Codex / OpenCode (the shared OAuth)

Run the login from your SSH session **once**:

```bash
claude /login        # opens an OAuth URL — paste it into a browser
codex login          # similar
opencode auth login  # similar
```

The credentials get written to `/paperclip/shared-creds/{claude,codex,opencode}/`, which is symlinked from both the SSH user's home dir and the `node` user's home dir. After this, Paperclip's internal agents can also use those credentials — no separate setup, no API key needed.

> ⚠️ **Claude Max caveat**: running `claude` on a remote 24/7 server using your Max subscription is technically outside Anthropic's intended use case for the Max plan. People do it; Anthropic could in theory rate-limit or warn the account. If you'd rather stay on the sanctioned path, set `ANTHROPIC_API_KEY` (Console API key) and Paperclip will use that instead — but the SSH user's `claude` invocations will still use whatever you logged in with via OAuth.

## Persistence

Anything that needs to survive redeploys lives under `/paperclip`:

- Paperclip app data (`/paperclip/instances/...`)
- Your SSH user's home directory (`/paperclip/home/<user>/`)
- All agent CLI credentials (`/paperclip/shared-creds/`)
- Anything you save under `~/dev` while SSH'd in

The rest of the container filesystem is wiped on every redeploy. Don't `apt-get install` things and expect them to stick — use the volume.

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| 3100 | HTTP | Paperclip web + `/setup` UI |
| 22 | TCP | SSH |

## Updating

To bump the upstream Paperclip version, set `PAPERCLIP_REF` as a build-time variable and redeploy. See the upstream README for details.

## Troubleshooting

**SSH connects but immediately drops** — check `AUTHORIZED_KEYS` is set (key-only auth means no key = no login). Tail the Paperclip service logs in Railway and look for `[ssh-user-init]` messages.

**Paperclip agents don't pick up Claude OAuth** — verify the symlinks:

```bash
ssh dev@... -p ... 'ls -la ~/.claude && sudo ls -la /paperclip/.claude'
```

Both should point to `/paperclip/shared-creds/claude`.

**Healthcheck fails** — Paperclip needs `BETTER_AUTH_SECRET` (32+ chars), `DATABASE_URL`, and the volume. Check `railway logs --service Paperclip` for the actual error.

## Credits

- Paperclip: [paperclipai/paperclip](https://github.com/paperclipai/paperclip)
- Original Railway template: [Lukem121/paperclip-railway-template](https://github.com/Lukem121/paperclip-railway-template)
- SSH-on-Railway pattern: [sCOSTAkg/claude-code-railway](https://github.com/sCOSTAkg/claude-code-railway)
