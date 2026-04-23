#!/usr/bin/env bash
# pi config installer — idempotent
# Default:  installs Node.js Current via fnm (https://github.com/Schniz/fnm) — clean, no apt bloat
# Opt-in:   PI_RUNTIME=bun bash -c "..."  — uses Bun instead of Node
#
# If run interactively (TTY), prompts for Node vs Bun; otherwise defaults to Node.
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/mosaicws/pi/main/install.sh)"
set -euo pipefail

REPO_URL="${PI_CONFIG_REPO:-https://github.com/mosaicws/pi.git}"
CONFIG_DIR="${PI_CONFIG_DIR:-$HOME/pi-config}"
PI_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
PI_RUNTIME="${PI_RUNTIME:-auto}"   # auto | node | bun
NODE_MIN_MAJOR=25
FNM_DIR="${FNM_DIR:-/usr/local/fnm}"

log()  { printf '\033[1;34m[pi-config]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pi-config]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pi-config]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Privilege detection ---
is_root() { [ "$(id -u)" = "0" ]; }
SUDO=""
if ! is_root; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"
  else warn "Not running as root and no sudo found — installs will fail"; fi
fi

# --- Prerequisites ---
for bin in git curl; do
  command -v "$bin" >/dev/null 2>&1 || die "Missing dependency: $bin (install with: apt install -y $bin)"
done

# --- Clean up broken NodeSource repo left by earlier runs (Debian 13 sqv issue) ---
cleanup_stale_nodesource() {
  local ns_list="/etc/apt/sources.list.d/nodesource.list"
  local ns_key="/etc/apt/keyrings/nodesource.gpg"
  [ -f "$ns_list" ] || [ -f "$ns_key" ] || return 0
  log "Found leftover NodeSource repo, checking..."
  local apt_out
  apt_out=$($SUDO apt-get update 2>&1 || true)
  if echo "$apt_out" | grep -qE "(Failed to fetch|Err:|error|Warning).*nodesource|nodesource.*(sqv|SHA1|Signing key)"; then
    warn "NodeSource apt source is failing (Debian 13 sqv policy). Removing..."
    $SUDO rm -f "$ns_list" "$ns_key"
    $SUDO apt-get update -qq
  fi
}

# --- Node presence check ---
node_version_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local major
  major=$(node -v 2>/dev/null | sed 's/^v\([0-9]\+\).*/\1/')
  [ -n "$major" ] && [ "$major" -ge "$NODE_MIN_MAJOR" ]
}

# --- fnm install: binary to /usr/local/bin ---
install_fnm_binary() {
  if command -v fnm >/dev/null 2>&1; then
    log "fnm already installed: $(fnm --version)"
    return
  fi
  local fnm_arch
  case "$(uname -m)" in
    x86_64)          fnm_arch="linux" ;;
    aarch64|arm64)   fnm_arch="arm64" ;;
    *) die "Unsupported architecture: $(uname -m) (fnm supports x86_64 and arm64)" ;;
  esac
  log "Installing fnm ($fnm_arch) to /usr/local/bin/fnm..."
  command -v unzip >/dev/null 2>&1 || { log "Installing unzip..."; $SUDO apt-get install -y unzip; }
  local tmp; tmp=$(mktemp -d)
  curl -fsSL "https://github.com/Schniz/fnm/releases/latest/download/fnm-${fnm_arch}.zip" -o "$tmp/fnm.zip"
  unzip -q "$tmp/fnm.zip" -d "$tmp"
  $SUDO install -m 755 "$tmp/fnm" /usr/local/bin/fnm
  rm -rf "$tmp"
  log "Installed fnm $(fnm --version)"
}

