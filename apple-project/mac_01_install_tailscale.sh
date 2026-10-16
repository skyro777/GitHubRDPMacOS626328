#!/usr/bin/env bash
# =============================================================================
#  mac_01_install_tailscale.sh
#  Install Tailscale via the Homebrew FORMULA, start tailscaled as a root
#  launchd LaunchDaemon via `brew services`, authenticate with an ephemeral
#  auth key, and publish the runner's Tailscale IPv4.
#
#  WHY THE HOME BREW FORMULA (not the .pkg, not the cask):
#     - The standalone .pkg installs a GUI .app whose CLI crashes with
#       "bundleIdentifier is unknown to the registry" under `sudo` (root's
#       LaunchServices context hasn't registered the bundle).  See Task 14.
#     - The Homebrew FORMULA (`brew install tailscale`) installs `tailscale`
#       + `tailscaled` as plain standalone binaries — no GUI app, no
#       LaunchServices, no bundle-identifier crash.
#
#  WHY `sudo brew services start tailscale` (not manual nohup):
#     - `brew services start` (with sudo) writes a proper LaunchDaemon plist
#       at /Library/LaunchDaemons/homebrew.mxcl.tailscale.plist that runs
#       tailscaled as ROOT with KeepAlive=true.  Root is required because
#       the formula's service block does NOT use --tun=userspace-networking,
#       so tailscaled opens a real kernel /dev/utun device.
#     - `sudo brew services` was re-enabled in Homebrew 2.1.1 (the "Homebrew
#       blocks sudo brew" rule only applies to install/upgrade/tap).
#     - The daemon listens on the DEFAULT socket /var/run/tailscaled.socket
#       (the formula passes NO flags to tailscaled), so the CLI finds it
#       automatically — no --socket override needed.
#
#  WHY WE DROP --ssh:
#     - The brew CLI build (1.94.2+, incl. 1.98.5) CANNOT act as a Tailscale
#       SSH server: the control plane now requires hardware attestation that
#       the brew build doesn't ship ("--hardware-attestation is not supported
#       on this platform or in this build of tailscaled").  Tailscale issue
#       #18957.  --ssh would make `tailscale up` fail.  We rely on RustDesk
#       for interactive access instead; the done-flag is touched via the Mac
#       Terminal inside the RustDesk session.
#
#  Tailscale is the ONLY transport.  No relay / rendezvous server is used
#  anywhere in this project — the RustDesk client dials the runner's Tailscale
#  IP directly on TCP 21118.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 01 — Tailscale install (Homebrew formula) + connect"

require_env TS_AUTHKEY

# --- 1. install via Homebrew formula ----------------------------------------
# `brew install tailscale`  → formula (CLI + tailscaled daemon)
# `brew install --cask tailscale` → GUI .app (we do NOT want this — it crashes)
if ! command -v tailscale >/dev/null 2>&1; then
  log "installing tailscale via Homebrew formula (not cask)"
  brew install tailscale
else
  ok "tailscale already on PATH"
fi

# Locate the CLI binary.  On Apple Silicon: /opt/homebrew/bin/tailscale
# (symlink to /opt/homebrew/opt/tailscale/bin/tailscale).
# On Intel: /usr/local/bin/tailscale.
TS_BIN="$(command -v tailscale)"
[ -x "$TS_BIN" ] || die "tailscale CLI not found on PATH after brew install"
ok "tailscale CLI: $TS_BIN  ($("$TS_BIN" version 2>/dev/null | head -n1))"

# --- 2. start tailscaled as a root LaunchDaemon via brew services ------------
# `sudo brew services start tailscale` writes
#   /Library/LaunchDaemons/homebrew.mxcl.tailscale.plist
# which runs  /opt/homebrew/opt/tailscale/bin/tailscaled  as root, KeepAlive=true.
# The formula's service block passes NO flags, so tailscaled uses:
#   - default TUN mode (real kernel /dev/utun device — bidirectional IP routing,
#     so inbound RustDesk on :21118 works)
#   - default socket  /var/run/tailscaled.socket  (the CLI looks here by default)
log "starting tailscaled as root LaunchDaemon via 'sudo brew services start'"
sudo brew services start tailscale

# --- 3. wait for the daemon to be ready -------------------------------------
# `tailscale status` returns non-zero + prints "Logged out." when the daemon
# is up but not yet authenticated.  That is the canonical readiness signal.
# We poll for up to 30 s.
log "waiting for tailscaled to be ready (polling 'tailscale status')..."
DAEMON_READY=false
for i in $(seq 1 30); do
  STATUS_OUT="$(sudo "$TS_BIN" status 2>&1 || true)"
  if echo "$STATUS_OUT" | grep -q "Logged out"; then
    DAEMON_READY=true
    break
  fi
  # also accept any non-empty status that isn't a connection error
  if echo "$STATUS_OUT" | grep -qiE "^(OS|user|version|netcheck|tailscale)" ; then
    DAEMON_READY=true
    break
  fi
  sleep 1
done
if [ "$DAEMON_READY" = "false" ]; then
  err "tailscaled did not become ready in 30 s.  Last 'tailscale status' output:"
  err "$STATUS_OUT"
  err "brew services info:"
  sudo brew services info tailscale 2>&1 | tail -n 20 || true
  die "tailscaled startup failed"
fi
ok "tailscaled is ready (status: $(echo "$STATUS_OUT" | head -n1))"

# --- 4. bring the runner onto the tailnet -----------------------------------
# A unique hostname per run makes the node easy to spot in the admin console.
HOSTNAME_TAG="gh-mac-${GITHUB_RUN_ID:-local}-$$"
log "tailscale up  (hostname=$HOSTNAME_TAG, ephemeral key, accept-routes)"
# --authkey      : non-interactive auth using the secret
# --hostname     : deterministic, findable name
# --accept-routes: honour any subnet routes advertised on the tailnet
# NOTE: --ssh is intentionally OMITTED — the brew CLI build cannot act as a
#       Tailscale SSH server (hardware-attestation requirement, issue #18957).
#       Interactive access is via RustDesk instead.
# NOTE: the auth key should be created as "reusable + ephemeral" so dead nodes
#       auto-expire when the job ends.
sudo "$TS_BIN" up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$HOSTNAME_TAG" \
    --accept-routes \
    --timeout=120s

# --- 5. capture the Tailscale IPv4 -----------------------------------------
TS_IP="$(sudo "$TS_BIN" ip -4 | head -n1)"
if [ -z "$TS_IP" ]; then
  die "could not determine Tailscale IPv4 (tailscale ip -4 empty)"
fi
echo "$TS_IP" > "$STATE_DIR/tailscale-ip"
echo "$HOSTNAME_TAG" > "$STATE_DIR/tailscale-hostname"
ok "runner is on the tailnet:"
ok "  Tailscale IPv4 : $TS_IP"
ok "  Tailscale host  : $HOSTNAME_TAG"
log "  (also written to $STATE_DIR/tailscale-ip)"

# Also expose as a step output if running inside GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tailscale_ip=$TS_IP" >> "$GITHUB_OUTPUT"
  echo "tailscale_host=$HOSTNAME_TAG" >> "$GITHUB_OUTPUT"
fi
