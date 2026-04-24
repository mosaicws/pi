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

# --- Colours (respects NO_COLOR, disabled when stdout isn't a TTY) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_BLUE=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

log()  { printf '%s[pi]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[pi]%s %s%s%s\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s[pi]%s %s%s%s\n' "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '%s[pi]%s %s%s%s\n' "$C_RED" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
step() { printf '\n%s━━ %s%s %s━━%s\n' "$C_CYAN" "$C_BOLD" "$*" "$C_CYAN" "$C_RESET"; }

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

# --- Runtime deps for Node's prebuilt binaries ---
ensure_libatomic1() {
  # Node's nodejs.org tarball links against libatomic.so.1, which is missing
  # from minimal Debian/Ubuntu images (LXC templates, cloud-init minbase).
  # Without it: "node: error while loading shared libraries: libatomic.so.1".
  # dpkg -s is authoritative; ldconfig -p isn't on non-root PATH everywhere.
  command -v dpkg >/dev/null 2>&1 || return 0
  dpkg -s libatomic1 >/dev/null 2>&1 && return 0
  log "Installing libatomic1 (required by Node prebuilt binaries)..."
  $SUDO apt-get install -y libatomic1
}

# --- Remove fnm-managed Node versions that aren't the current default ---
cleanup_stale_node_versions() {
  local keep="$1"
  [ -n "$keep" ] || return 0
  local dir removed=0
  for dir in "$FNM_DIR"/node-versions/v*; do
    [ -d "$dir" ] || continue
    local ver="${dir##*/}"
    [ "$ver" = "$keep" ] && continue
    log "Removing stale Node $ver"
    $SUDO env FNM_DIR="$FNM_DIR" fnm uninstall "$ver" >/dev/null 2>&1 || \
      $SUDO rm -rf "$dir"
    removed=$((removed + 1))
  done
  [ "$removed" -eq 0 ] || log "Cleaned up $removed stale Node version(s)"
}

# --- Node install via fnm, symlinks to /usr/local/bin for system-wide PATH ---
install_node_via_fnm() {
  install_fnm_binary
  $SUDO mkdir -p "$FNM_DIR"
  ensure_libatomic1

  log "Installing latest Node.js Current via fnm..."
  $SUDO env FNM_DIR="$FNM_DIR" fnm install --latest --progress=never

  # fnm has no "which version did I just install" query — read the filesystem.
  # Layout is stable: $FNM_DIR/node-versions/vX.Y.Z/installation/bin/
  local latest_version
  latest_version=$(ls -1 "$FNM_DIR/node-versions" 2>/dev/null | grep '^v' | sort -V | tail -n1)
  [ -n "$latest_version" ] || die "fnm install --latest completed but no versions found in $FNM_DIR/node-versions"

  log "Setting fnm default -> $latest_version"
  $SUDO env FNM_DIR="$FNM_DIR" fnm default "$latest_version"

  # Link through the 'default' alias, not the concrete version path.
  # fnm maintains $FNM_DIR/aliases/default as a symlink → the current default's
  # installation dir, so a future `fnm default <new>` auto-propagates to /usr/local/bin.
  local default_bin="$FNM_DIR/aliases/default/bin"
  [ -x "$default_bin/node" ] || die "fnm default alias missing expected binary: $default_bin/node"

  for bin in node npm npx; do
    [ -e "$default_bin/$bin" ] || die "Missing binary in fnm install: $default_bin/$bin"
    $SUDO ln -sfn "$default_bin/$bin" "/usr/local/bin/$bin"
  done
  # corepack is optional — removed from Node core in v25+; silently skip if absent.
  [ -e "$default_bin/corepack" ] && $SUDO ln -sfn "$default_bin/corepack" /usr/local/bin/corepack

  cleanup_stale_node_versions "$latest_version"

  command -v node >/dev/null 2>&1 || die "node not on PATH after symlink"
  local installed_major
  installed_major=$(node -v | sed 's/^v\([0-9]\+\).*/\1/')
  [ "$installed_major" -ge "$NODE_MIN_MAJOR" ] || die "Installed Node is v$installed_major, need ≥$NODE_MIN_MAJOR"

  # Node tarballs ship with whatever npm was current at build time — often stale.
  # Upgrade in place so subsequent global installs (pi) use the latest npm.
  log "Updating npm to latest..."
  $SUDO env PATH="$PATH" npm install -g --silent npm@latest >/dev/null || \
    warn "npm self-update failed (non-fatal — continuing with $(npm -v))"

  log "Installed Node $(node -v), npm $(npm -v) via fnm"
}

# --- Bun: installed system-wide under /usr/local/bun so the layout mirrors fnm/Node.
# Bun's upstream installer defaults to $HOME/.bun, which makes the install
# per-invoking-user — fine for dev boxes, brittle for a shared tool: `sudo npm`
# and `bun install -g` end up writing to different trees, and /usr/local/bin/pi
# silently points at whichever one won last. Pinning BUN_INSTALL=/usr/local/bun
# and running the installer as root keeps both runtimes symmetric and root-owned. ---
BUN_ROOT="${BUN_ROOT:-/usr/local/bun}"
install_bun() {
  if [ ! -x "$BUN_ROOT/bin/bun" ]; then
    command -v unzip >/dev/null 2>&1 || { log "Installing unzip..."; $SUDO apt-get install -y unzip; }
    log "Installing Bun system-wide to $BUN_ROOT..."
    $SUDO mkdir -p "$BUN_ROOT"
    # Bun's installer respects $BUN_INSTALL. Run it as root so the tree ends up
    # root-owned and visible to every user on the box — same shape as fnm.
    $SUDO env BUN_INSTALL="$BUN_ROOT" bash -c 'curl -fsSL https://bun.sh/install | bash'
    [ -x "$BUN_ROOT/bin/bun" ] || die "Bun install finished but $BUN_ROOT/bin/bun missing"
  else
    log "Bun already installed at $BUN_ROOT/bin/bun"
  fi
  export BUN_INSTALL="$BUN_ROOT"
  export PATH="$BUN_ROOT/bin:$PATH"
  $SUDO ln -sfn "$BUN_ROOT/bin/bun" /usr/local/bin/bun
  log "Using Bun $(bun -v) (linked to /usr/local/bin/bun)"
}

# --- Detect which runtime owns /usr/local/bin/pi (readlink -f = resolve all symlinks) ---
detect_current_runtime() {
  local target
  target=$(readlink -f /usr/local/bin/pi 2>/dev/null || true)
  case "$target" in
    "$FNM_DIR"/*)    echo node ;;
    "$BUN_ROOT"/*)   echo bun ;;
    */.bun/*)        echo bun ;;  # legacy per-user Bun install (pre-system-wide script)
    *)               echo "" ;;
  esac
}

# --- Remove pi from a given runtime's global package tree + drop the /usr/local/bin shim ---
uninstall_pi_from() {
  local rt="$1"
  log "Removing pi from $rt runtime..."
  case "$rt" in
    node)
      if command -v npm >/dev/null 2>&1; then
        $SUDO env PATH="$PATH" npm uninstall -g --silent @mariozechner/pi-coding-agent >/dev/null 2>&1 || true
      fi
      ;;
    bun)
      # Remove pi from the system-wide Bun tree and any legacy per-user one.
      if [ -x "$BUN_ROOT/bin/bun" ]; then
        $SUDO env BUN_INSTALL="$BUN_ROOT" "$BUN_ROOT/bin/bun" remove -g @mariozechner/pi-coding-agent >/dev/null 2>&1 || true
      fi
      if [ -x "$HOME/.bun/bin/bun" ]; then
        "$HOME/.bun/bin/bun" remove -g @mariozechner/pi-coding-agent >/dev/null 2>&1 || true
      fi
      ;;
  esac
  $SUDO rm -f /usr/local/bin/pi
}

# --- Interactive runtime prompt when stdin is a TTY and no explicit PI_RUNTIME ---
# Default to whatever is currently installed (keeps Enter a safe no-op on re-runs).
if [ "$PI_RUNTIME" = "auto" ] && [ -t 0 ]; then
  _current=$(detect_current_runtime)
  _default="${_current:-node}"

  # If pi is already installed, show version + runtime version so the user can
  # verify what they're switching from.
  _status=""
  if [ -n "$_current" ] && command -v pi >/dev/null 2>&1; then
    _pi_ver=$(pi --version 2>/dev/null || echo "?")
    case "$_current" in
      node) _rt_ver="Node.js $(node -v 2>/dev/null || echo "?")" ;;
      bun)  _rt_ver="Bun v$(bun -v 2>/dev/null || echo "?")" ;;
    esac
    _status="pi v$_pi_ver on $_rt_ver"
  fi

  printf '\n'
  printf 'Select JavaScript runtime for pi'
  [ -n "$_status" ] && printf ' %s(currently: %s)%s' "$C_GREEN" "$_status" "$C_RESET"
  printf ':\n'
  printf '  [n] Node.js — recommended, full extension support%s\n' \
    "$([ "$_default" = node ] && printf ' (default)')"
  printf '  [b] Bun — experimental, some pi extensions may misbehave%s\n' \
    "$([ "$_default" = bun ] && printf ' (default)')"
  read -r -p "Choice [n/b, enter=$_default]: " _rt_choice || _rt_choice=""
  case "${_rt_choice,,}" in
    n|node) PI_RUNTIME=node ;;
    b|bun)  PI_RUNTIME=bun ;;
    "")     PI_RUNTIME="$_default" ;;
    *)      die "Invalid choice: '$_rt_choice' (expected n or b)" ;;
  esac
fi
# Non-TTY fallback: default auto -> node
[ "$PI_RUNTIME" = "auto" ] && PI_RUNTIME=node

# --- Runtime selection ---
step "Runtime: $PI_RUNTIME"
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

# --- Install / switch pi runtime ---
step "Installing pi"
# Detect what's currently linked at /usr/local/bin/pi so we know whether to switch.
current_pi_runtime=$(detect_current_runtime)
if [ -n "$current_pi_runtime" ] && [ "$current_pi_runtime" != "$PI_RUNTIME" ]; then
  log "Switching pi runtime: $current_pi_runtime -> $PI_RUNTIME"
  log "  (configs in $PI_DIR and $CONFIG_DIR are preserved)"
  uninstall_pi_from "$current_pi_runtime"
  current_pi_runtime=""
fi

# Migrate legacy per-user Bun installs ($HOME/.bun) to the system-wide tree.
# Same runtime, wrong location — runtime-switch logic above doesn't catch this.
if [ "$current_pi_runtime" = "bun" ] && [ "$PI_RUNTIME" = "bun" ]; then
  _legacy_pi=$(readlink -f /usr/local/bin/pi 2>/dev/null || true)
  case "$_legacy_pi" in
    */.bun/*)
      # readlink -f resolves every symlink in the chain, so $_legacy_pi can be
      # the final cli.js, not the bun bin shim. Derive the bun root by stripping
      # from "/.bun/" onward, then re-append "/.bun" — works at any chain depth.
      _legacy_bun_root="${_legacy_pi%%/.bun/*}/.bun"
      warn "Legacy per-user Bun install detected ($_legacy_bun_root) — migrating to $BUN_ROOT"
      if [ -x "$_legacy_bun_root/bin/bun" ]; then
        env BUN_INSTALL="$_legacy_bun_root" "$_legacy_bun_root/bin/bun" \
          remove -g @mariozechner/pi-coding-agent >/dev/null 2>&1 || true
      fi
      # Belt and braces: drop the shim directly in case bun's uninstall left it.
      # This matters because ~/.bashrc often has $HOME/.bun/bin earlier in PATH
      # than /usr/local/bin — a surviving shim shadows the new system-wide pi.
      [ -e "$_legacy_bun_root/bin/pi" ] && rm -f "$_legacy_bun_root/bin/pi"
      $SUDO rm -f /usr/local/bin/pi
      log "  (the $_legacy_bun_root tree itself is left intact in case other tools use it)"
      ;;
  esac
fi

# Drop a symlink that points at a path that no longer exists (stale from earlier runs)
[ -L /usr/local/bin/pi ] && [ ! -e /usr/local/bin/pi ] && $SUDO rm -f /usr/local/bin/pi

# Always run the package manager — npm/bun are idempotent (no-op when up-to-date,
# upgrade when a newer version is published). Skipping here previously meant
# re-running install.sh never picked up pi releases.
_pre_ver=$(pi --version 2>/dev/null || echo "none")
case "$PI_RUNTIME" in
  node)
    log "Installing/updating pi via npm (current: $_pre_ver)..."
    # npm -g writes into the fnm tree (root-owned), so sudo with PATH works cleanly
    $SUDO env PATH="$PATH" npm install -g @mariozechner/pi-coding-agent
    pi_src="$FNM_DIR/aliases/default/bin/pi"
    ;;
  bun)
    log "Installing/updating pi via Bun (experimental, current: $_pre_ver)..."
    $SUDO env BUN_INSTALL="$BUN_ROOT" PATH="$BUN_ROOT/bin:$PATH" bun install -g @mariozechner/pi-coding-agent
    pi_src="$BUN_ROOT/bin/pi"
    ;;
esac
[ -e "$pi_src" ] || die "pi install completed but shim not found at $pi_src"
$SUDO ln -sfn "$pi_src" /usr/local/bin/pi
log "Linked /usr/local/bin/pi -> $pi_src"

# Drift guard: confirm /usr/local/bin/pi actually resolves into the runtime we picked.
# Catches the class of bug where a parallel install (e.g. sudo npm while bun owned
# the symlink) leaves pi served from the wrong tree.
_final_target=$(readlink -f /usr/local/bin/pi 2>/dev/null || true)
case "$PI_RUNTIME" in
  node) _expected_prefix="$FNM_DIR" ;;
  bun)  _expected_prefix="$BUN_ROOT" ;;
esac
case "$_final_target" in
  "$_expected_prefix"/*) ;;
  *) warn "Drift: /usr/local/bin/pi -> $_final_target (expected under $_expected_prefix) — another runtime may still own the symlink" ;;
esac

# --- Clone or update the config repo ---
step "Syncing configs"
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

# --- Final verification: confirm which runtime is actually serving pi ---
step "Summary"
_final_pi=$(pi --version 2>/dev/null || echo "unavailable")
case "$PI_RUNTIME" in
  node) _final_rt="Node.js $(node -v 2>/dev/null || echo "?")" ;;
  bun)  _final_rt="Bun v$(bun -v 2>/dev/null || echo "?")" ;;
esac
_pi_target=$(readlink -f "$(command -v pi 2>/dev/null)" 2>/dev/null || echo "?")
ok   "pi v$_final_pi  |  Runtime: $_final_rt"
log  "  /usr/local/bin/pi -> $_pi_target"
log  "Add API keys:   $PI_DIR/auth.json  (see $CONFIG_DIR/auth.json.example)"
log  "Update later:   re-run this script, or: git -C $CONFIG_DIR pull"
if [ "$PI_RUNTIME" = "bun" ]; then
  warn "Bun PATH may not be active in your current shell — run: source ~/.bashrc"
fi
