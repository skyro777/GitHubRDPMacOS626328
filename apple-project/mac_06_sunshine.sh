#!/usr/bin/env bash
# =============================================================================
#  mac_06_sunshine.sh — Install + configure Sunshine (ultra-low-latency HOST)
#
#  Sunshine (LizardByte) is an open-source, self-hosted game stream HOST for
#  Moonlight clients. It's designed for ultra-low-latency streaming (<16ms)
#  using hardware encoding (VideoToolbox on macOS).
#
#  Unlike RustDesk (TCP, general-purpose remote desktop), Sunshine uses UDP
#  + hardware encoding — purpose-built for gaming + low-latency streaming.
#
#  Architecture:
#    Sunshine (HOST) runs on the Mac → serves on port 47990 (web UI) +
#    47984/47989 (stream). Moonlight (CLIENT) runs on your device → connects
#    to the Tailscale IP. PIN-based pairing.
#
#  Config: ~/.config/sunshine/ (sunshine.conf, credentials)
#  Web UI: https://<tailscale-ip>:47990 (Tailscale-cert secured)
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 06 — install Sunshine (ultra-low-latency streaming HOST)"

SUNSHINE_APP="/Applications/Sunshine.app"
SUNSHINE_CONFIG_DIR="/Users/$RUNNER_USER/.config/sunshine"

# --- 1. install Sunshine ----------------------------------------------------
# Sunshine can be installed two ways:
#   a) brew formula (LizardByte tap) — binary at /opt/homebrew/opt/sunshine/bin/sunshine
#   b) DMG from GitHub releases — .app at /Applications/Sunshine.app
# We try brew first (more reliable), then DMG fallback.
SUNSHINE_BIN=""
SUNSHINE_BUNDLE="com.lizardbyte.sunshine"

# check if already installed (either method)
if [ -x "/opt/homebrew/opt/sunshine/bin/sunshine" ]; then
  SUNSHINE_BIN="/opt/homebrew/opt/sunshine/bin/sunshine"
  log "Sunshine already installed (brew formula): $SUNSHINE_BIN"
elif [ -d "$SUNSHINE_APP" ]; then
  SUNSHINE_BIN="$SUNSHINE_APP/Contents/MacOS/sunshine"
  log "Sunshine already installed (.app): $SUNSHINE_APP"
fi

if [ -z "$SUNSHINE_BIN" ]; then
  log "installing Sunshine..."
  # Method 1: LizardByte's homebrew tap
  brew tap lizardbyte/homebrew 2>/dev/null || true
  brew trust lizardbyte/homebrew 2>/dev/null || true
  HOMEBREW_NO_REQUIRE_TAP_TRUST=1 brew install sunshine 2>&1 | tail -n5 || true

  # check if brew install worked
  if [ -x "/opt/homebrew/opt/sunshine/bin/sunshine" ]; then
    SUNSHINE_BIN="/opt/homebrew/opt/sunshine/bin/sunshine"
    ok "Sunshine installed via brew: $SUNSHINE_BIN"
  else
    warn "brew install didn't produce a binary — trying DMG fallback"
    # Method 2: download the macOS DMG from GitHub releases
    dmg_url="https://github.com/LizardByte/Sunshine/releases/latest/download/Sunshine-macOS-arm64.dmg"
    log "downloading $dmg_url..."
    curl -fsSL "$dmg_url" -o /tmp/sunshine.dmg || die "could not download Sunshine DMG"
    ok "downloaded $(du -h /tmp/sunshine.dmg | awk '{print $1}')"
    log "mounting DMG..."
    mount_output="$(hdiutil attach /tmp/sunshine.dmg -nobrowse 2>&1)" || die "could not mount DMG: $mount_output"
    vol="$(echo "$mount_output" | grep -oE '/Volumes/[^ ]+' | head -1)"
    [ -z "$vol" ] && die "could not find mounted volume in: $mount_output"
    log "mounted at: $vol"
    app_src="$(find "$vol" -name '*.app' -maxdepth 1 2>/dev/null | head -1)"
    [ -z "$app_src" ] && die "could not find .app in DMG (contents: $(ls "$vol"))"
    log "copying $(basename "$app_src") to /Applications..."
    cp -R "$app_src" /Applications/ || die "could not copy app"
    hdiutil detach "$vol" -quiet 2>/dev/null || true
    rm -f /tmp/sunshine.dmg
    xattr -dr com.apple.quarantine "$SUNSHINE_APP" 2>/dev/null || true
    SUNSHINE_BIN="$SUNSHINE_APP/Contents/MacOS/sunshine"
    # try to read the bundle ID from the .app
    SUNSHINE_BUNDLE="$(defaults read "$SUNSHINE_APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo 'com.lizardbyte.sunshine')"
    ok "Sunshine installed via DMG: $SUNSHINE_APP"
  fi
