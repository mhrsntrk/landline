#!/bin/bash
# Record the App Store preview videos.
#
#   ios/screenshots/record.sh            both devices
#   ios/screenshots/record.sh iphone     one device
#
# Writes the finished previews into the upload tree beside the stills:
#   ios/screenshots/<locale>/<slot>/preview.mp4
#
# The motion is real. The session on screen is a real `landlined` session on a
# real tmux server on this machine, the output is a real `cargo test`, and the
# taps are real mouse events posted at the simulator window, which the device
# delivers as touches. See docs/SCREENSHOTS.md.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/simctl.sh"

WHICH="${1:-all}"
WORK=/tmp/landline-shots
TAP="$WORK/tap"

mkdir -p "$WORK" "$RAW/video"

# --- tapping ----------------------------------------------------------------

build_tap() { swiftc -O -o "$TAP" "$SHOTS/lib/tap.swift"; }

# "x y w h" of the device *screen*, in screen points.
#
# Not the window's own bounds: the window is wider than the glass it holds and
# carries a toolbar, so mapping fractions onto it lands every tap in the wrong
# place. The screen is the window's `group` child, and its size is the device's
# point size exactly (440x956 on this phone), which is also the check that this
# found the right element.
win_bounds() { # window-prefix
  osascript <<EOF
tell application "System Events" to tell process "Simulator"
  set w to first window whose name starts with "$1"
  set g to first group of w
  set p to position of g
  set s to size of g
  return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ¬
         ((item 1 of s) as text) & " " & ((item 2 of s) as text)
end tell
EOF
}

# Tap a point given as fractions of the device screen, which is how every
# coordinate in this file is written: the window is scaled by whatever the
# operator last left the simulator at, and fractions survive that.
tap_at() { # window-prefix u v [hold]
  local b u v hold x y w h
  # The simulator only forwards a click to the device when it is the active
  # app, and a click on an inactive window is spent activating it. Asserting it
  # before every tap is cheap and is the difference between a take where the
  # taps land and one where the app never leaves the first screen. It costs
  # nothing on camera: `recordVideo` captures the device framebuffer, not the
  # desktop.
  osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1 || true
  b=$(win_bounds "$1")
  read -r x y w h <<<"$b"
  u="$2"; v="$3"; hold="${4:-0.06}"
  "$TAP" \
    "$(python3 -c "print($x + $w * $u)")" \
    "$(python3 -c "print($y + $h * $v)")" \
    "$hold"
}

# --- the demo machine -------------------------------------------------------

# Window 2 holds a second real screen for the leader keys to switch to. It is
# deliberately not a tail of the demo daemon's own log: that log prints the
# harness listener, the `dev@local` bypass identity and the scratch HOME this
# run works in, which is exactly the debug detail a store video may not show.
dress_session() { # the shape both takes start from
  tm rename-window -t landline:1 test
  tm new-window -d -t landline: -n git -c "$DEMO_HOME/src/landline"
  tm new-window -d -t landline: -n dev -c "$DEMO_HOME/src/landline"
  tm send-keys -t landline:git 'clear; git log --oneline -30' Enter
  tm send-keys -t landline:test 'cd ~/src/landline && clear' Enter
  sleep 1
  tm send-keys -t landline:test 'cargo test -p landline-proto --lib roundtrip' Enter
  sleep 14
  tm clear-history -t landline:test
  tm clear-history -t landline:git
}

tm() { dtmux "$@" >/dev/null 2>&1 || true; }

# --- takes ------------------------------------------------------------------

record_iphone() {
  local udid="$IPHONE_UDID" win="$IPHONE_WINDOW" mov="$WORK/iphone.mov"

  dtmux kill-server >/dev/null 2>&1 || true
  # Pass one dresses the session at the phone's own geometry.
  reinstall "$udid"; status_bar "$udid"
  SIMCTL_CHILD_LANDLINE_DEMO=live \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  wait_for_session 20
  ensure_no_soft_keyboard "$win" "$udid"
  dress_session
  tm select-window -t landline:test

  # Pass two starts on the index, so the take opens on the choice the app is
  # about: which machine.
  reinstall "$udid"; status_bar "$udid"
  SIMCTL_CHILD_LANDLINE_DEMO=fullindex \
    SIMCTL_CHILD_LANDLINE_DEMO_KEYBAR=tmux \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  sleep 6
  raise_window "$win"

  rm -f "$mov"
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$mov" &
  local rec=$!
  sleep 3.5

  tap_at "$win" 0.30 0.183          # studio, the first row
  sleep 2
  tm send-keys -t landline:test 'cargo test -p landline-proto --lib' Enter
  sleep 9
  tap_at "$win" 0.25 0.945          # LDR, arm the leader
  sleep 1.6
  tap_at "$win" 0.55 0.945          # L2, the second tmux window
  sleep 6

  kill -INT $rec 2>/dev/null || true
  wait $rec 2>/dev/null || true
  encode "$mov" "$RAW/video/iphone.mp4" 886 1920 22
}

record_ipad() {
  local udid="$IPAD_UDID" win="$IPAD_WINDOW" mov="$WORK/ipad.mov"

  dtmux kill-server >/dev/null 2>&1 || true
  reinstall "$udid"; status_bar "$udid"
  SIMCTL_CHILD_LANDLINE_DEMO=live \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  wait_for_session 20
  ensure_no_soft_keyboard "$win" "$udid"
  dress_session
  tm select-window -t landline:test

  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  raise_window "$win"

  # Launch first, record second: starting the recorder before the app puts a
  # second and a half of the iOS home screen at the head of the take.
  SIMCTL_CHILD_LANDLINE_DEMO=liveresize \
    SIMCTL_CHILD_LANDLINE_DEMO_KEYBAR=tmux \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  sleep 2.5
  rm -f "$mov"
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$mov" &
  local rec=$!
  # `liveresize` collapses the index column six seconds after launch and brings
  # it back eight seconds later, which is the one thing on an iPad a still
  # cannot show. Both moments land inside this take.
  sleep 4
  tm send-keys -t landline:test 'cargo test -p landline-proto --lib' Enter
  sleep 11
  tap_at "$win" 0.4625 0.966        # LDR
  sleep 1.6
  tap_at "$win" 0.6500 0.966        # L2
  sleep 6

  kill -INT $rec 2>/dev/null || true
  wait $rec 2>/dev/null || true
  encode "$mov" "$RAW/video/ipad.mp4" 1200 1600 21
}

# --- encode -----------------------------------------------------------------

# Apple rejects a preview with no audio stream at all, so a silent AAC track is
# mapped in rather than the video shipping bare. Trimmed to 25s from the first
# frame; the head is already the index, so there is nothing to cut off the front.
encode() { # src dst width height [seconds]
  local src="$1" dst="$2" w="$3" h="$4"
  ffmpeg -y -loglevel error \
    -i "$src" \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
    -t "${5:-24}" \
    -vf "scale=${w}:-2:flags=lanczos,crop=${w}:${h}" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -r 30 -crf 20 \
    -c:a aac -b:a 128k -shortest \
    -movflags +faststart "$dst"
}

case "$WHICH" in
  iphone) build_tap; write_demo_home; start_daemon; record_iphone ;;
  ipad)   build_tap; write_demo_home; start_daemon; record_ipad ;;
  all)    build_tap; write_demo_home; start_daemon; record_iphone; record_ipad ;;
  *) echo "usage: record.sh [iphone|ipad|all]" >&2; exit 2 ;;
esac

echo "previews in $RAW/video"
