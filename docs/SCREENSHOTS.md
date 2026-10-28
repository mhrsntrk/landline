# Regenerating the App Store screenshots and previews

Everything the listing shows is generated from this repo. Nothing is drawn by hand and
nothing on any frame is mocked: the terminal in the stills and in the video is a real
`landlined` session on a real tmux server on the build machine, running real commands
against a real checkout.

From iOS 1.1, terminal captures need a valid trial or unlock on the capture
simulator. Acquire one with the **Landline StoreKit** scheme before running the
capture scripts; demo seeding does not bypass purchase access. The separate
purchase-offer review images and their local StoreKit provenance are documented
in [appstore/review](../appstore/review/README.md).

```
ios/screenshots/
  capture.sh          drives the simulators, writes raw/
  record.sh           records the App Preview videos
  compose.py          dresses raw/ into the uploadable locale trees
  captions.json       the caption copy, en-US and ko
  demo/               the demo machine's zshrc and tmux.conf
  lib/simctl.sh       shared plumbing
  lib/tap.swift       posts a real tap at the simulator window
  raw/                the bare captures, kept alongside the composed ones
  en-US/, ko/         what `ascelerate apps media upload` reads
```

## The whole run

```sh
cargo build -p landlined --features harness      # the daemon the simulator dials
xcodebuild -project ios/Landline.xcodeproj -scheme Landline -configuration Debug \
  -sdk iphonesimulator -destination "id=$IPHONE_UDID" \
  -skipPackagePluginValidation -skipMacroValidation build

ios/screenshots/capture.sh all                   # ~12 min, both devices
ios/screenshots/record.sh all                    # ~4 min, both previews
python3 ios/screenshots/compose.py               # dresses stills into en-US/ and ko/
ios/screenshots/stage-previews.sh                # copies raw/video into en-US/ and ko/
```

The per-locale `preview.mp4` files are generated, not tracked: they are byte-identical to
`raw/video/`, and committing them meant the same two videos lived in the repository three
times each.

## iPhone Duo

The `APP_IPHONE_DUO` set carries the store's "Made for iPhone Duo" badge. It needs
Xcode 27.1 and its iOS 27.1 runtime (`xcodebuild -downloadPlatform iOS`), which is the
only runtime the Duo device type boots on. Xcode 27 replaced Simulator.app with
**DeviceHub**, which exposes no menus or window to a script, and that changes three things:

- **The pose is set by hand.** DeviceHub's pose buttons fold or open the device and its
  rotate button turns it. Neither `simctl` nor DeviceHub lets a script do either, so each
  pose is its own run, both in portrait:

  ```sh
  xcrun simctl create "iPhone Duo" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
  export DUO_UDID=<that udid> PY=<a python3 with Pillow>
  # open the Duo in DeviceHub, rotate to portrait
  ios/screenshots/capture.sh duo-inner             # 01, 03, 04, 05 on the inner display
  # fold it, rotate to portrait
  ios/screenshots/capture.sh duo-outer             # 02, 06 on the outer display
  ```

- **The software keyboard cannot be cycled off from a menu.** Duo runs set
  `LANDLINE_DEMO_NOKEYBOARD=1`, and the app leaves the terminal without first responder.
- **The screen is named explicitly.** The outer display is `LCD`, the inner one `LCD-1`,
  and display UUIDs change with the pose. Left to itself, `simctl io screenshot` shoots
  the display it last defaulted to, which after a fold is the one that is switched off:
  a frame of solid black at the wrong size.

The terminal frames need a StoreKit trial on the Duo simulator, and **uninstalling the app
drops it**, so Duo runs clear the container in place (`KEEP_PURCHASES=1`) instead of
reinstalling. Seed the trial once with an `SKTestSession` against
`LandlineTests/StoreKit/Landline.storekit` that calls `Purchases.startTrial()` and does
not clear its transactions (run it with `test-without-building -only-testing:`; a run that
also rebuilds has been seen to hang at the purchase).

`compose.py` prints all six frames on one 2007x2853 plate, the inner display's portrait
size, because one Duo set holds both displays.

Then upload. The layout is what `ascelerate apps media upload` expects, and files sort
alphabetically into gallery order, which is why the stills are `01_` to `0N_` and the
video is `preview.mp4`.

## What is on screen, and why it is real

`capture.sh` stands up a **throwaway demo machine** before it touches a simulator:

- a `HOME` at `/tmp/landline-shots/home`, with `demo/zshrc` (a starship-shaped prompt
  with Nerd Font git and rustc segments) and `demo/tmux.conf` (One Dark Pro status line,
  `C-a` prefix);
- a **git clone of this repo** at `~/src/landline`, so `cargo test` and `git log` on
  screen are this project's own real output;
- `landlined` built with `--features harness`, listening on **127.0.0.1:7788**.

None of it touches the operator's own setup. The real daemon on 7777 is never contacted,
the demo tmux runs on its own socket (`-L landlinedemo`) via a shim on the demo `PATH`,
and the demo `HOME` is a scratch directory. `/tmp` rather than a longer scratch path is
deliberate: a unix socket path is capped at about 104 bytes and both tmux and `landlined`
put one under `$HOME`.

The screenshot run has no fingers, so the session is dressed from outside with
`tmux send-keys` **after** the phone has attached, so the output is laid out at the
phone's own column count rather than reflowed into it.

## Things that will bite you again

- **Pick the app bundle by mtime.** `app_bundle()` sorts DerivedData by mtime. Stale
  trees sort ahead of the one you just built.
- **Reinstall, do not relaunch.** The seeded hosts and the resumable session id live in
  the container. A leftover session id makes the app attach twice, which leaves two tmux
  clients of different sizes on one session and draws an empty terminal.
- **The software keyboard eats 40% of a phone frame.** `ensure_no_soft_keyboard` cycles
  the simulator's *Connect Hardware Keyboard* menu item and then checks the **pixels**.
  The menu's tick is global while the effect is per device window, and the tmux client's
  row count has been seen to disagree with what is drawn, so neither is trusted.
- **The I/O menu applies to the frontmost device window.** With two simulators booted, a
  run that does not raise the right one silently toggles the other one's keyboard.
- **The leader latch is fragile on purpose.** It is armed on attach, cleared by any
  reconnect, and *spent* by the emulator's own answers to the queries tmux asks on
  attach. `DemoSeed.armsLeader` arms it two seconds after the session goes live, and
  `armed_in` confirms the accent fill is in the frame before the still is kept.
- **A resize pulls history back onto the screen.** Without `tmux clear-history` after
  dressing, a pane opens on the tail of the run that `clear` was supposed to have taken
  away, including the demo machine's own `$HOME` path.
- **`xcrun simctl` cannot tap.** `lib/tap.swift` posts real mouse events at the device
  window. Two things matter: the tap target is the window's `group` child (the glass),
  not the window (which is wider and carries a toolbar), and the simulator must be the
  **active** app or the click is spent activating it instead of reaching the device.
- **An App Preview with no audio stream is rejected at upload.** `record.sh` maps a
  silent AAC track in with `anullsrc`. Confirm with `ffprobe` before uploading.

## The debug hooks these frames rely on

All are `#if DEBUG` and inert unless the environment variable is set, so a release build
cannot reach any of them.

| Variable | What it does |
|---|---|
| `LANDLINE_DEMO` | seeds hosts and parks the run on a screen (`live`, `liveleader`, `liveresize`, `index`, `fullindex`, `keybar`, `edit`, …) |
| `LANDLINE_DEMO_ENDPOINT` | `studio.tail4f1a.ts.net@127.0.0.1:7788`: the seeded host keeps the tailnet name it *prints* and dials the harness daemon instead |
| `LANDLINE_DEMO_KEYBAR` | `tmux`: a key row carrying the leader and the window keys |
| `LANDLINE_DEMO_SECTION` | which host setting screen the edit sheet opens on |
| `LANDLINE_DEMO_CHAIN` | which startup-command shape the edit sheet is seeded with |
| `LANDLINE_DEMO_NOKEYBOARD` | `1`: the terminal never takes first responder, so no software keyboard covers the frame (Duo runs, see above) |

`LANDLINE_DEMO_ENDPOINT` exists because the iPad header band prints `ENDPOINT` and the
index row prints `hostname:port`, and a listing for a Tailscale client that advertises
`127.0.0.1:7788` tells the reader the wrong thing about the product. It redirects only
the host it names, so the index's reachability probe still tells the truth about every
other row.

## Fictional by construction

The machines in the index (`studio`, `macbook`, `rack`, `edge`, `nas`, `builder`, `pi`,
`vps` on `tail4f1a.ts.net`) are invented, and so are their status squares: the tailnet
does not exist, so nothing about it could be probed. No real hostname, tailnet, or login
appears on any frame.
