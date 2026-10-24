#!/usr/bin/env bash
# =============================================================================
#  mac_03_grant_permissions.sh — AUTOMATED TCC granter + environment setup
#
#  METHOD-AWARE: runs for BOTH rustdesk and moonlight.
#    - Always (both methods): install deps, set 1920x1080, pre-authorize
#      screencapture, start dialog-dismissal loop, set dark mode + reduced
#      transparency/motion (lower encoding work = lower latency for BOTH
#      RustDesk and Sunshine), wait for any replayd dialog.
#    - Rustdesk only: install + configure RustDesk, run mac_grant_tcc.py
#      (grants RustDesk's 4 TCC services), restart RustDesk.
#      (For moonlight, Sunshine's TCC is granted directly inside
#      mac_06_sunshine.sh — mac_grant_tcc.py only targets RustDesk.)
#
#  Flow:
#    1. Install deps (cliclick, Pillow, displayplacer)                 [both]
#    2. Set display to 1920x1080 (BEFORE grant so dialog detection
#       works at the final resolution)                                   [both]
#    3. Install + configure RustDesk (idempotent)                  [rustdesk]
#    4. Pre-authorize screencapture + start dialog dismissal loop      [both]
#    5. Set macOS dark mode + reduced transparency/motion               [both]
#    6. Grant all 4 TCC services via sqlite3 (mac_grant_tcc.py)    [rustdesk]
#    7. Wait for replayd dialog to be dismissed                         [both]
#    8. Restart RustDesk to pick up the clean permission state     [rustdesk]
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 03 — TCC granter + env setup (method=${REMOTE_METHOD:-rustdesk})"
require_env MAC_USER_PASSWORD
# RustDesk password is only needed when actually configuring RustDesk.
if [ "${REMOTE_METHOD:-rustdesk}" = "rustdesk" ]; then
  require_env RUSTDESK_PASSWORD
fi

# --- 0. deps (always — displayplacer for resolution; Pillow for the TCC
#        granter; cliclick for the dialog loop's screen interactions) --------
if ! command -v cliclick >/dev/null 2>&1 || ! command -v displayplacer >/dev/null 2>&1; then
  brew install cliclick displayplacer 2>&1 | tail -n2  # parallel install
fi
if ! python3 -c "import PIL" 2>/dev/null; then
  pip3 install Pillow 2>&1 | tail -n1 || true
fi

# --- 1. set display to 1920x1080 (BEFORE grant — always, both methods) -------
# Sunshine + RustDesk both benefit from a fixed 1920x1080: stable frame size,
# known aspect ratio, and the dialog-detection logic works at the final res.
if command -v displayplacer >/dev/null 2>&1; then
  log "setting display resolution to 1920x1080"
  # parse the persistent screen ID (note: it's "Persistent SCREEN id", not "Persistent id")
  DISP_ID="$(displayplacer list 2>/dev/null | grep -iE 'Persistent screen id:' | head -1 | sed 's/.*Persistent screen id: *//' | tr -d ' \r' || true)"
  if [ -n "$DISP_ID" ]; then
    log "found display: $DISP_ID"
    # use the exact format displayplacer suggests (with hz + color_depth + enabled)
    displayplacer "id:$DISP_ID res:1920x1080 hz:60 color_depth:7 enabled:true scaling:off origin:(0,0) degree:0" 2>&1 | while IFS= read -r line; do log "  $line"; done || true
    sleep 2
    CUR_RES="$(displayplacer list 2>/dev/null | grep -iE 'Resolution:' | head -1 | sed 's/.*Resolution: *//' | tr -d ' \r' || true)"
    if echo "$CUR_RES" | grep -q "1920x1080"; then
      ok "display set to 1920x1080"
    else
      warn "display resolution is $CUR_RES (expected 1920x1080) — may need manual change"
    fi
  else
    warn "could not find display ID — using default resolution"
  fi
fi

# --- 2. install + configure RustDesk (RUSTDESK ONLY) ------------------------
if [ "${REMOTE_METHOD:-rustdesk}" = "rustdesk" ]; then
  if [ ! -x "$RUSTDESK_BIN" ]; then
    log "installing RustDesk"
    # RustDesk already installed in step 02 (direct DMG, faster than brew cask)
    xattr -dr com.apple.quarantine "$RUSTDESK_APP" 2>/dev/null || true
  fi

  RUSTDESK_USER_PREFS="$RUSTDESK_PREFS_DIR"
  sudo -u "$RUNNER_USER" mkdir -p "$RUSTDESK_USER_PREFS"
  RUSTDESK_ID="${RUSTDESK_ID:-$(date +%s | tail -c 9)}"
  sudo -u "$RUNNER_USER" tee "$RUSTDESK_USER_PREFS/RustDesk.toml" >/dev/null <<EOF
id = '${RUSTDESK_ID}'
password = '${RUSTDESK_PASSWORD}'
EOF
  sudo -u "$RUNNER_USER" tee "$RUSTDESK_USER_PREFS/RustDesk2.toml" >/dev/null <<EOF
