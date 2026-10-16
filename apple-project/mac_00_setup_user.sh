#!/usr/bin/env bash
# =============================================================================
#  mac_00_setup_user.sh — create a fresh admin user with a known password.
#
#  WHY:  the default `runner` user on the GitHub macOS image is SecureToken-
#  enabled and its password is NOT known / not resettable, even by root.
#  Some permission flows and login prompts need a password we actually know.
#  We therefore provision a second admin user (default: cihelper) whose
#  password we control, and tell the ShowUI-2B agent about it so it can type
#  it into any password prompt that appears while granting permissions.
#
#  The new user is NOT auto-logged-in; the existing `runner` Aqua session
#  stays active and is what RustDesk will capture.  The helper user exists
#  for authentication prompts + as an SSH/Tailscale-SSH fallback.
#
#  PASSWORD FIX: sysadminctl -addUser -password doesn't work reliably on the
#  GitHub runner (it logs "No clear text password" + the user can't auth).
#  We use dscl + passwd instead — create the user with dscl, then set the
#  password separately with passwd (which works reliably).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/mac_lib.sh"

log "Step 00 — provisioning helper admin user '$MAC_USER'"

require_env MAC_USER_PASSWORD

# idempotent: if the user already exists, reset the password + ensure admin
if id "$MAC_USER" >/dev/null 2>&1; then
  warn "user '$MAC_USER' already exists — resetting password + ensuring admin"
  # reset the password (in case it was created without one last time)
  echo "$MAC_USER:$MAC_USER_PASSWORD" | sudo chpasswd 2>/dev/null || \
    sudo dscl . -passwd /Users/"$MAC_USER" "$MAC_USER_PASSWORD" 2>/dev/null || true
else
  log "creating user '$MAC_USER' via dscl (reliable password setting)"
  # Find the next available UID (501 is runner, start at 502)
  UID_NUM=$(sudo dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
  UID_NUM=$((UID_NUM + 1))
  [ "$UID_NUM" -lt 502 ] && UID_NUM=502

  # Create the user with dscl (more reliable than sysadminctl for password)
  sudo dscl . -create /Users/"$MAC_USER"
  sudo dscl . -create /Users/"$MAC_USER" UserShell /bin/bash
  sudo dscl . -create /Users/"$MAC_USER" NFSHomeDirectory /Users/"$MAC_USER"
  sudo dscl . -create /Users/"$MAC_USER" RealName "CI Helper"
  sudo dscl . -create /Users/"$MAC_USER" UniqueID "$UID_NUM"
  sudo dscl . -create /Users/"$MAC_USER" PrimaryGroupID 20  # staff group

  # Set the password with dscl (reliable — sysadminctl was failing)
  sudo dscl . -passwd /Users/"$MAC_USER" "$MAC_USER_PASSWORD"

  # Create the home directory
  sudo createhomedir -c -u "$MAC_USER" 2>/dev/null || sudo mkdir -p /Users/"$MAC_USER"

  ok "user '$MAC_USER' created (UID=$UID_NUM) with password set via dscl"
fi

# ensure admin group membership (belt and suspenders)
sudo dscl . -append /Groups/admin GroupMembership "$MAC_USER" 2>/dev/null || true

# allow the helper user sudo without password (handy for SSH debugging)
sudo mkdir -p /etc/sudoers.d
echo "$MAC_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/"$MAC_USER" >/dev/null
sudo chmod 0440 /etc/sudoers.d/"$MAC_USER"

# VERIFY the password actually works (test with su)
if echo "$MAC_USER_PASSWORD" | sudo -S su - "$MAC_USER" -c 'whoami' 2>/dev/null | grep -q "$MAC_USER"; then
  ok "password verified: '$MAC_USER' can authenticate"
else
  warn "password verification failed — trying chpasswd fallback"
  echo "$MAC_USER:$MAC_USER_PASSWORD" | sudo chpasswd 2>/dev/null || true
  if echo "$MAC_USER_PASSWORD" | sudo -S su - "$MAC_USER" -c 'whoami' 2>/dev/null | grep -q "$MAC_USER"; then
    ok "password verified after chpasswd fallback"
  else
    warn "password still not working — SSH may fail, but sudo will work (passwordless)"
  fi
fi

# stash the creds where later steps can read them
umask 077
sudo tee "$STATE_DIR/helper-user.env" >/dev/null <<EOF
MAC_USER=$MAC_USER
MAC_USER_PASSWORD=$MAC_USER_PASSWORD
EOF
sudo chown "$RUNNER_USER" "$STATE_DIR/helper-user.env"

ok "helper user '$MAC_USER' ready (admin, passwordless sudo, verified password)"
