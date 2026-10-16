#!/usr/bin/env bash
# =============================================================================
#  mac_02_install_rustdesk.sh
#  Install RustDesk and configure it for DIRECT-IP-only operation:
#
#     direct-server = Y                 (host listens on TCP 21118)
#     direct-access-port = 21118
#     custom-rendezvous-server = ''     (no hbbs — no ID registration server)
#     relay-server = ''                 (no hbbr — no relay)
#     api-server = ''                   (no public API)
#     verification-method = use-fixed-password
#     password = $RUSTDESK_PASSWORD     (plaintext — RustDesk encrypts on save)
#     id = $RUSTDESK_ID
#
#  The client (Windows 11 / Android RustDesk app) then dials:
#        <runner-tailscale-IPv4>:21118
#  directly over the Tailscale WireGuard tunnel.  No third party, no relay,
#  no rendezvous, no API key.
#
#  WHY WE WRITE CONFIG FILES DIRECTLY (not via the RustDesk CLI):
#     The RustDesk CLI flags --password / --set-id / --option print
#       "Installation and administrative privileges required!"
#     and refuse to run unless invoked as ROOT (see src/core_main.rs gate:
#     `is_installed() && is_root()`).  Running them via `sudo` (root) would
#     write the config to /var/root/... instead of /Users/runner/...
#     So we bypass the CLI entirely and write the TOML files directly.
#     RustDesk's `decrypt_str_or_original` accepts PLAINTEXT values (it only
#     treats strings starting with "00" as encrypted), so we can write
#     `password = 'SECRET'` and `id = '123'` in the clear — RustDesk will
#     re-encrypt them on its next save.  No CLI, no root dance.
#
#  WHY RustDesk2.toml MUST use a [options] SUBTABLE:
#     RustDesk deserialises RustDesk2.toml into a struct where the server
#     config keys live INSIDE an `options` subtable.  Flat top-level keys
#     are silently dropped by serde → direct-server=Y is lost → port 21118
#     never listens.  This was Bug #3 in the prior version.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 02 — install + configure RustDesk (direct-IP, no relay)"

require_env RUSTDESK_PASSWORD

# --- 0. helper functions MUST be defined before main code --------------------
# (prior version defined them after `exit 0`, so bash never saw them —
#  resulting in "install_launch_agent: command not found".)

# Download + mount a RustDesk DMG, copy the .app to /Applications.
install_via_dmg() {
  local dmg="/tmp/rustdesk.dmg"
  # try arm64 first (macos-15 runner is Apple Silicon), then x86_64
  local arch_url="https://github.com/rustdesk/rustdesk/releases/download/1.3.9/rustdesk-1.3.9-aarch64.dmg"
  local x86_url="https://github.com/rustdesk/rustdesk/releases/download/1.3.9/rustdesk-1.3.9-x86_64.dmg"
  log "downloading RustDesk DMG (arm64 preferred)"
  if curl -fsSL "$arch_url" -o "$dmg" 2>/dev/null; then
    : # arm64 ok
  else
    curl -fsSL "$x86_url" -o "$dmg" || die "could not download RustDesk DMG"
  fi
  log "mounting DMG and copying .app"
  hdiutil attach "$dmg" -nobrowse -quiet
  local vol; vol="$(hdiutil info | grep '/Volumes/RustDesk' | head -n1 | awk '{print $NF}')"
  [ -z "$vol" ] && vol="/Volumes/RustDesk"
  cp -R "$vol/RustDesk.app" /Applications/ || die "could not copy RustDesk.app"
  hdiutil detach "$vol" -quiet 2>/dev/null || true
  rm -f "$dmg"
}

# Write the user-level LaunchAgent plist so RustDesk starts in the runner's
# Aqua GUI session (required — a root LaunchDaemon cannot capture the screen
# because WindowServer only talks to GUI-session processes).
#
# CRITICAL: use `--server` (NOT `--service`).  The official RustDesk
# agent.plist uses --server; --service is for the root LaunchDaemon which
# cannot do screen capture.
install_launch_agent() {
  local label="com.carriez.RustDesk_server"
  local plist="/Users/$RUNNER_USER/Library/LaunchAgents/${label}.plist"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUSTDESK_BIN}</string>
    <string>--server</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
    <key>AfterInitialDemand</key>
    <false/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <array>
    <string>Aqua</string>
    <string>LoginWindow</string>
  </array>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
EOF
  # ensure the runner owns it
  chown "$RUNNER_USER" "$plist"
  ok "LaunchAgent installed at $plist (uses --server, Aqua+LoginWindow sessions)"
}

# Also install a root-level LaunchDaemon.  On macOS RustDesk uses this for
# privileged operations (input injection elevation, service management).
# The GUI LaunchAgent does the actual screen capture.
install_launch_daemon() {
  local label="com.carriez.RustDesk_service"
  local plist="/Library/LaunchDaemons/${label}.plist"
  # CRITICAL: use `sudo tee` NOT `cat >` — the redirection in `cat > $plist`
  # opens the file in the CURRENT shell context (runner user), which can't
  # write to /Library/LaunchDaemons/ (root-owned).  `sudo tee` opens the file
  # under root's authority instead.
  sudo tee "$plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUSTDESK_BIN}</string>
    <string>--service</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <array>
    <string>System</string>
  </array>
</dict>
</plist>
EOF
  sudo chown root:wheel "$plist"
  sudo chmod 644 "$plist"
  ok "LaunchDaemon installed at $plist (root, --service)"
}