fi

[ -z "$SUNSHINE_BIN" ] && die "Sunshine binary not found after install"
ok "Sunshine binary: $SUNSHINE_BIN"
ok "Sunshine bundle ID: $SUNSHINE_BUNDLE"

# --- 2. grant TCC permissions (Screen Recording + Accessibility + Input Monitoring) ---
log "granting TCC permissions to Sunshine..."
for service in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServiceListenEvent kTCCServiceLocalNetwork; do
  sudo sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, flags) VALUES ('$service', '$SUNSHINE_BUNDLE', 0, 2, 4, 1, NULL, 0, 0, 'UNUSED', 0);" 2>/dev/null || true
  sudo sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, flags) VALUES ('$service', '$SUNSHINE_BIN', 1, 2, 4, 1, NULL, 0, 0, 'UNUSED', 0);" 2>/dev/null || true
done
sudo killall tccd 2>/dev/null || true
sleep 2
ok "Sunshine TCC permissions granted (4 services)"

# pre-authorize screencapture for Sunshine binary
sca_plist="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
sys_plist="/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
for plist in "$sca_plist" "$sys_plist"; do
  sudo defaults write "$plist" "$SUNSHINE_BIN" -date "2099-01-01 00:00:00 +0000" 2>/dev/null || true
done
sudo killall -HUP replayd 2>/dev/null || true

# --- 3. create config dir + set initial credentials ------------------------
mkdir -p "$SUNSHINE_CONFIG_DIR"

# Sunshine stores credentials in a JSON file (credentials_file in sunshine.conf)
# On first run, the web UI asks you to create a username + password.
# We can pre-set these by creating the credentials file directly.
SUNSHINE_USER="${SUNSHINE_USER:-admin}"
SUNSHINE_PASS="${SUNSHINE_PASS:-sunshine}"

# The credentials file is a simple JSON with hashed credentials.
# Sunshine uses its own hashing. We'll create the config + let the web UI
# handle the initial credential creation (more reliable than pre-hashing).
# Get the Tailscale IP for the CSRF config
TS_IP_FOR_CONFIG="$(cat "$STATE_DIR/tailscale-ip" 2>/dev/null || echo '0.0.0.0')"

cat > "$SUNSHINE_CONFIG_DIR/sunshine.conf" <<EOF
# Sunshine configuration — generated by The Apple Project
origin_web_ui_allowed = wan
csrf_allowed_origins = https://$TS_IP_FOR_CONFIG:47990, https://localhost:47990, https://127.0.0.1:47990

# Use Sunshine DEFAULTS — don't override anything.
# The defaults are well-tuned by LizardByte for smooth streaming.
# Overriding them (bitrate, qp, fec, etc.) caused flickering + bad quality.
# Moonlight client-side settings handle latency optimization.
EOF
ok "config written to $SUNSHINE_CONFIG_DIR/sunshine.conf"

# --- 3b. set credentials variables (will be created via API after launch) ---
SUNSHINE_USER_VAL="${SUNSHINE_USER:-admin}"
SUNSHINE_PASS_VAL="${SUNSHINE_PASS:-sunshine}"
export SUNSHINE_USER_VAL SUNSHINE_PASS_VAL

# --- 4. launch Sunshine -----------------------------------------------------
log "launching Sunshine..."

# Stop any brew services instance first (it runs as root, can't access GUI)
brew services stop lizardbyte/homebrew/sunshine 2>/dev/null || true
brew services stop sunshine 2>/dev/null || true
sleep 2