# --- Node install via fnm, symlinks to /usr/local/bin for system-wide PATH ---
install_node_via_fnm() {
  install_fnm_binary
  $SUDO mkdir -p "$FNM_DIR"
  log "Installing latest Node.js Current via fnm into $FNM_DIR..."
  $SUDO env FNM_DIR="$FNM_DIR" fnm install latest

  # Determine which version was just installed (pick the highest via sort -V)
  local installed
  installed=$($SUDO env FNM_DIR="$FNM_DIR" fnm list 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
  [ -n "$installed" ] || die "Could not determine installed Node version from 'fnm list'"

  log "Setting fnm default alias -> $installed"
  $SUDO env FNM_DIR="$FNM_DIR" fnm alias default "$installed"

  # fnm's 'default' alias is a symlink to the installation root; bin/ is inside
  local default_bin="$FNM_DIR/aliases/default/bin"
  [ -d "$default_bin" ] || die "fnm default alias missing: $default_bin"

  # System-wide symlinks so node/npm/npx work without shell init
  for bin in node npm npx corepack; do
    [ -e "$default_bin/$bin" ] && $SUDO ln -sfn "$default_bin/$bin" "/usr/local/bin/$bin"
  done

  node_version_ok || die "fnm installed Node but version check still fails"
  log "Installed Node $(node -v), npm $(npm -v) via fnm"
}

# --- Bun ---
install_bun() {
  if command -v bun >/dev/null 2>&1; then
    log "Bun already installed: $(bun -v)"
    return
  fi
  command -v unzip >/dev/null 2>&1 || { log "Installing unzip..."; $SUDO apt-get install -y unzip; }
  log "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  command -v bun >/dev/null 2>&1 || die "Bun install finished but 'bun' not on PATH"
  log "Installed Bun $(bun -v)"
}

# --- Interactive runtime prompt when stdin is a TTY and no explicit PI_RUNTIME ---
if [ "$PI_RUNTIME" = "auto" ] && [ -t 0 ]; then
  printf '\n'
  printf 'Select JavaScript runtime for pi:\n'
  printf '  [n] Node.js (default) — recommended, full extension support\n'
  printf '  [b] Bun — experimental, some pi extensions may misbehave\n'
  read -r -p "Choice [N/b]: " _rt_choice || _rt_choice=""
  case "${_rt_choice,,}" in
    b|bun) PI_RUNTIME=bun ;;
    *)     PI_RUNTIME=node ;;
  esac
fi
# Non-TTY fallback: default auto -> node
[ "$PI_RUNTIME" = "auto" ] && PI_RUNTIME=node

# --- Runtime selection ---
case "$PI_RUNTIME" in
  node)
    cleanup_stale_nodesource
    if node_version_ok; then log "Using existing Node $(node -v)"
    else install_node_via_fnm; fi
    ;;
  bun)
    install_bun
    ;;
  *) die "PI_RUNTIME must be 'node' or 'bun' (got: $PI_RUNTIME)" ;;
esac

# --- Install pi ---
if command -v pi >/dev/null 2>&1; then
  log "pi already installed: $(pi --version 2>/dev/null || echo '?')"
else
  case "$PI_RUNTIME" in
    node)
      log "Installing pi via npm..."
      # When Node came from fnm (owned by root), npm -g writes into the fnm tree — sudo works cleanly
      $SUDO env PATH="$PATH" npm install -g @mariozechner/pi-coding-agent
      ;;
    bun)
      log "Installing pi via Bun (experimental)..."
      bun install -g @mariozechner/pi-coding-agent
      ;;
  esac
fi

# If pi was installed inside fnm's tree, the shim isn't on PATH — symlink it
if [ "$PI_RUNTIME" = "node" ] && [ ! -e /usr/local/bin/pi ]; then
  pi_path="$FNM_DIR/aliases/default/bin/pi"
  if [ -e "$pi_path" ]; then
    $SUDO ln -sfn "$pi_path" /usr/local/bin/pi
    log "Linked /usr/local/bin/pi -> $pi_path"
  fi
fi

# --- Clone or update the config repo ---
if [ -d "$CONFIG_DIR/.git" ]; then
  log "Updating $CONFIG_DIR"
  git -C "$CONFIG_DIR" pull --ff-only
elif [ -d "$CONFIG_DIR" ]; then
  bak="$CONFIG_DIR.bak.$(date +%s)"
  warn "$CONFIG_DIR exists but isn't a git repo — moving to $bak"
  mv "$CONFIG_DIR" "$bak"
  log "Cloning $REPO_URL into $CONFIG_DIR"
  git clone "$REPO_URL" "$CONFIG_DIR"
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