# --- 1. install RustDesk ----------------------------------------------------
if [ -x "$RUSTDESK_BIN" ]; then
  warn "RustDesk already installed at $RUSTDESK_APP — reinstalling fresh"
  rm -rf "$RUSTDESK_APP"
fi

# Primary path: Homebrew cask (notarized, Sequoia-compatible, auto-quarantine strip)
if command -v brew >/dev/null 2>&1; then
  log "installing via 'brew install --cask rustdesk'"
  install_via_dmg  # direct DMG download (faster than brew cask) || {
    ok "using direct DMG (faster than brew cask)"
    install_via_dmg
  }
else
  warn "brew not found — falling back to direct DMG download"
  install_via_dmg
fi

# strip quarantine attribute regardless of install method
xattr -dr com.apple.quarantine "$RUSTDESK_APP" 2>/dev/null || true

# install displayplacer (for setting 1920x1080 resolution in step 04)
if ! command -v displayplacer >/dev/null 2>&1; then
  brew install displayplacer 2>&1 | tail -n1
fi

[ -x "$RUSTDESK_BIN" ] || die "RustDesk binary not present at $RUSTDESK_BIN after install"
ok "RustDesk installed: $($RUSTDESK_BIN --version 2>/dev/null || echo 'unknown version')"

# pre-authorize screencapture (suppresses the replayd "bypass window picker" dialog)
preauthorize_screencapture

# --- 2. write RustDesk.toml (id + password) ---------------------------------
RUSTDESK_ID="${RUSTDESK_ID:-$(date +%s | tail -c 9)}"
RUSTDESK_USER_PREFS="/Users/$RUNNER_USER/Library/Preferences/com.carriez.RustDesk"
sudo -u "$RUNNER_USER" mkdir -p "$RUSTDESK_USER_PREFS"

# write as the runner user so RustDesk (running as runner) can read+update it
sudo -u "$RUNNER_USER" tee "$RUSTDESK_USER_PREFS/RustDesk.toml" >/dev/null <<EOF
# Written by The_Apple_Project — plaintext; RustDesk re-encrypts on save.
id = '${RUSTDESK_ID}'
password = '${RUSTDESK_PASSWORD}'
EOF
ok "wrote $RUSTDESK_USER_PREFS/RustDesk.toml (id=$RUSTDESK_ID, plaintext password)"

# --- 3. write RustDesk2.toml (server config) WITH [options] SUBTABLE --------
# CRITICAL: the server-config keys MUST live inside a [options] TOML subtable.
# Flat top-level keys are silently dropped by serde → direct-server=Y lost.
sudo -u "$RUNNER_USER" tee "$RUSTDESK_USER_PREFS/RustDesk2.toml" >/dev/null <<EOF
# Written by The_Apple_Project — direct-IP, relay-less configuration.
# The [options] subtable is REQUIRED — flat top-level keys are ignored.

[options]
custom-rendezvous-server = ''
relay-server = ''
api-server = ''
direct-server = 'Y'
direct-access-port = '${RUSTDESK_PORT}'
verification-method = 'use-fixed-password'
# Pre-grant ALL permissions so RustDesk does NOT show the "Accept incoming
# connection?" dialog (which causes "waiting for image" if nobody clicks Accept).
# With these set to Y + use-fixed-password, a correct-password connection
# auto-accepts with full permissions — no dialog, no human, no delay.
allow-clipboard = 'Y'
allow-file-transfer = 'Y'
allow-file-copy = 'Y'
allow-audio = 'Y'
allow-keyboard = 'Y'
allow-mouse = 'Y'
allow-restart = 'Y'
allow-cam = 'Y'
EOF
ok "wrote $RUSTDESK_USER_PREFS/RustDesk2.toml ([options] subtable, direct-server=Y, no relay)"

# --- 4. mirror the config into root's prefs (for the LaunchDaemon) ----------
# The root LaunchDaemon reads from /var/root/...; copy the files there so both
# the daemon and the GUI agent share the same config.
sudo mkdir -p /var/root/Library/Preferences/com.carriez.RustDesk
sudo cp "$RUSTDESK_USER_PREFS/RustDesk.toml"  /var/root/Library/Preferences/com.carriez.RustDesk/
sudo cp "$RUSTDESK_USER_PREFS/RustDesk2.toml" /var/root/Library/Preferences/com.carriez.RustDesk/
ok "mirrored config to /var/root/Library/Preferences/com.carriez.RustDesk/"

# --- 5. macOS application firewall: allow RustDesk through ------------------
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$RUSTDESK_BIN" 2>/dev/null || true
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$RUSTDESK_BIN" 2>/dev/null || true

# --- 6. install the launchd plists ------------------------------------------
install_launch_agent
install_launch_daemon

# --- 7. record state for later steps ----------------------------------------
echo "$RUSTDESK_ID" > "$STATE_DIR/rustdesk-id"
echo "$RUSTDESK_PASSWORD" > "$STATE_DIR/rustdesk-password"
chmod 600 "$STATE_DIR/rustdesk-password"
ok "RustDesk id=$RUSTDESK_ID  password=********  (stored in $STATE_DIR/rustdesk-password)"

ok "RustDesk configured for direct-IP on port $RUSTDESK_PORT (no relay)"
log "next step will grant Screen Recording / Accessibility / Input Monitoring"

