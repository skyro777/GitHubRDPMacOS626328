#!/usr/bin/env bash
# =============================================================================
#  mac_04_start_rustdesk.sh — SSH enable + connection-info (method-aware)
#
#  METHOD-AWARE: runs for BOTH rustdesk and moonlight.
#    - Always (both methods):
#        1. Enable SSH (Remote Login) — needed for the done-flag fallback
#           (ssh cihelper@<ip> 'touch /tmp/apple-project/remote-done').
#        2. Restart the dialog-dismissal loop (covers the step 03 → 05 gap).
#        3. Write + print the connection-info block (Tailscale IP/host, SSH,
#           macOS admin user, display 1920x1080). For moonlight, the
#           RustDesk-specific lines are omitted and a pointer to Step 05
#           (Sunshine PIN page) is shown instead.
#    - Rustdesk only:
#        4. Verify RustDesk is listening on TCP 21118.
#        5. Get the ACTUAL RustDesk ID (via --get-id CLI).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 04 — verify + connection info (method=${REMOTE_METHOD:-rustdesk})"

# --- 0. enable Remote Login (SSH) for done-flag fallback (always) -----------
# The hold-session step ends cleanly when you run:
#   ssh cihelper@<ip> 'touch /tmp/apple-project/remote-done'
# This requires SSH to be enabled. It's useful for BOTH methods (you may want
# to end a Sunshine session the same way).
sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || {
  sudo launchctl enable system/com.openssh.sshd 2>/dev/null || true
  sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
}
ok "Remote Login (SSH) enabled"

# --- 1. restart dialog dismissal loop (covers gap until step 05/06) (always) -
start_dialog_dismissal_loop

# --- 2. verify RustDesk is listening (RUSTDESK ONLY) -----------------------
RD_ID=""
RD_PASS=""
if [ "${REMOTE_METHOD:-rustdesk}" = "rustdesk" ]; then
  if ! pgrep -x RustDesk >/dev/null 2>&1; then
    log "RustDesk not running — relaunching"
    gui_run open -a RustDesk || true
    sleep 5
  fi

  log "checking RustDesk on TCP $RUSTDESK_PORT ..."
  if wait_for 30 port_open "$RUSTDESK_PORT"; then
    ok "RustDesk is listening on TCP $RUSTDESK_PORT"
  else
    warn "RustDesk NOT listening on $RUSTDESK_PORT"
  fi

  # --- 3. get the ACTUAL RustDesk ID via CLI -------------------------------
  # RustDesk --get-id prints the real ID RustDesk resolved at startup.
  # This is more reliable than parsing RustDesk.toml (which may be encrypted).
  sleep 3  # give RustDesk time to fully initialize
  RD_ID="$(gui_run "$RUSTDESK_BIN" --get-id 2>/dev/null || echo '')"
  if [ -z "$RD_ID" ]; then
    # fallback: read from the toml (may be encrypted/overwritten)
    RD_TOML="$RUSTDESK_PREFS_DIR/RustDesk.toml"
    RD_ID="$(grep -oE "^id *= *'[^']*'" "$RD_TOML" 2>/dev/null | head -1 | sed "s/^id *= *'//;s/'$//" || true)"
    if [ -z "$RD_ID" ] || [ "${RD_ID#00}" != "$RD_ID" ]; then
      RD_ID="$(cat "$STATE_DIR/rustdesk-id" 2>/dev/null || echo UNKNOWN)"
      warn "could not get RustDesk ID via CLI — using configured: $RD_ID"
    else
      ok "RustDesk ID from toml: $RD_ID"
    fi
  else
    ok "actual RustDesk ID (via --get-id): $RD_ID"
  fi
  echo "$RD_ID" > "$STATE_DIR/rustdesk-id"

  # password: always use plaintext from state file (toml may be encrypted)
  RD_PASS="$(cat "$STATE_DIR/rustdesk-password" 2>/dev/null || echo UNKNOWN)"
else
  log "remote_method=${REMOTE_METHOD} → skipping RustDesk verify + ID (not used for this method)"
fi

# --- 4. print connection info (always — method-appropriate fields) ---------
TS_IP="$(cat "$STATE_DIR/tailscale-ip" 2>/dev/null || echo UNKNOWN)"
TS_HOST="$(cat "$STATE_DIR/tailscale-hostname" 2>/dev/null || echo UNKNOWN)"
# Read the actual MAC_USER password from the state file (set by step 00)
MAC_PASS="$(grep '^MAC_USER_PASSWORD=' "$STATE_DIR/helper-user.env" 2>/dev/null | cut -d= -f2- || echo '<from secret>')"

if [ "${REMOTE_METHOD:-rustdesk}" = "rustdesk" ]; then
cat > "$STATE_DIR/connection-info.txt" <<EOF

==============================================================================
  THE APPLE PROJECT  —  macOS 15 runner
==============================================================================

  TRANSPORT ........ Tailscale (WireGuard, no relay)
  Tailscale IPv4 ... $TS_IP
  Tailscale host ... $TS_HOST

  RUSTDESK ......... direct-IP mode (NO rendezvous, NO relay)
  RustDesk port .... $RUSTDESK_PORT  (TCP)
  RustDesk ID ...... $RD_ID
  RustDesk password  $RD_PASS
    (connect via RustDesk client to $TS_IP:$RUSTDESK_PORT)
    (or enter just the IP:port in RustDesk's "Enter remote ID" field)

  SSH .............. ssh $MAC_USER@$TS_IP
  SSH password ..... $MAC_PASS
    (end session: ssh $MAC_USER@$TS_IP 'touch /tmp/apple-project/remote-done')

  macOS admin user . $MAC_USER (password: $MAC_PASS)
    (use this password for any macOS authentication prompts during install)
    (the GUI session runs as '$RUNNER_USER' — use $MAC_USER for sudo/passwords)

  Display .......... 1920x1080

==============================================================================
EOF
else
# moonlight / other — no RustDesk info; Sunshine PIN page printed by step 05
cat > "$STATE_DIR/connection-info.txt" <<EOF

==============================================================================
  THE APPLE PROJECT  —  macOS 15 runner  (remote_method=$REMOTE_METHOD)
==============================================================================

  TRANSPORT ........ Tailscale (WireGuard, no relay)
  Tailscale IPv4 ... $TS_IP
  Tailscale host ... $TS_HOST

  SSH .............. ssh $MAC_USER@$TS_IP
  SSH password ..... $MAC_PASS
    (end session: ssh $MAC_USER@$TS_IP 'touch /tmp/apple-project/remote-done')

  macOS admin user . $MAC_USER (password: $MAC_PASS)
    (use this password for any macOS authentication prompts during install)
    (the GUI session runs as '$RUNNER_USER' — use $MAC_USER for sudo/passwords)

  Display .......... 1920x1080  (set by Step 03)
  Dark mode ........ on  (set by Step 03 — reduces encoding work = lower latency)

  REMOTE METHOD .... $REMOTE_METHOD
    (RustDesk was NOT installed for this method — see Step 05 output for the
     Sunshine PIN page at http://$TS_IP:8080)

==============================================================================
EOF
fi

cat "$STATE_DIR/connection-info.txt"
ok "connection info written (method=${REMOTE_METHOD:-rustdesk})"
