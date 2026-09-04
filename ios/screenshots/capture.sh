#!/bin/bash
# Capture the raw simulator frames for the App Store listing.
#
#   ios/screenshots/capture.sh            both devices
#   ios/screenshots/capture.sh iphone     one device
#
# Writes ios/screenshots/raw/<device>/NN_<name>.png. compose.py turns those into
# the uploadable en-US/ and ko/ trees. See docs/SCREENSHOTS.md.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/simctl.sh"

WHICH="${1:-all}"

mkdir -p /tmp/landline-shots "$RAW/iphone" "$RAW/ipad"
write_demo_home
start_daemon
trap stop_demo EXIT

# Launch the app on a device with a demo mode, from a clean container.
launch() { # udid mode [extra env assignments...]
  local udid="$1" mode="$2"; shift 2
  reinstall "$udid"
  status_bar "$udid"
  env "$@" SIMCTL_CHILD_LANDLINE_DEMO="$mode" \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
}

# One live session, dressed with real work: three tmux windows and a real
# `cargo test` run against the checkout in the demo home. Sent from outside
# because a screenshot run has no fingers, and sent *after* the phone attaches
# so the output is laid out at the phone's own column count.
tm() { dtmux "$@" >/dev/null 2>&1 || true; }

# Three named windows, so the status line has something to say.
seed_tmux_windows() {
  tm rename-window -t landline:1 test
  tm new-window -d -t landline: -n logs -c "$DEMO_HOME/src/landline"
  tm new-window -d -t landline: -n dev -c "$DEMO_HOME/src/landline"
  tm send-keys -t landline:test 'cd ~/src/landline && clear' Enter
  sleep 1
}

# `$1` is how many commits the trailing `git log` prints: enough to fill the
# rows the device has left after the test run, and no more.
seed_tmux_work() {
  seed_tmux_windows
  tm send-keys -t landline:test 'cargo test -p landline-proto --lib roundtrip' Enter
  sleep 14
  tm send-keys -t landline:test "git log --oneline -${1:-3}" Enter
  sleep 3
  # Without this the resumed replay opens on the demo machine's own $HOME path,
  # which `clear` hid from the screen but not from the scrollback the daemon
  # replays on the next attach.
  tm clear-history -t landline:test
}

# The tmux frame gets a split as well as the status line, because two panes and
# an active-pane border is what makes a screen read as tmux at a glance.
seed_tmux_split() {
  seed_tmux_windows
  # Split before the commands run, not after: splitting reflows the pane and a
  # screen that was written at full height comes back showing only its tail.
  tm split-window -v -t landline:test -c "$DEMO_HOME/src/landline" -l 60%
  sleep 1
  tm send-keys -t landline:test.1 'clear' Enter
  sleep 1
  tm send-keys -t landline:test.1 'cargo test -q -p landline-proto --lib roundtrip' Enter
  sleep 12
  tm send-keys -t landline:test.2 'git log --oneline -12' Enter
  sleep 3
  tm select-pane -t landline:test.1
  # The relaunch that arms the leader resizes the panes on the way in, and a
  # resize pulls history back onto the screen: without this the top pane opens
  # on the tail of the run that `clear` was supposed to have taken away.
  tm clear-history -t landline:test.1
  tm clear-history -t landline:test.2
}

capture_iphone() {
  local udid="$IPHONE_UDID" out="$RAW/iphone"
  # Where the leader cell sits in a phone frame, as fractions.
  local LDR_BOX="0.21 0.932 0.28 0.956"
  hardware_keyboard "$IPHONE_WINDOW"

  # 01  a live session doing real work
  dtmux kill-server >/dev/null 2>&1 || true
  launch "$udid" live
  wait_for_session 20
  ensure_no_soft_keyboard "$IPHONE_WINDOW" "$udid"
  seed_tmux_work 3
  shoot "$udid" "$out/01_session.png"

  # 02  the index: several machines, each with its status square
  launch "$udid" index
  sleep 5
  shoot "$udid" "$out/02_index.png"

  # 03  tmux: leader armed over a live session, window keys on the bar, and
  #     the session split into two panes so the screen reads as tmux and not
  #     just as a shell. The latch is verified in the pixels before the still is
  #     taken, because it is armed on attach and any reconnect clears it.
  dtmux kill-server >/dev/null 2>&1 || true
  launch "$udid" live
  wait_for_session 20
  ensure_no_soft_keyboard "$IPHONE_WINDOW" "$udid"
  seed_tmux_split
  launch_with_armed_leader "$udid" "$out/03_tmux.png" $LDR_BOX

  # 04  the palettes, printed as themselves
  launch "$udid" edit SIMCTL_CHILD_LANDLINE_DEMO_SECTION=palette
  sleep 5
  shoot "$udid" "$out/04_palettes.png"

  # 05  the key bar, with the bytes each key sends
  launch "$udid" keybar
  sleep 5
  shoot "$udid" "$out/05_keybar.png"

  # 06  adding a machine: the whole setup, on one screen
  launch "$udid" edit SIMCTL_CHILD_LANDLINE_DEMO_CHAIN=fixed
  sleep 5
  shoot "$udid" "$out/06_host.png"
}

capture_ipad() {
  local udid="$IPAD_UDID" out="$RAW/ipad"
  # The iPad key bar spans the detail pane only, so the leader cell is further
  # right and lower than on the phone.
  local LDR_BOX="0.45 0.957 0.49 0.975"
  hardware_keyboard "$IPAD_WINDOW"

  # 01  the split: the index column beside a live session
  dtmux kill-server >/dev/null 2>&1 || true
  launch "$udid" live
  wait_for_session 20
  ensure_no_soft_keyboard "$IPAD_WINDOW" "$udid"
  seed_tmux_work 22
  shoot "$udid" "$out/01_split.png"

  # 02  the same session with the index given back to the terminal.
  #     Relaunched rather than reinstalled: the session id is in the container,
  #     so the app resumes the session frame 01 was just photographed on, with
  #     its scrollback, and `liveresize` collapses the column six seconds in.
  #     That is also the resize proof, since GEOM is written only by the
  #     callback that sends the RESIZE frame.
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  SIMCTL_CHILD_LANDLINE_DEMO=liveresize \
    SIMCTL_CHILD_LANDLINE_DEMO_ENDPOINT="$DEMO_DISPLAY_HOST@127.0.0.1:$DEMO_PORT" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  sleep 9
  shoot "$udid" "$out/02_fullwidth.png"

  # 03  tmux. Same as the phone: armed leader, split panes, latch verified.
  dtmux kill-server >/dev/null 2>&1 || true
  launch "$udid" live
  wait_for_session 20
  ensure_no_soft_keyboard "$IPAD_WINDOW" "$udid"
  seed_tmux_split
  launch_with_armed_leader "$udid" "$out/03_tmux.png" $LDR_BOX

  # 04  palettes
  launch "$udid" edit SIMCTL_CHILD_LANDLINE_DEMO_SECTION=palette
  sleep 5
  shoot "$udid" "$out/04_palettes.png"

  # 05  key bar
  launch "$udid" keybar
  sleep 5
  shoot "$udid" "$out/05_keybar.png"
}

case "$WHICH" in
  iphone) capture_iphone ;;
  ipad)   capture_ipad ;;
  all)    capture_iphone; capture_ipad ;;
  *) echo "usage: capture.sh [iphone|ipad|all]" >&2; exit 2 ;;
esac

echo "raw frames in $RAW"
