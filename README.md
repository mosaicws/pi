# pi config

Shared configuration for [pi coding agent](https://github.com/badlogic/pi-mono) across a Proxmox host, LXC containers, and workstations. One `models.json`, one place to update.

## One-liner install (Debian/Ubuntu, fresh host)

The installer bootstraps a current Node.js for you (via NodeSource), installs pi globally, clones this repo, and symlinks the config into `~/.pi/agent/`. Safe to re-run.

```bash
apt update && apt install -y curl git ca-certificates \
  && bash -c "$(curl -fsSL https://raw.githubusercontent.com/mosaicws/pi/main/install.sh)"
```

### With Bun instead of Node (experimental)

pi is published to npm and `bun install -g` works, but Bun's Node-API coverage isn't complete — some pi extensions may misbehave. For the core CLI it works.

```bash
apt update && apt install -y curl git ca-certificates unzip \
  && PI_RUNTIME=bun bash -c "$(curl -fsSL https://raw.githubusercontent.com/mosaicws/pi/main/install.sh)"
```

### Environment variables

| Var | Default | Effect |
|---|---|---|
| `PI_RUNTIME` | `auto` | `auto` (use existing Node ≥20 or install NodeSource), `node` (force NodeSource path), `bun` (install Bun) |
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

API keys live in `~/.pi/agent/auth.json` on each host (`0600` permissions). See [`auth.json.example`](./auth.json.example) for the format.

The install script creates an empty `auth.json` on first run. Add your keys per host after install.

## Updating config across all hosts

Edit `models.json` (or any other file) locally, commit + push. Then on each host:

```bash
~/pi-config/install.sh      # or: git -C ~/pi-config pull
```

Re-running the script is idempotent — it pulls the repo and re-applies symlinks. No dependency reinstall if Node/pi are already current.

Cron an hourly `git -C ~/pi-config pull --ff-only` if you want it hands-free.

## Notes

- `baseUrl` entries currently use a static LAN IP (`192.168.0.10`). You can replace with a hostname (e.g. `http://llm.lan:1234/v1`) if you prefer — via router DNS or mDNS.
- Providers listed here (`lm-studio`, `llama-swap`) are plain-HTTP LAN services, so their `apiKey` values are placeholders — not real secrets.
- **Windows hosts**: the installer is Linux-only. On Windows, clone manually and either use `mklink /J` to junction `%USERPROFILE%\.pi\agent\models.json` onto the clone, or schedule a periodic `git pull`.
- **Running as non-root**: the script will call `sudo` for apt steps if it's available. For a fresh LXC running as root, no sudo is needed.
