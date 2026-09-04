#!/bin/bash
# Shared plumbing for the store-screenshot run. Sourced by capture.sh.
#
# Nothing here touches the real daemon on 127.0.0.1:7777 or the operator's own
# tmux server: the demo machine is a throwaway HOME with its own landlined on
# 7788 and its own tmux socket, and every path below is derived from $DEMO_HOME.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SHOTS="$REPO_ROOT/ios/screenshots"
RAW="$SHOTS/raw"

IPHONE_UDID="${IPHONE_UDID:-BC8D7246-C964-4480-863F-9012BB12B1F6}"
IPAD_UDID="${IPAD_UDID:-E7FA1587-69DD-4D9B-ACA3-5903677FF1D0}"
IPHONE_WINDOW="${IPHONE_WINDOW:-iPhone 16 Pro Max}"
IPAD_WINDOW="${IPAD_WINDOW:-iPad Pro 13-inch (M4)}"

BUNDLE_ID="com.landlineclient.app"

# The tailnet name the live demo seed prints, and where it actually dials.
# See `Host.demoEndpoint`.
DEMO_DISPLAY_HOST="studio.tail4f1a.ts.net"

# The demo machine. Short on purpose: a unix socket path is capped at ~104
# bytes and tmux and landlined both put one under here.
DEMO_HOME="${DEMO_HOME:-/tmp/landline-shots/home}"
DEMO_PORT="${DEMO_PORT:-7788}"
DEMO_TMUX_SOCKET="landlinedemo"
export TMUX_TMPDIR="/tmp/landline-shots/tmux"

TMUX_BIN="${TMUX_BIN:-$(command -v tmux)}"

dtmux() { TMUX_TMPDIR="$TMUX_TMPDIR" "$TMUX_BIN" -L "$DEMO_TMUX_SOCKET" "$@"; }

# --- app bundle -------------------------------------------------------------

