# pi

Shared [pi coding agent](https://github.com/badlogic/pi-mono) configuration for a Proxmox host, LXC containers, and workstations. One `models.json`, one source of truth.

The installer bootstraps Node.js (latest Current release) via [`fnm`](https://github.com/Schniz/fnm) — single Rust binary, ~5 MB, zero apt bloat. If run interactively it prompts to choose between Node and Bun. Then it installs pi globally, clones this repo to `~/pi-config`, and symlinks the config into `~/.pi/agent/`. Fully idempotent — re-run any time to update config, heal a broken NodeSource repo from a prior attempt, or add missing symlinks.

## Installation — inside a fresh Debian/Ubuntu LXC

### Quick Install (recommended — always fetches latest)

```bash
sudo apt update && sudo apt install -y curl git ca-certificates && \
  t=$(mktemp -d) && git clone --depth 1 https://github.com/mosaicws/pi.git "$t" && bash "$t/install.sh"; rm -rf "$t"
```

`git clone --depth 1` pulls the latest `main` directly from Git — bypassing `raw.githubusercontent.com` entirely. That's the only approach that's fully immune to GitHub's raw-hosting cache, which can serve stale content for 30–60 seconds after a push (the query-string `?v=` buster invalidates Fastly's edge but not the origin propagation delay).

### Quick Install (curl one-shot, may lag briefly after a push)

```bash
bash -c "$(curl -fsSL "https://raw.githubusercontent.com/mosaicws/pi/main/install.sh?v=$(date +%s)")"
```

One-liner alternative if you don't want `git` in the bootstrap. The `?v=$(date +%s)` query string busts Fastly's CDN edge cache; if you run this within ~60 s of pushing to `main`, you may still get the previous version.

### Review First (Recommended for untrusted sources)

```bash
sudo apt update && sudo apt install -y curl git ca-certificates
git clone --depth 1 https://github.com/mosaicws/pi.git /tmp/pi-install
less /tmp/pi-install/install.sh
bash /tmp/pi-install/install.sh
```

### Use Bun instead of Node (experimental)

pi is published to npm and `bun install -g` works, but Bun's Node-API coverage isn't complete — some pi extensions may misbehave. Core CLI works.

```bash
sudo apt update && sudo apt install -y curl git ca-certificates unzip && \
  t=$(mktemp -d) && git clone --depth 1 https://github.com/mosaicws/pi.git "$t" && PI_RUNTIME=bun bash "$t/install.sh"; rm -rf "$t"
```

## Environment variables

| Var | Default | Effect |
|---|---|---|
| `PI_RUNTIME` | `auto` | `auto` = prompt interactively (or default to node if no TTY). `node` = use existing Node ≥25 if present, else install latest Current via fnm. `bun` = install Bun and use it instead of Node. |
| `FNM_DIR` | `/usr/local/fnm` | Where fnm stores its Node versions |
| `PI_CONFIG_REPO` | this repo | Override the config repo URL |
| `PI_CONFIG_DIR` | `~/pi-config` | Where to clone the repo |
| `PI_AGENT_DIR` | `~/.pi/agent` | Where pi looks for its config |

## What gets linked

| From repo | To pi |
|---|---|
| `models.json` | `~/.pi/agent/models.json` |
| `settings.json` *(if present)* | `~/.pi/agent/settings.json` |
| `AGENTS.md` *(if present)* | `~/.pi/agent/AGENTS.md` |
| `prompts/` *(if present)* | `~/.pi/agent/prompts` |
| `skills/` *(if present)* | `~/.pi/agent/skills` |

Any existing non-symlink file is backed up to `<file>.bak.<timestamp>` before being replaced.

## Secrets — never in this repo

API keys live in `~/.pi/agent/auth.json` on each host (`0600`). See [`auth.json.example`](./auth.json.example) for the format.

The installer creates an empty `auth.json` on first run. Add your keys per host after install.

## Updating config across hosts

Edit locally, commit, push. Then on each host:

```bash
~/pi-config/install.sh      # or: git -C ~/pi-config pull
```

Re-running the installer is idempotent:
- Skips Node/pi installation if already current
- Auto-detects and removes a broken NodeSource repo (Debian 13 `sqv` signing issue)
- Backs up any pre-existing non-symlink `models.json` (or `~/pi-config` directory) before replacing
- Never touches your `auth.json`

Cron `git -C ~/pi-config pull --ff-only` hourly for hands-free updates.

## Notes

- `baseUrl` entries currently use the static LAN IP `192.168.0.10`. Replace with a hostname if you prefer (`http://llm.lan:1234/v1`) — add via router DNS or mDNS.
- Bundled providers (`lm-studio`, `llama-swap`) are plain-HTTP LAN services; their `apiKey` values are placeholders, not real secrets.
- **Windows hosts**: the installer is Linux-only. Clone manually, then either `mklink /J` a junction or schedule a periodic `git pull`.
- **Non-root**: the script invokes `sudo` for apt steps if available. Fresh LXC as root needs no sudo.
