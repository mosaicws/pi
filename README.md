# pi

Shared [pi coding agent](https://github.com/badlogic/pi-mono) configuration for a Proxmox host, LXC containers, and workstations. One `models.json`, one source of truth.

The installer bootstraps Node.js (latest Current release) via [`fnm`](https://github.com/Schniz/fnm) — single Rust binary, ~5 MB, zero apt bloat. If run interactively it prompts to choose between Node and Bun. Then it installs pi globally, clones this repo to `~/pi-config`, and symlinks the config into `~/.pi/agent/`. Fully idempotent — re-run any time to update config, heal a broken NodeSource repo from a prior attempt, or add missing symlinks.

## Installation — inside a fresh Debian/Ubuntu LXC

### Quick Install

```bash
sudo apt update && sudo apt install -y curl git ca-certificates && bash -c "$(curl -fsSL https://raw.githubusercontent.com/mosaicws/pi/main/install.sh)"
```

This single command installs the three apt prereqs and runs the installer. Works on fresh Debian 13 / Ubuntu. Drop the `sudo` if you're already root.

### Review First (Recommended)

```bash
sudo apt update && sudo apt install -y curl git ca-certificates
curl -fsSL https://raw.githubusercontent.com/mosaicws/pi/main/install.sh -o install.sh
less install.sh
bash install.sh
```

### Use Bun instead of Node (experimental)

pi is published to npm and `bun install -g` works, but Bun's Node-API coverage isn't complete — some pi extensions may misbehave. Core CLI works.

```bash
sudo apt update && sudo apt install -y curl git ca-certificates unzip && PI_RUNTIME=bun bash -c "$(curl -fsSL https://raw.githubusercontent.com/mosaicws/pi/main/install.sh)"
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
