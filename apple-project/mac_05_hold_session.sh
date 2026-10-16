#!/usr/bin/env bash
# =============================================================================
#  mac_05_hold_session.sh
#  Keeps the job alive so the operator can drive the Mac via RustDesk.
#  Restarts the dialog-dismissal loop (each step is a separate shell).
#  Exits when the done-flag appears OR the hold timeout elapses.
#
#  HOLD_MINUTES=0 means NO limit (GitHub closes at 6 hours = 360 min).
#  DIALOG_HUNTING=0 disables the dialog-hunting loop.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 05 — holding session open for remote control"

HOLD_MINUTES_INT="${HOLD_MINUTES:-0}"
# 0 = no limit; cap at 350 to stay under GitHub's 360-min hard cap
if [ "$HOLD_MINUTES_INT" -eq 0 ]; then
  HOLD_MINUTES_INT=350
  log "hold_minutes=0 → no manual limit (using 350 min max, GitHub closes at 6h)"
elif [ "$HOLD_MINUTES_INT" -gt 350 ]; then
  HOLD_MINUTES_INT=350
fi
DEADLINE=$(( $(date +%s) + HOLD_MINUTES_INT * 60 ))

[ -f "$STATE_DIR/connection-info.txt" ] && cat "$STATE_DIR/connection-info.txt"

log "session alive until $(date -r "$DEADLINE" '+%H:%M:%S') runner time"
log "(end: ssh cihelper@<ip> 'touch $DONE_FLAG'  or  wait for timeout)"

rm -f "$DONE_FLAG"

# --- TCP keepalive: prevents RustDesk 'os error 10054' disconnects ----------
# macOS default TCP keepalive is 2 hours (7200s) — way too long.
# RustDesk direct-IP has no application-level keepalive, so idle TCP connections
# get dropped by macOS after a few minutes. Setting keepidle to 60s forces
# macOS to send TCP keepalive probes every 60s, keeping the connection alive.
sudo sysctl -w net.inet.tcp.keepidle=60000 2>/dev/null || true
sudo sysctl -w net.inet.tcp.keepintvl=10000 2>/dev/null || true
sudo sysctl -w net.inet.tcp.keepcnt=5 2>/dev/null || true
sudo sysctl -w net.inet.tcp.always_keepalive=1 2>/dev/null || true
log "TCP keepalive set: 60s idle, 10s interval, 5 probes"

# restart the dialog-dismissal loop (died with step 04's shell)
start_dialog_dismissal_loop

elapsed=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ -f "$DONE_FLAG" ]; then
    ok "done-flag detected — ending session cleanly"
    rm -f "$DONE_FLAG"
    stop_dialog_dismissal_loop
    exit 0
  fi
  # heartbeat every 30s (GitHub kills jobs with 10+ min of no log output)
  if [ $((elapsed % 30)) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
    remaining=$(( (DEADLINE - $(date +%s)) / 60 ))
    rd="OK"; port_open "$RUSTDESK_PORT" || rd="DOWN"
    log "alive — ${remaining}min left (RustDesk:$rd, touch $DONE_FLAG to end)"
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

stop_dialog_dismissal_loop
warn "hold timeout reached ($HOLD_MINUTES_INT min) — ending session"
