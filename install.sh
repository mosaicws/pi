#!/usr/bin/env bash
# pi config installer — idempotent
# Default:  installs Node.js LTS via NodeSource (if needed), then pi via npm
# Opt-in:   PI_RUNTIME=bun bash -c "..."  — uses Bun instead of Node
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/mosaicws/pi/main/install.sh)"
set -euo pipefail

REPO_URL="${PI_CONFIG_REPO:-https://github.com/mosaicws/pi.git}"
CONFIG_DIR="${PI_CONFIG_DIR:-$HOME/pi-config}"
PI_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
PI_RUNTIME="${PI_RUNTIME:-auto}"   # auto | node | bun
NODE_MIN_MAJOR=20

log()  { printf '\033[1;34m[pi-config]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pi-config]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pi-config]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Require root on Debian/Ubuntu paths that use apt ---
is_root() { [ "$(id -u)" = "0" ]; }
SUDO=""
if ! is_root; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"
  else warn "Not running as root and no sudo found — apt-based installs will fail"; fi
fi

# --- Prerequisites ---
for bin in git curl; do
  command -v "$bin" >/dev/null 2>&1 || die "Missing dependency: $bin (install with: apt install -y $bin)"
done

# --- Runtime selection ---
node_version_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local major
  major=$(node -v 2>/dev/null | sed 's/^v\([0-9]\+\).*/\1/')
  [ -n "$major" ] && [ "$major" -ge "$NODE_MIN_MAJOR" ]
}

install_node_via_nodesource() {
  log "Installing Node.js LTS via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
  $SUDO apt install -y nodejs
  log "Installed Node $(node -v), npm $(npm -v)"
}

install_bun() {
  if command -v bun >/dev/null 2>&1; then
    log "Bun already installed: $(bun -v)"
    return
  fi
  command -v unzip >/dev/null 2>&1 || { log "Installing unzip (required by Bun installer)"; $SUDO apt install -y unzip; }
  log "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  command -v bun >/dev/null 2>&1 || die "Bun install finished but 'bun' not on PATH"
  log "Installed Bun $(bun -v)"
}

case "$PI_RUNTIME" in
  auto)
    if node_version_ok; then
      log "Using existing Node $(node -v)"
      PI_RUNTIME=node
    else
      install_node_via_nodesource
      PI_RUNTIME=node
    fi
    ;;
  node)
    if node_version_ok; then log "Using existing Node $(node -v)"
    else install_node_via_nodesource; fi
    ;;
  bun)
    install_bun
    ;;
  *) die "PI_RUNTIME must be 'auto', 'node', or 'bun' (got: $PI_RUNTIME)" ;;
esac

# --- Install pi ---
if command -v pi >/dev/null 2>&1; then
  log "pi already installed: $(pi --version 2>/dev/null || echo '?')"
else
  case "$PI_RUNTIME" in
    node) log "Installing pi via npm...";  npm install -g @mariozechner/pi-coding-agent ;;
    bun)  log "Installing pi via Bun (experimental)..."; bun install -g @mariozechner/pi-coding-agent ;;
  esac
fi

# --- Clone or update the config repo ---
if [ -d "$CONFIG_DIR/.git" ]; then
  log "Updating $CONFIG_DIR"
  git -C "$CONFIG_DIR" pull --ff-only
else
  log "Cloning $REPO_URL into $CONFIG_DIR"
  git clone "$REPO_URL" "$CONFIG_DIR"
fi

# --- Link config files into pi's agent directory ---
mkdir -p "$PI_DIR"

link_if_exists() {
  local src="$1" dst="$2"
  [ -e "$src" ] || return 0
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    local bak="$dst.bak.$(date +%s)"
    warn "Backing up existing $dst to $bak"
    mv "$dst" "$bak"
  fi
  ln -sfn "$src" "$dst"
  log "Linked $dst -> $src"
}

link_if_exists "$CONFIG_DIR/models.json"   "$PI_DIR/models.json"
link_if_exists "$CONFIG_DIR/settings.json" "$PI_DIR/settings.json"
link_if_exists "$CONFIG_DIR/AGENTS.md"     "$PI_DIR/AGENTS.md"
link_if_exists "$CONFIG_DIR/prompts"       "$PI_DIR/prompts"
link_if_exists "$CONFIG_DIR/skills"        "$PI_DIR/skills"

# --- Ensure auth.json exists (empty, 0600) ---
if [ ! -f "$PI_DIR/auth.json" ]; then
  printf '{}\n' > "$PI_DIR/auth.json"
  chmod 600 "$PI_DIR/auth.json"
  log "Created empty $PI_DIR/auth.json (0600)"
fi

printf '\n'
log "Done. Runtime: $PI_RUNTIME"
log "Add API keys to $PI_DIR/auth.json (see $CONFIG_DIR/auth.json.example)."
log "Update later: re-run this script, or: git -C $CONFIG_DIR pull"
if [ "$PI_RUNTIME" = "bun" ]; then
  log "NOTE: Bun PATH may not be active in your shell. Run: source ~/.bashrc (or restart shell)"
fi
