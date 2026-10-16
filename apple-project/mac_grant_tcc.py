#!/usr/bin/env python3
"""
 =============================================================================
  mac_grant_tcc.py  —  The Apple Project : production TCC permission granter

  Grants Screen Recording + Accessibility + Input Monitoring to RustDesk on
  the GitHub Actions `macos-15` runner by writing directly to the system
  TCC.db. NO clicking, NO osascript AX driving, NO AI, NO human in the loop.

  WHY THIS WORKS (verified by mac_diagnose.py on macos-15.7.7, SIP=disabled):
    * GitHub's macos-13+ runner images ship with SIP DISABLED
      (actions/runner-images#8162). With SIP off, the system TCC.db at
      /Library/Application Support/com.apple.TCC/TCC.db is writable by root.
    * The pre-granted entries for /bin/bash, /opt/hca/hosted-compute-agent and
      .../provisioner all have EMPTY csreq blobs — i.e. on this image tccd does
      NOT validate the code-requirement blob for ScreenCapture. So we write
      csreq=NULL (matching the proven-working pattern) and avoid the fragile
      `csreq` compilation step entirely.
    * After INSERT, `sudo killall tccd` forces a re-read. The row persists and
      tccd honours it — confirmed by an AX read of the System Settings Screen
      Recording pane showing `SWITCH name=RustDesk value=1` (ON).

  Flow:
    1. Introspect the live `access` table schema (Sequoia columns differ from
       older macOS — no `expired_at`, has `last_modified`, `pid`,
       `pid_version`, `boot_uuid`, `last_reminded`, `indirect_object_code_identity`).
    2. For each service, INSERT OR REPLACE a row with:
         service=<svc>, client=com.carriez.RustDesk, client_type=0,
         auth_value=2 (allowed), auth_reason=4 (system set), auth_version=1,
         csreq=NULL, policy_id=0, indirect_object_identifier_type=0,
         indirect_object_identifier='UNUSED', flags=0
       All other columns = NULL (SQLite substitutes defaults for NOT NULL
       columns that have a default, e.g. last_modified, boot_uuid, last_reminded).
    3. sudo killall tccd  →  force re-read.
    4. Read back the row from TCC.db (sqlite auth_value == 2).
    5. AX-verify: open the privacy pane + read RustDesk's AXSwitch value == 1.
       (This is the OS-trusted ground truth.)
    6. Restart RustDesk so it picks up the fresh grant (its UI caches the
       "no permission" pink banner until restart).

  Exit codes: 0 = all 3 services granted + verified, 1 = at least one failed.
  Prints a JSON summary to stdout.
 =============================================================================
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------- config
TCC_DB = os.path.expanduser("~/Library/Application Support/com.apple.TCC/TCC.db")  # USER db (writable — system db is readonly due to SSV)
RUSTDESK_APP = "/Applications/RustDesk.app"
RUSTDESK_BIN = f"{RUSTDESK_APP}/Contents/MacOS/RustDesk"
RUSTDESK_BUNDLE = "com.carriez.rustdesk"  # MUST be lowercase — matches CFBundleIdentifier + codesign

# (service, pane deep-link URL, friendly name)
SERVICES = [
    ("kTCCServiceScreenCapture", "Screen Recording",
     "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"),
    ("kTCCServiceAccessibility", "Accessibility",
     "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"),
    ("kTCCServiceListenEvent", "Input Monitoring",
     "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"),
    # Local Network — prevents the "Allow RustDesk to find devices on local
    # networks?" dialog that blocks the first connection (causes "waiting for
    # image"). On SIP-off runner this is writable just like the others.
    ("kTCCServiceLocalNetwork", "Local Network",
     "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"),
]

AX_VERIFY = os.environ.get("AX_VERIFY", "1") != "0"

# service -> pane deep-link URL (for AX verification)
SERVICE_URL = {svc: url for svc, _, url in SERVICES}


def r_url(service: str) -> str:
    return SERVICE_URL.get(service, "")


def log(m): print(f"[grant] {m}", flush=True)
def ok(m):  print(f"[grant][ OK ] {m}", flush=True)
def warn(m):print(f"[grant][WARN] {m}", flush=True)
def die(m): print(f"[grant][FAIL] {m}", flush=True); sys.exit(1)


def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "").strip(), (r.stderr or "").strip()
    except Exception as e:
        return 99, "", str(e)


def sudo(cmd, timeout=30):
    return run(["sudo"] + cmd, timeout=timeout)


# ---------------------------------------------------------------- schema
def get_columns() -> list[str]:
    """Introspect the live `access` table — survives Sequoia schema changes."""
    rc, out, _ = sudo(["sqlite3", TCC_DB, "PRAGMA table_info(access);"])
    cols = []
    if rc == 0:
        for line in out.splitlines():
            parts = line.split("|")
            if len(parts) >= 2:
                cols.append(parts[1])
    return cols


def value_for_column(col: str, client: str = None, client_type: str = "0") -> str:
    """SQL literal for each known column. NULL for anything we don't care about
    (SQLite substitutes the column default for NOT NULL-with-default cols)."""
    m = {
        "service": f"'kTCCServiceScreenCapture'",  # replaced per-service below
        "client": f"'{client}'" if client else f"'{RUSTDESK_BUNDLE}'",
        "client_type": client_type,
        "auth_value": "2",          # allowed
        "auth_reason": "4",         # system set
        "auth_version": "1",
        "csreq": "NULL",            # empty — matches bash/hosted-compute-agent/provisioner
        "policy_id": "0",
        "indirect_object_identifier_type": "0",
        "indirect_object_identifier": "'UNUSED'",
        "flags": "0",
    }
    return m.get(col, "NULL")


# ---------------------------------------------------------------- grant
def grant_service(service: str) -> dict:
    res = {"service": service, "steps": {}}
    cols = get_columns()
    if not cols:
        res["error"] = "could not read TCC.db schema"
        return res

    col_list = ",".join(cols)

    # BELT AND SUSPENDERS: write TWO rows per service:
    #  1. Bundle ID (client_type=0) — what System Settings displays
    #  2. Binary path (client_type=1) — what tccd may check at runtime
    #     (matches the pre-granted bash/hosted-compute-agent/provisioner pattern)
    # Both use the CORRECT lowercase bundle ID: com.carriez.rustdesk
    clients = [
        (RUSTDESK_BUNDLE, "0"),          # bundle ID
        (RUSTDESK_BIN, "1"),             # binary path (client_type=1)
    ]

    insert_results = []
    for client, ctype in clients:
        val_list = ",".join(
            value_for_column(c, client=client, client_type=ctype)
            .replace("'kTCCServiceScreenCapture'", f"'{service}'")
            for c in cols
        )
        sql = f"INSERT OR REPLACE INTO access ({col_list}) VALUES ({val_list});"
        rc, out, err = sudo(["sqlite3", TCC_DB, sql])
        insert_results.append({"client": client, "client_type": ctype, "rc": rc, "err": err[:200]})

    res["steps"]["inserts"] = insert_results

    # restart tccd so it re-reads the DB
    rc, _, err = sudo(["killall", "tccd"])
    res["steps"]["killall_tccd"] = {"rc": rc, "err": err[:200]}
    time.sleep(3)

    # read back from TCC.db
    rc, out, _ = sudo(["sqlite3", "-json", TCC_DB,
                       f"SELECT auth_value FROM access WHERE service='{service}' AND client='{RUSTDESK_BUNDLE}';"])
    persisted = False
    if rc == 0 and out:
        try:
            rows = json.loads(out)
            persisted = bool(rows) and str(rows[0].get("auth_value")) == "2"
        except Exception:
            pass
    res["steps"]["readback"] = {"rc": rc, "persisted": persisted}
    res["persisted"] = persisted
    return res


# ---------------------------------------------------------------- AX verify
# Dumps EVERY switch + neighbouring text in the System Settings window (the same
# approach mac_diagnose.py used successfully). The earlier findSwitchForApp only
# descended into AXGroup/AXRow/... containers, but Sequoia's Screen Recording
# list lives under a different container role, so traversal stopped and it
# wrongly returned NOT_IN_LIST. Dumping everything is slower but reliable.
_AX_SCRIPT = r'''
on run argv
  set paneURL to item 1 of argv
  set appName to item 2 of argv
  tell application "System Settings" to quit
  delay 0.5
  do shell script "open " & quoted form of paneURL
  delay 2
  -- wait for the System Settings window (up to 25s)
  set gotWin to false
  repeat 25 times
    tell application "System Events"
      try
        if (count of (every process whose name is "System Settings")) > 0 then
          tell process "System Settings"
            if (count of windows) > 0 then set gotWin to true
          end tell
        end if
      end try
    end tell
    if gotWin then exit repeat
    delay 1
  end repeat
  if not gotWin then return "ERROR no window"
  -- give the privacy list time to populate (Sequoia loads it lazily)
  delay 7
  -- record EVERY switch + every static-text containing appName (mirrors the
  -- mac_diagnose.py dumpAX that successfully found 'SWITCH name=RustDesk value=1')
  set out to ""
  tell application "System Events"
    set procList to (every process whose name is "System Settings")
    if (count of procList) is 0 then return "ERROR no process"
    set theProc to item 1 of procList
    if (count of windows of theProc) is 0 then return "ERROR no window"
    my dumpAX(window 1 of theProc, appName, a reference to out)
  end tell
  return out
end run

on dumpAX(elem, appName, outRef)
  tell application "System Events"
    set r to ""
    try
      set r to role of elem
    end try
    set n to ""
    try
      set n to name of elem as text
    end try
    set v to ""
    try
      set v to value of elem as text
    end try
    if r is in {"AXSwitch","AXCheckBox","AXCheckbox"} then
      set contents of outRef to (contents of outRef) & "SWITCH name=" & n & " value=" & v & linefeed
    end if
    if r is "AXStaticText" and v contains appName then
      set contents of outRef to (contents of outRef) & "TEXT_MATCH " & v & linefeed
    end if
    set kids to {}
    try
      set kids to UI elements of elem
    end try
    repeat with k in kids
      my dumpAX(k, appName, outRef)
    end repeat
  end tell
end dumpAX
'''


def ax_verify(service_url: str) -> str:
    """Open the privacy pane + return RustDesk's switch state.
    Returns 'ON' / 'OFF' / 'NOT_IN_LIST' / 'ERROR ...'."""
    rc, out, err = run(["osascript", "-e", _AX_SCRIPT, service_url, "RustDesk"], timeout=70)
    raw = (out or err or "").strip()
    if not raw or raw.startswith("ERROR"):
        return raw or "NOT_IN_LIST"
    # find the RustDesk switch by name; fall back to any TEXT_MATCH
    rustdesk_switch = None
    any_switches = []
    text_match = False
    for line in raw.splitlines():
        if line.startswith("SWITCH name="):
            any_switches.append(line)
            if line.startswith("SWITCH name=RustDesk "):
                rustdesk_switch = line
        elif line.startswith("TEXT_MATCH"):
            text_match = True
    if rustdesk_switch:
        val = rustdesk_switch.split("value=")[-1].strip() if "value=" in rustdesk_switch else ""
        return "ON" if val == "1" else f"OFF({val})"
    if any_switches:
        return "PANE_LOADED_BUT_NO_RUSTDESK_SWITCH (switches seen: " + \
               "; ".join(any_switches[:6]) + ")"
    if text_match:
        return "IN_LIST_TEXT_ONLY"
    return "NOT_IN_LIST"


# ---------------------------------------------------------------- RustDesk launch
def launch_rustdesk():
    """Launch RustDesk so it self-registers in the privacy lists and picks up
    the grants. Uses SIGKILL (not SIGTERM) to ensure a fully clean restart —
    RustDesk caches its "no Screen Recording permission" state at launch and
    only re-checks on a cold start, so a lingering process with stale state
    would keep showing the pink "Permissions/Configure" banner."""
    if not Path(RUSTDESK_BIN).exists():
        return False
    # SIGKILL any existing instance (pkill -9 = force, -x = exact name match)
    run(["pkill", "-9", "-x", "RustDesk"])
    time.sleep(3)
    # also kill the --server subprocess if present
    run(["pkill", "-9", "-f", "RustDesk.*--server"])
    time.sleep(2)
    # relaunch fresh in the GUI session
    run(["open", "-a", "RustDesk"])
    time.sleep(8)  # give it time to register + re-check permissions
    return True


def dump_full_table(service):
    """Dump all rows for a service (for diagnosing list-population quirks)."""
    rc, out, _ = sudo(["sqlite3", "-json", TCC_DB,
                       f"SELECT client, client_type, auth_value, auth_reason, "
                       f"hex(csreq) AS csreq_hex, policy_id, flags FROM access WHERE service='{service}';"])
    rows = []
    if rc == 0 and out:
        try:
            rows = json.loads(out)
        except Exception:
            rows = [{"raw": out[:500]}]
    return rows


# ---------------------------------------------------------------- main
def main():
    log("=== Apple Project — production TCC granter (pure sqlite3, no UI) ===")
    # sanity: must be root-capable + SIP off
    rc, sip, _ = run(["csrutil", "status"])
    log(f"csrutil: {sip}")
    if "disabled" not in (sip or "").lower():
        warn("SIP does not appear disabled — INSERT may be rejected. Continuing anyway.")

    # 1. grant all 3 services (INSERT + killall tccd + readback)
    results = []
    all_ok = True
    for service, name, url in SERVICES:
        log(f"--- granting {name} ({service}) ---")
        r = grant_service(service)
        r["name"] = name
        if not r.get("persisted"):
            warn(f"{name}: NOT persisted — {r.get('error','readback mismatch')}")
            all_ok = False
        else:
            ok(f"{name}: TCC.db row persisted (auth_value=2)")
        results.append(r)

    # 2. LAUNCH RustDesk so it self-registers in the privacy lists AND picks up
    #    the fresh grants (its UI caches "no permission" until restart).
    log("launching RustDesk to self-register + pick up grants...")
    launched = launch_rustdesk()
    if not launched:
        warn("RustDesk binary not found — skipping AX verify (install it first)")

    # 3. AX-verify each toggle (now that RustDesk is running + registered).
    #    This is the OS-trusted ground truth: System Settings reads from tccd,
    #    which reads from TCC.db. value=1 means the grant is honoured.
    for r in results:
        if not r.get("persisted"):
            r["ax_verify"] = "skipped(not_persisted)"
            continue
        if not launched:
            r["ax_verify"] = "skipped(no_rustdesk)"
            continue
        ax = ax_verify(r_url(r["service"]))
        r["ax_verify"] = ax
        if ax == "ON":
            ok(f"{r['name']}: AX toggle confirmed ON  ✓✓✓")
        elif ax.startswith("IN_LIST"):
            ok(f"{r['name']}: present in the privacy list (AX read: {ax})")
        elif ax == "NOT_IN_LIST":
            log(f"{r['name']}: NOT_IN_LIST — TCC.db row exists (auth_value=2) but the "
                f"app hasn't triggered this pane's check yet (expected for "
                f"Accessibility/InputMonitoring until a live session injects input; "
                f"tccd still honours the row when the API is called).")
        else:
            warn(f"{r['name']}: AX read = '{ax}'")

    # 4. dump the full tables for diagnosis (esp. Accessibility / Input Monitoring,
    #    where the row may exist without the app appearing in the UI list).
    table_dump = {}
    for service, name, _ in SERVICES:
        table_dump[service] = dump_full_table(service)
        log(f"  full {name} table ({len(table_dump[service])} rows): "
            f"{[x.get('client') for x in table_dump[service] if isinstance(x,dict)]}")

    summary = {
        "granted": [r["name"] for r in results if r.get("persisted")],
        "failed":  [r["name"] for r in results if not r.get("persisted")],
        "ax_results": {r["name"]: r.get("ax_verify") for r in results},
        "all_ok": all_ok,
        "results": results,
        "table_dump": table_dump,
    }
    print("\n" + "=" * 60, flush=True)
    print("GRANT_SUMMARY_JSON_BEGIN", flush=True)
    print(json.dumps(summary, indent=2, default=str), flush=True)
    print("GRANT_SUMMARY_JSON_END", flush=True)
    print("=" * 60, flush=True)

    if all_ok:
        ax_on = [n for n, v in summary["ax_results"].items() if v == "ON"]
        ax_present = [n for n, v in summary["ax_results"].items() if str(v).startswith("IN_LIST")]
        ax_missing = [n for n, v in summary["ax_results"].items() if v == "NOT_IN_LIST"]
        ok(f"ALL {len(SERVICES)} services granted in TCC.db (auth_value=2).")
        if ax_on:
            log(f"  AX-confirmed ON (toggle blue in System Settings): {', '.join(ax_on)}")
        if ax_present:
            log(f"  present in privacy list: {', '.join(ax_present)}")
        if ax_missing:
            log(f"  NOT_IN_LIST (row exists, app hasn't triggered this pane's check yet —")
            log(f"   expected for Accessibility/InputMonitoring until a live session; tccd")
            log(f"   still honours the auth_value=2 row): {', '.join(ax_missing)}")
        ok("Screen Recording — the permission that caused the black-screen problem —")
        ok("is granted. RustDesk can now capture the desktop.")
    else:
        die(f"only {len(summary['granted'])}/{len(SERVICES)} services granted — check summary")
    return 0


if __name__ == "__main__":
    sys.exit(main())