[options]
custom-rendezvous-server = ''
relay-server = ''
api-server = ''
direct-server = 'Y'
direct-access-port = '${RUSTDESK_PORT}'
verification-method = 'use-fixed-password'
allow-clipboard = 'Y'
allow-file-transfer = 'Y'
allow-file-copy = 'Y'
allow-audio = 'Y'
allow-keyboard = 'Y'
allow-mouse = 'Y'
allow-restart = 'Y'
allow-cam = 'Y'
# --- CONNECTION STABILITY (fixes 'os error 10054' disconnects) ---
# Disable auto-disconnect (don't drop idle connections)
allow-auto-disconnect = 'N'
# --- PERFORMANCE ---
codec-preference = 'vp9'
image-quality = 'best'
custom-fps = '60'
enable-hwcodec = 'Y'
enable-abr = 'N'
use-texture-render = 'Y'
EOF
  sudo mkdir -p /var/root/Library/Preferences/com.carriez.RustDesk
  sudo cp "$RUSTDESK_USER_PREFS/RustDesk.toml" "$RUSTDESK_USER_PREFS/RustDesk2.toml" \
       /var/root/Library/Preferences/com.carriez.RustDesk/ 2>/dev/null || true
  ok "RustDesk configured (port=$RUSTDESK_PORT)"
else
  log "remote_method=${REMOTE_METHOD} → skipping RustDesk install + config"
fi

# --- 3. pre-authorize screencapture + start dialog dismissal (always) ------
# Both Sunshine and RustDesk need screen capture; both benefit from the
# dialog-dismissal loop auto-clicking "Allow"/"Accept" on TCC prompts.
preauthorize_screencapture
start_dialog_dismissal_loop

# --- 3b. set macOS dark mode + reduce transparency/motion (always) -----------
# Dark mode + reduced transparency + reduced motion = FEWER pixels changing
# per frame = LESS encoding work for RustDesk OR Sunshine = LOWER latency.
# This is a latency optimization, so it applies to BOTH methods (Sunshine
# streaming benefits at least as much as RustDesk).
# These are pure UI appearance settings — they do NOT affect connection behavior.
log "setting macOS dark mode + reduced transparency/motion..."

# System-wide dark mode via osascript (applies IMMEDIATELY to all apps + the
# menu bar + dock — unlike `defaults write` which only takes effect after a
# process restart). osascript tells System Events to set appearance preferences.
sudo -u "$RUNNER_USER" osascript -e '
  tell application "System Events"
    tell appearance preferences
      set dark mode to true
    end tell
  end tell
' 2>/dev/null || true

# Also write the defaults (belt and suspenders — for processes that start later)
sudo -u "$RUNNER_USER" defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark" 2>/dev/null || true
sudo -u "$RUNNER_USER" defaults write NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically -bool false 2>/dev/null || true
# Reduce transparency (less blur/animation = less screen changes to encode)
sudo -u "$RUNNER_USER" defaults write com.apple.universalaccess reduceTransparency -bool true 2>/dev/null || true
# Reduce motion (less animation = less screen changes to encode)
sudo -u "$RUNNER_USER" defaults write com.apple.universalaccess reduceMotion -bool true 2>/dev/null || true
# Flush the preferences cache so all running processes pick up the change
sudo killall -u "$RUNNER_USER" cfprefsd 2>/dev/null || true
ok "dark mode + reduced transparency/motion enabled (applied system-wide)"

# --- 4. THE GRANT (RUSTDESK ONLY — mac_grant_tcc.py targets RustDesk) -------
# mac_grant_tcc.py grants the 4 TCC services (ScreenCapture, Accessibility,
# Input Monitoring, LocalNetwork) to com.carriez.rustdesk ONLY. For moonlight,
# Sunshine's TCC is granted directly inside mac_06_sunshine.sh via sqlite3
# (kTCCServiceScreenCapture / Accessibility / ListenEvent / LocalNetwork →
# com.lizardbyte.sunshine), so running mac_grant_tcc.py here would be a no-op
# plus wasted AX-verify UI work.
if [ "${REMOTE_METHOD:-rustdesk}" = "rustdesk" ]; then
  log "running mac_grant_tcc.py (RustDesk TCC grant)..."
  set +e
  python3 "$PROJECT_ROOT/mac_grant_tcc.py" > "$STATE_DIR/grant_output.log" 2>&1
  GRANT_RC=$?
  set -e
  cat "$STATE_DIR/grant_output.log"

  if [ "$GRANT_RC" -ne 0 ]; then
    die "automated granter failed (rc=$GRANT_RC)"
  fi
  ok "GRANT SUCCEEDED — 4 services in TCC.db (RustDesk)"
else
  log "remote_method=${REMOTE_METHOD} → skipping RustDesk TCC grant (Sunshine TCC handled in mac_06_sunshine.sh)"
fi

# --- 5. wait for the dialog loop to handle any replayd dialog (always) ------
# The dialog loop (started in step 3) uses osascript to click "Allow" on
# any system dialogs. We wait a few seconds for it to handle the replayd
# dialog if it appears (useful for both methods — Sunshine can also trigger
# a Screen Recording prompt on first capture).
log "waiting for any replayd dialog to be dismissed (10s)..."
sleep 10
ok "dialog handling complete"

# --- 6. restart RustDesk to pick up the clean permission state (RUSTDESK) ---
if [ "${REMOTE_METHOD:-rustdesk}" = "rustdesk" ]; then
  log "restarting RustDesk to pick up the clean permission state..."
  pkill -9 -x RustDesk 2>/dev/null || true
  sleep 3
  gui_run open -a RustDesk || true
  sleep 8
  ok "RustDesk restarted — screen capture should now work"
else
  log "remote_method=${REMOTE_METHOD} → skipping RustDesk restart (Sunshine handles its own launch in mac_06_sunshine.sh)"
fi