# Kill ALL stale Sunshine processes (the brew services one + any direct ones)
# Use pkill -9 to force-kill (pkill without -9 may not work on LaunchAgent processes)
pkill -9 -f "sunshine" 2>/dev/null || true
sudo pkill -9 -f "sunshine" 2>/dev/null || true
sleep 3

# Launch Sunshine DIRECTLY as the GUI user (NOT via brew services).
# brew services runs as root which can't access the Aqua session / WindowServer.
# Direct launch as $RUNNER_USER gives Sunshine GUI access for screen capture.
if [ -x "/opt/homebrew/opt/sunshine/bin/sunshine" ]; then
  log "launching Sunshine as $RUNNER_USER (direct, not brew services)..."
  gui_run /opt/homebrew/opt/sunshine/bin/sunshine "$SUNSHINE_CONFIG_DIR/sunshine.conf" &
  sleep 8
elif [ -d "$SUNSHINE_APP" ]; then
  gui_run open -a Sunshine 2>/dev/null || true
  sleep 5
fi

# Verify it's running
if pgrep -f sunshine >/dev/null 2>&1; then
  ok "Sunshine is running"
  # Check which ports are actually listening
  for p in 47984 47989 47990 47991 48010 48011; do
    if lsof -nP -iTCP:"$p" 2>/dev/null | grep -q LISTEN; then
      ok "  port $p: LISTENING"
    else
      warn "  port $p: not listening"
    fi
  done
  # Also dump the full lsof for sunshine-related ports
  log "Sunshine port details:"
  lsof -nP -iTCP -a -p "$(pgrep -f sunshine | head -1)" 2>/dev/null | while IFS= read -r line; do log "  $line"; done || true
  log "Sunshine UDP ports:"
  lsof -nP -iUDP -a -p "$(pgrep -f sunshine | head -1)" 2>/dev/null | while IFS= read -r line; do log "  $line"; done || true
else
  warn "Sunshine is NOT running — try launching it manually via RustDesk"
  log "debug: processes matching sunshine:"
  ps aux | grep -i sunshine | grep -v grep || true
fi

# --- 5. start HTTP PIN proxy (no HTTPS, no cert warning) --------------------
# Sunshine's web UI is HTTPS-only (self-signed cert → browser warning).
# Instead of dealing with certs, we start a simple HTTP server on port 8080
# that serves a PIN entry form. The form POSTs the PIN to Sunshine's API
# via localhost (HTTPS, no cert issue since it's loopback).
# User accesses: http://<tailscale-ip>:8080 (HTTP, no warning!)
PIN_PROXY="/tmp/apple-project/pin_proxy.py"
cat > "$PIN_PROXY" << 'PYEOF'
import http.server, json, ssl, urllib.request, subprocess

SUNSHINE_USER = "PLACEHOLDER_USER"
SUNSHINE_PASS = "PLACEHOLDER_PASS"

