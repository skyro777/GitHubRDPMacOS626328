#!/usr/bin/env bash
# =============================================================================
#  mac_lib.sh — shared helpers for The Apple Project.
#  Source me:   source "$(dirname "$0")/mac_lib.sh"
# =============================================================================
set -o pipefail

# Speed optimizations (set early so all steps benefit)
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALL_UPGRADE=1
export HOMEBREW_CURL_RETRIES=5
export HOMEBREW_MAKE_JOBS=4
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_INPUT=1

# --- pretty logging ---------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err()  { printf '[FAIL] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- runner identity + paths ------------------------------------------------
RUNNER_USER="${RUNNER_USER:-runner}"
MAC_USER="${MAC_USER:-cihelper}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-/tmp/apple-project}"
mkdir -p "$STATE_DIR"; chmod 1777 "$STATE_DIR"
DONE_FLAG="$STATE_DIR/remote-done"
export RUNNER_USER MAC_USER PROJECT_ROOT STATE_DIR DONE_FLAG

# --- require a secret env var -----------------------------------------------
require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "Required env var $name is empty. Add it as a GitHub repo Secret."
  fi
  return 0  # explicitly return 0 so set -e doesn't kill the caller
}

# --- run as the GUI user (inside the Aqua session) --------------------------
gui_run() {
  sudo -u "$RUNNER_USER" env HOME="/Users/$RUNNER_USER" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" "$@"
}

# --- is a TCP port listening? -----------------------------------------------
port_open() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; }

# --- wait until a predicate is true, with timeout (seconds) -----------------
wait_for() {
  local timeout="$1"; shift; local elapsed=0
  until "$@"; do
    sleep 1; elapsed=$((elapsed + 1))
    [ "$elapsed" -ge "$timeout" ] && return 1
  done; return 0
}

# --- RustDesk + TCC constants -----------------------------------------------
RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK_BIN="$RUSTDESK_APP/Contents/MacOS/RustDesk"
RUSTDESK_BUNDLE="com.carriez.rustdesk"          # MUST be lowercase (matches codesign)
RUSTDESK_PREFS_DIR="/Users/$RUNNER_USER/Library/Preferences/com.carriez.RustDesk"
RUSTDESK_PORT="21118"
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
export RUSTDESK_APP RUSTDESK_BIN RUSTDESK_BUNDLE RUSTDESK_PREFS_DIR RUSTDESK_PORT TCC_DB

# =============================================================================
#  Sequoia ScreenCapture pre-authorization
#  Writes far-future dates to ScreenCaptureApprovals.plist to suppress the
#  replayd "bypass window picker" dialog. Best-effort — the dialog-dismissal
#  loop (below) is the reliable fallback.
# =============================================================================
preauthorize_screencapture() {
  local sca_dir="$HOME/Library/Group Containers/group.com.apple.replayd"
  local sca_plist="$sca_dir/ScreenCaptureApprovals.plist"
  local sys_dir="/Library/Group Containers/group.com.apple.replayd"
  sudo mkdir -p "$sca_dir" "$sys_dir" 2>/dev/null || true

  local bins=("/bin/bash" "/usr/bin/screencapture" "/usr/bin/osascript" "$RUSTDESK_BIN")
  command -v cliclick >/dev/null 2>&1 && bins+=("$(command -v cliclick)")

  # Write plist (user + system) as root — TCC-protected on 15.7
  for plist in "$sca_plist" "$sys_dir/ScreenCaptureApprovals.plist"; do
    for bin in "${bins[@]}"; do
      sudo defaults write "$plist" "$bin" -date "2099-01-01 00:00:00 +0000" 2>/dev/null || true
    done
  done
  sudo killall -HUP replayd 2>/dev/null || true
  sudo killall -HUP cfprefsd 2>/dev/null || true

  # DIAGNOSTIC: dump the plist contents so we can see if it was written correctly
  log "ScreenCaptureApprovals.plist contents (user):"
  sudo defaults read "$sca_plist" 2>/dev/null | while IFS= read -r line; do log "  $line"; done || true
  log "ScreenCaptureApprovals.plist contents (system):"
  sudo defaults read "$sys_dir/ScreenCaptureApprovals.plist" 2>/dev/null | while IFS= read -r line; do log "  $line"; done || true

  ok "screencapture pre-authorized (${#bins[@]} binaries, user+system plist)"
}

# =============================================================================
# =============================================================================
#  Dialog auto-dismissal loop (LIGHTWEIGHT — no screencapture during hold)
#
#  Uses osascript ONLY (no screencapture/pixel scan) to avoid competing
#  with RustDesk for the Screen Recording resource + CPU.
#  Clicks: Accept, Allow, Later, Not Now. NEVER Cancel / Don't Allow.
#  When a RustDesk client IS connected: sleeps 30s (near-zero CPU).
# =============================================================================
DIALOG_DISMISS_PID=""
export DIALOG_DISMISS_PID

# Check if a RustDesk client is currently connected (ESTABLISHED on port 21118).
rustdesk_client_connected() {
  lsof -nP -iTCP:"$RUSTDESK_PORT" -sTCP:ESTABLISHED 2>/dev/null | grep -q ESTABLISHED
}

start_dialog_dismissal_loop() {
  [ -n "$DIALOG_DISMISS_PID" ] && kill -0 "$DIALOG_DISMISS_PID" 2>/dev/null && return 0
  (
    while true; do
      # When a client IS connected: sleep 30s (near-zero CPU, no osascript)
      if rustdesk_client_connected 2>/dev/null; then
        sleep 30
        continue
      fi

      # When NOT connected: check for dialogs via osascript (lightweight)
      osascript -e '
        try
          tell application "System Events"
            repeat with p in (every process whose background only is false)
              repeat with w in (windows of p)
                try
                  repeat with b in (every button of w)
                    try
                      set n to name of b as text
                      if n starts with "Allow" or n is "Accept" or n is "Later" or n is "Not Now" then
                        click b
                        return
                      end if
                    end try
                  end repeat
                end try
              end repeat
            end repeat
          end tell
        end try
      ' 2>/dev/null || true

      sleep 5
    done
  ) &
  DIALOG_DISMISS_PID=$!
  disown 2>/dev/null || true
  log "dialog loop started (PID=$DIALOG_DISMISS_PID, lightweight: no screencapture)"
}

stop_dialog_dismissal_loop() {
  [ -n "$DIALOG_DISMISS_PID" ] && kill "$DIALOG_DISMISS_PID" 2>/dev/null || true
  [ -n "$DIALOG_DISMISS_PID" ] && wait "$DIALOG_DISMISS_PID" 2>/dev/null || true
  DIALOG_DISMISS_PID=""
}