# Newest built simulator bundle, by mtime. Never `find | head -1`: stale
# DerivedData trees sort ahead of the one that was just built.
app_bundle() {
  find ~/Library/Developer/Xcode/DerivedData -name Landline.app \
       -path '*Debug-iphonesimulator*' -maxdepth 5 -exec stat -f '%m %N' {} \; \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# --- simulator --------------------------------------------------------------

# The I/O menu applies to the *frontmost* device window, so a run that does not
# raise the right one silently toggles the keyboard on the other simulator.
raise_window() {
  osascript >/dev/null 2>&1 <<EOF || true
tell application "Simulator" to activate
tell application "System Events" to tell process "Simulator"
  repeat with w in windows
    if name of w starts with "$1" then perform action "AXRaise" of w
  end repeat
end tell
EOF
  sleep 1
}

click_keyboard_menu() {
  osascript >/dev/null 2>&1 <<EOF || true
tell application "System Events" to tell process "Simulator" to click menu item "$1" ¬
  of menu 1 of menu item "Keyboard" of menu 1 of menu bar item "I/O" of menu bar 1
EOF
}

# The software keyboard eats 40% of a phone frame and is the most generic
# surface iOS has. Connecting the hardware keyboard hides it and leaves the
# app's own key bar on screen, which is the row worth photographing.
#
# The menu mark is global while the effect is per device window, so the state
# is cycled off and on with the target window raised, which is what makes the
# window pick it up. Verified by the row count of the attached tmux client, not
# by the menu's tick.
hardware_keyboard() {
  raise_window "$1"
  click_keyboard_menu "Connect Hardware Keyboard"
  sleep 1
  click_keyboard_menu "Connect Hardware Keyboard"
  sleep 2
}

# Is the software keyboard on screen? Asked of the pixels, not of the menu tick
# and not of the tmux client's row count: both have been seen to disagree with
# what is actually drawn. The keyboard is a light grey slab in an otherwise
# ink-dark app, so the mean luminance of the band it occupies separates the two
# states by a wide margin (about 78 against about 44).
soft_keyboard_visible() { # udid
  local probe="/tmp/landline-shots/kbprobe.png"
  shoot "$1" "$probe" || return 1
  python3 - "$probe" <<'PY'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L")
w, h = im.size
band = im.crop((0, int(h * 0.76), w, int(h * 0.95)))
sys.exit(0 if ImageStat.Stat(band).mean[0] > 60 else 1)
PY
}

# Call after a live launch: cycles the hardware-keyboard setting until the
# pixels say the software keyboard is gone.
ensure_no_soft_keyboard() { # window-prefix udid
  local try
  for try in 1 2 3 4; do
    soft_keyboard_visible "$2" || return 0
    hardware_keyboard "$1"
  done
  echo "warning: software keyboard still on screen for $1" >&2
}

status_bar() {
  xcrun simctl status_bar "$1" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3
}

# Reinstall rather than relaunch: the seeded hosts and the resumable session id
# both live in the container, and a leftover session id makes the app attach
# twice, which leaves two tmux clients of different sizes on one session and
# draws an empty screen.
reinstall() {
  xcrun simctl terminate "$1" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$1" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$1" "$(app_bundle)"
}

shoot() { xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1; }

# Is the leader latch armed in this frame? An armed latch fills its cell with
# the accent (#61AFEF), the only saturated blue anywhere near the key bar.
# Asked of the pixels because nothing outside the app can see the latch: it is
# cleared by a reconnect and spent by the emulator's own replies, and both
# happen without a trace on this side.
armed_in() { # png x0 y0 x1 y1  (fractions of the frame)
  python3 - "$@" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
x0, y0, x1, y1 = (float(v) for v in sys.argv[2:6])
# A box, not a point: a single sample lands on a glyph as often as on the fill.
box = im.crop((int(w * x0), int(h * y0), int(w * x1), int(h * y1)))
hits = sum(1 for r, g, b in list(box.getdata()) if b > 200 and 140 < g < 210 and r < 140)
sys.exit(0 if hits > box.width * box.height * 0.5 else 1)
PY
}

# Resume the session that was just dressed, this time with the leader armed,
# and keep the frame only once the latch is actually in the pixels. Resumed
# rather than launched fresh, because the latch is armed a beat after the attach
# settles and anything typed at the session in between spends it.
launch_with_armed_leader() { # udid outfile x0 y0 x1 y1
  local udid="$1" out="$2" try
  shift 2
  for try in 1 2 3; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 1
    SIMCTL_CHILD_LANDLINE_DEMO=liveleader \
      SIMCTL_CHILD_LANDLINE_DEMO_KEYBAR=tmux \
      SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
      xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
    sleep 6
    shoot "$udid" "$out"
    if armed_in "$out" "$@"; then return 0; fi
  done
  echo "warning: leader latch never armed on $udid" >&2
}

# --- demo machine -----------------------------------------------------------

write_demo_home() {
  mkdir -p "$DEMO_HOME/bin" "$DEMO_HOME/Library/Application Support/landline" "$TMUX_TMPDIR"
  cp "$SHOTS/demo/zshrc" "$DEMO_HOME/.zshrc"
  cp "$SHOTS/demo/tmux.conf" "$DEMO_HOME/.tmux.conf"
  # Every tmux the demo shell runs goes to the demo socket, so the operator's
  # own server is never touched even though the UID is the same.
  cat > "$DEMO_HOME/bin/tmux" <<EOF
#!/bin/sh
exec "$TMUX_BIN" -L $DEMO_TMUX_SOCKET "\$@"
EOF
  chmod +x "$DEMO_HOME/bin/tmux"
  cat > "$DEMO_HOME/Library/Application Support/landline/config.toml" <<EOF
listen = "127.0.0.1:$DEMO_PORT"
allowed_logins = []
shell = "/bin/zsh"
default_cmd = ""
session_ttl_hours = 24
scrollback_bytes = 262144
max_sessions = 8
unlock_hash = ""
EOF
  # A real checkout, so the session on screen runs real commands against real
  # code rather than echoing a script.
  if [ ! -d "$DEMO_HOME/src/landline/.git" ]; then
    mkdir -p "$DEMO_HOME/src"
    git clone -q "file://$REPO_ROOT" "$DEMO_HOME/src/landline"
  fi
  git -C "$DEMO_HOME/src/landline" config core.pager cat
}

start_daemon() {
  pkill -f "target/debug/landlined serve" >/dev/null 2>&1 || true
  sleep 1
  HOME="$DEMO_HOME" nohup "$REPO_ROOT/target/debug/landlined" serve \
    > /tmp/landline-shots/daemon.log 2>&1 &
  sleep 2
}

stop_demo() {
  dtmux kill-server >/dev/null 2>&1 || true
  pkill -f "target/debug/landlined serve" >/dev/null 2>&1 || true
}

# Wait until the app's tmux client is attached and tall enough to be
# keyboard-free, so a frame is never shot mid-attach.
wait_for_session() {
  local want_rows="${1:-34}" tries=0
  while [ $tries -lt 30 ]; do
    local rows
    rows=$(dtmux list-clients -F '#{client_height}' 2>/dev/null | sort -rn | head -1 || true)
    if [ -n "$rows" ] && [ "$rows" -ge "$want_rows" ]; then return 0; fi
    sleep 1
    tries=$((tries + 1))
  done
  echo "warning: tmux client never reached $want_rows rows" >&2
}