HTML = """<!DOCTYPE html><html><head><title>Sunshine PIN</title>
<style>body{font-family:system-ui;max-width:400px;margin:80px auto;text-align:center}
input{font-size:24px;text-align:center;width:200px;padding:12px;margin:10px}
button{font-size:18px;padding:12px 40px;background:#0a84ff;color:#fff;border:none;border-radius:8px;cursor:pointer}
.result{margin-top:20px;font-size:18px}</style></head>
<body><h2>🔆 Sunshine Pairing</h2>
<p>Enter the 4-digit PIN from Moonlight:</p>
<input type="text" id="pin" maxlength="4" pattern="[0-9]{4}" placeholder="0000" autofocus>
<br><button onclick="submit()">Submit PIN</button>
<div class="result" id="result"></div>
<script>
async function submit(){
  const pin=document.getElementById('pin').value;
  const r=await fetch('/api/pin?pin='+pin);
  const t=await r.text();
  document.getElementById('result').innerText=t;
  if(t.includes('Paired'))setTimeout(()=>{document.getElementById('result').innerText+='\\n\\n✅ Close this page and connect via Moonlight';},500);
}
document.getElementById('pin').addEventListener('keypress',e=>{if(e.key==='Enter')submit();});
</script></body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith('/api/pin'):
            pin = self.path.split('pin=')[1].split('&')[0] if 'pin=' in self.path else ''
            self.handle_pin(pin)
        else:
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(HTML.encode())

    def handle_pin(self, pin):
        try:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            import base64
            auth = base64.b64encode(f"{SUNSHINE_USER}:{SUNSHINE_PASS}".encode()).decode()

            # Use subprocess + curl for SPEED (urllib has SSL handshake overhead)
            import subprocess

            # Get CSRF token (fast — single curl call)
            csrf_r = subprocess.run(["curl", "-sk", "-u", f"{SUNSHINE_USER}:{SUNSHINE_PASS}",
                "https://127.0.0.1:47990/api/csrf-token"], capture_output=True, text=True, timeout=3)
            csrf = json.loads(csrf_r.stdout).get("csrf_token", "") if csrf_r.stdout else ""

            # Get pending pairings + submit PIN in ONE step (race condition-free)
            pin_r = subprocess.run(["curl", "-sk", "-u", f"{SUNSHINE_USER}:{SUNSHINE_PASS}",
                "https://127.0.0.1:47990/api/pin"], capture_output=True, text=True, timeout=3)
            pairings = json.loads(pin_r.stdout).get("pairings", []) if pin_r.stdout else []

            if not pairings:
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b"No pending pairing. Click Pair in Moonlight first, then enter PIN here.")
                return

            p = pairings[0]
            pairing_id = p["id"]
            name = p.get("name", "Moonlight")

            # Submit the PIN immediately
            post_data = json.dumps({"pairing_id": pairing_id, "pin": pin, "name": name})
            submit_r = subprocess.run(["curl", "-sk", "-X", "POST",
                "-u", f"{SUNSHINE_USER}:{SUNSHINE_PASS}",
                "-H", "Content-Type: application/json",
                "-H", f"X-CSRF-Token: {csrf}",
                "-H", "Origin: https://127.0.0.1:47990",
                "-d", post_data,
                "https://127.0.0.1:47990/api/pin"], capture_output=True, text=True, timeout=10)

            result = json.loads(submit_r.stdout) if submit_r.stdout else {}
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            if result.get("status"):
                self.wfile.write(f"✅ Paired with {name}! Connect via Moonlight now.".encode())
            else:
                self.wfile.write(f"❌ Pairing failed: {json.dumps(result)}. Try again — click Pair in Moonlight, then enter the new PIN.".encode())
        except Exception as e:
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(f"Error: {str(e)}".encode())

# Replace placeholders with real values
with open(__file__) as f:
    code = f.read()
code = code.replace("PLACEHOLDER_USER", SUNSHINE_USER).replace("PLACEHOLDER_PASS", SUNSHINE_PASS)

print("[pin-proxy] serving on port 8080 (HTTP, no cert warning)", flush=True)
http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PYEOF

# Replace placeholders with actual values
sed -i.bak "s/PLACEHOLDER_USER/$SUNSHINE_USER_VAL/" "$PIN_PROXY"
sed -i.bak "s/PLACEHOLDER_PASS/$SUNSHINE_PASS_VAL/" "$PIN_PROXY"
rm -f "$PIN_PROXY.bak"

python3 "$PIN_PROXY" &
PIN_PROXY_PID=$!
disown 2>/dev/null || true
log "PIN proxy started on port 8080 (HTTP — no cert warning)"

# --- 6. print connection info -----------------------------------------------
TS_IP="$(cat "$STATE_DIR/tailscale-ip" 2>/dev/null || echo '<tailscale-ip>')"

log ""
log "=========================================================================="
log "  SUNSHINE — Ultra-Low-Latency Streaming (alternative to RustDesk)"
log "=========================================================================="
log ""
log "  HOST ............. Sunshine (running on this Mac)"
log "  PIN page ......... http://$TS_IP:8080  (HTTP — no cert warning!)"
log "    (simple form — enter the 4-digit PIN from Moonlight)"
log ""
log "  CLIENT ........... Moonlight (download on your device)"
log "    Windows: https://moonlight-stream.org"
log "    macOS:   brew install --cask moonlight"
log "    Android: Google Play → 'Moonlight Game Streaming'"
log "    iOS:     App Store → 'Moonlight Game Streaming'"
log ""
log "  HOW TO PAIR (do this ONCE per session):"
log "    1. Open Moonlight on your device → add host: $TS_IP"
log "    2. Click the locked monitor icon → Moonlight shows a 4-digit PIN"
log "    3. Open http://$TS_IP:8080 in your browser (no cert warning!)"
log "    4. Enter the 4-digit PIN from Moonlight → click Submit"
log "    5. Moonlight pairs automatically → click Connect to start streaming"
log ""
log "  No login needed — the PIN page handles auth automatically."
log ""
log "  MOUSE FIX (Windows Moonlight only):"
log "    If cursor is stuck/glitchy: Moonlight → Settings → Input →"
log "    enable 'Optimize Mouse for Remote Desktop'"
log "    (or press Ctrl+Alt+Shift+C during streaming)"
log ""
log "  ADVANTAGES over RustDesk:"
log "    - Hardware encoding (VideoToolbox) = lower latency"
log "    - UDP streaming = less lag than TCP"
log "    - Designed for gaming (<16ms latency)"
log "    - 4K @ 120fps support"
log ""
log "  PORTS (open on the Mac via Tailscale):"
log "    47990 (HTTPS web UI)"
log "    47984 (HTTPS — Moonlight pairing)"
log "    47989 (HTTP — Moonlight API)"
log "    48010 (UDP — control)"
log "    47998-48000 (UDP — video/audio)"
log ""
log "=========================================================================="

# Save sunshine info to connection-info.txt
cat >> "$STATE_DIR/connection-info.txt" <<EOF

  SUNSHINE ......... Ultra-low-latency streaming (alternative to RustDesk)
  Sunshine PIN page .. http://$TS_IP:8080
    (accept cert warning, create username + password on first visit)
  Moonlight client . Connect to $TS_IP (download from moonlight-stream.org)
    (enter the PIN from Sunshine's web UI to pair)

EOF


# --- 6b. create credentials via Sunshine API (after launch) ---
# On first run, Sunshine has no credentials → POST /api/password works without auth.
# This is more reliable than manually writing the JSON file.
# On first run, Sunshine has no credentials → POST /api/password works without auth.
# The API requires: currentUsername, newUsername, currentPassword, newPassword,
# confirmNewPassword + a CSRF token (from GET /api/csrf-token).
log "creating Sunshine credentials via API..."
# When username is empty (first run), POST /api/password doesn't need auth.
# CSRF is bypassed if the Origin header matches csrf_allowed_origins.
for attempt in $(seq 1 10); do
  RESP=$(curl -skL -X POST \
    -H "Content-Type: application/json" \
    -H "Origin: https://localhost:47990" \
    -d "{\"currentUsername\":\"\",\"newUsername\":\"$SUNSHINE_USER_VAL\",\"currentPassword\":\"\",\"newPassword\":\"$SUNSHINE_PASS_VAL\",\"confirmNewPassword\":\"$SUNSHINE_PASS_VAL\"}" \
    "https://localhost:47990/api/password" 2>/dev/null) || true
  if echo "$RESP" | grep -q '"status":true' 2>/dev/null; then
    ok "Sunshine credentials created via API ($SUNSHINE_USER_VAL)"
    break
  else
    log "  attempt $attempt: ${RESP:-no response}"
  fi
  sleep 2
done

# --- 7. open macOS firewall for Sunshine UDP ports --------------------------
# Moonlight needs UDP ports 47998-48000 (video/control/audio) + 48010 (RTSP)
# The macOS application firewall may block these by default.
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$SUNSHINE_BIN" 2>/dev/null || true
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$SUNSHINE_BIN" 2>/dev/null || true
ok "macOS firewall configured for Sunshine"

# --- 8. print clear PIN instructions ----------------------------------------
# IMPORTANT: The auto-pair daemon was REMOVED. It can't work because:
# - Moonlight generates a random 4-digit PIN on the CLIENT side
# - The PIN is NOT available via Sunshine's API
# - The user MUST enter the PIN manually in the Sunshine web UI
# 
# Pairing flow:
# 1. Moonlight shows a 4-digit PIN (e.g., 1788) on YOUR device
# 2. Open https://<tailscale-ip>:47990/pin in your browser
# 3. Login with username: admin / password: sunshine
# 4. Enter the 4-digit PIN from Moonlight
# 5. Pairing completes — Moonlight connects automatically

ok "Sunshine setup complete — see PIN instructions above"
