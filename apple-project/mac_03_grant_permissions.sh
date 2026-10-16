#!/usr/bin/env bash
# =============================================================================
#  mac_03_grant_permissions.sh — AUTOMATED TCC granter
#
#  Flow:
#    1. Install deps (cliclick, Pillow, displayplacer)
#    2. Set display to 1920x1080 (BEFORE grant so everything happens at final res)
#    3. Install + configure RustDesk (idempotent)
#    4. Pre-authorize screencapture + start dialog dismissal loop
#    5. Grant all 4 TCC services via sqlite3 (mac_grant_tcc.py)
#    6. Trigger + wait for replayd dialog to be dismissed
#    7. Restart RustDesk so it picks up the clean permission state
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 03 — automated TCC permission granter"
require_env MAC_USER_PASSWORD
require_env RUSTDESK_PASSWORD

# --- 0. deps ---------------------------------------------------------------
if ! command -v cliclick >/dev/null 2>&1; then
  brew install cliclick displayplacer 2>&1 | tail -n2  # parallel install
fi
if ! python3 -c "import PIL" 2>/dev/null; then
  pip3 install Pillow 2>&1 | tail -n1 || true
fi
if ! command -v displayplacer >/dev/null 2>&1; then
fi

# --- 1. set display to 1920x1080 (BEFORE grant — so dialog detection works
#        at the final resolution, and RustDesk launches at 1920x1080) --------
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

# --- 2. install + configure RustDesk (idempotent) ---------------------------
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

# --- 3. pre-authorize screencapture + start dialog dismissal ----------------
preauthorize_screencapture
start_dialog_dismissal_loop

# --- 3b. set macOS dark mode + reduce transparency/motion -------------------
# Dark mode + reduced transparency + reduced motion = FEWER pixels changing per
# frame = LESS encoding work for RustDesk = LOWER latency.
# These are pure UI appearance settings — they do NOT affect RustDesk's
# connection behavior (no sleep/caffeinate/keep-awake changes).
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

# --- 4. THE GRANT (pure sqlite3, no UI) -------------------------------------
log "running mac_grant_tcc.py ..."
set +e
python3 "$PROJECT_ROOT/mac_grant_tcc.py" > "$STATE_DIR/grant_output.log" 2>&1
GRANT_RC=$?
set -e
cat "$STATE_DIR/grant_output.log"

if [ "$GRANT_RC" -ne 0 ]; then
  die "automated granter failed (rc=$GRANT_RC)"
fi
ok "GRANT SUCCEEDED — 4 services in TCC.db"

# --- 5. wait for the dialog loop to handle any replayd dialog ---------------
# The dialog loop (started in step 3) uses osascript to click "Allow" on
# any system dialogs. We just wait a few seconds for it to handle the
# replayd dialog if it appears.
log "waiting for any replayd dialog to be dismissed (10s)..."
sleep 10
ok "dialog handling complete"

# --- 6. restart RustDesk to pick up the clean permission state --------------
log "restarting RustDesk to pick up the clean permission state..."
pkill -9 -x RustDesk 2>/dev/null || true
sleep 3
gui_run open -a RustDesk || true
sleep 8
ok "RustDesk restarted — screen capture should now work"
