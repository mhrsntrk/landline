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

# "x y w h" of a simulator device window, in screen points.
win_bounds() { # window-prefix
  osascript <<EOF
tell application "System Events" to tell process "Simulator"
  repeat with w in windows
    if name of w starts with "$1" then
      set p to position of w
      set s to size of w
      return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ¬
             ((item 1 of s) as text) & " " & ((item 2 of s) as text)
    end if
  end repeat
end tell
EOF
}

# Tap a point given as fractions of the device screen, which is how every
# coordinate in this file is written: the window is scaled by whatever the
# operator last left the simulator at, and fractions survive that.
tap_at() { # window-prefix u v [hold]
  local b u v hold x y w h
  b=$(win_bounds "$1")
  read -r x y w h <<<"$b"
  u="$2"; v="$3"; hold="${4:-0.06}"
  "$TAP" \
    "$(python3 -c "print($x + $w * $u)")" \
    "$(python3 -c "print($y + $h * $v)")" \
    "$hold"
}

# --- the demo machine -------------------------------------------------------

# Window 2 tails the daemon's own log, so attaching and detaching during the
# take writes real lines onto the screen rather than a scripted crawl.
link_log() {
  mkdir -p "$DEMO_HOME/logs"
  ln -sf "$WORK/daemon.log" "$DEMO_HOME/logs/landlined.log"
}

dress_session() { # the shape both takes start from
  tm rename-window -t landline:1 test
  tm new-window -d -t landline: -n logs -c "$DEMO_HOME"
  tm new-window -d -t landline: -n dev -c "$DEMO_HOME/src/landline"
  tm send-keys -t landline:logs 'clear; tail -f ~/logs/landlined.log' Enter
  tm send-keys -t landline:test 'cd ~/src/landline && clear' Enter
  sleep 1
  tm send-keys -t landline:test 'cargo test -p landline-proto --lib roundtrip' Enter
  sleep 14
}

tm() { dtmux "$@" >/dev/null 2>&1 || true; }

# --- takes ------------------------------------------------------------------

record_iphone() {
  local udid="$IPHONE_UDID" win="$IPHONE_WINDOW" mov="$WORK/iphone.mov"

  dtmux kill-server >/dev/null 2>&1 || true
  link_log
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
  SIMCTL_CHILD_LANDLINE_DEMO=index \
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
  sleep 6
  tm send-keys -t landline:test 'cargo test -p landline-proto --lib' Enter
  sleep 8
  tap_at "$win" 0.25 0.945          # LDR, arm the leader
  sleep 1.6
  tap_at "$win" 0.55 0.945          # L2, go to window 2
  sleep 4
  tap_at "$win" 0.25 0.945          # LDR again
  sleep 1.4
  tap_at "$win" 0.45 0.945          # L1, back to the build
  sleep 3

  kill -INT $rec 2>/dev/null || true
  wait $rec 2>/dev/null || true
  encode "$mov" "$RAW/video/iphone.mp4" 886 1920
}

record_ipad() {
  local udid="$IPAD_UDID" win="$IPAD_WINDOW" mov="$WORK/ipad.mov"

  dtmux kill-server >/dev/null 2>&1 || true
  link_log
  reinstall "$udid"; status_bar "$udid"
  SIMCTL_CHILD_LANDLINE_DEMO=live \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  wait_for_session 20
  ensure_no_soft_keyboard "$win" "$udid"
  dress_session
  tm select-window -t landline:test

  # `liveresize` resumes the dressed session and then collapses the index
  # column six seconds in and brings it back eight seconds later, which is the
  # one thing on an iPad that a still cannot show.
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  raise_window "$win"

  rm -f "$mov"
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$mov" &
  local rec=$!
  sleep 1
  SIMCTL_CHILD_LANDLINE_DEMO=liveresize \
    SIMCTL_CHILD_LANDLINE_DEMO_KEYBAR=tmux \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  sleep 4
  tm send-keys -t landline:test 'cargo test -p landline-proto --lib' Enter
  sleep 12        # the column collapses at +6s and comes back at +14s
  tap_at "$win" 0.47 0.966          # LDR
  sleep 1.6
  tap_at "$win" 0.72 0.966          # L2
  sleep 4
  tap_at "$win" 0.47 0.966
  sleep 1.4
  tap_at "$win" 0.66 0.966          # L1
  sleep 3

  kill -INT $rec 2>/dev/null || true
  wait $rec 2>/dev/null || true
  encode "$mov" "$RAW/video/ipad.mp4" 1200 1600
}

# --- encode -----------------------------------------------------------------

# Apple rejects a preview with no audio stream at all, so a silent AAC track is
# mapped in rather than the video shipping bare. Trimmed to 25s from the first
# frame; the head is already the index, so there is nothing to cut off the front.
encode() { # src dst width height
  local src="$1" dst="$2" w="$3" h="$4"
  ffmpeg -y -loglevel error \
    -i "$src" \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
    -t 25 \
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
