# Working on Landline with a coding agent

Conventions and traps for anyone, human or agent, changing this repository. Read
`docs/SCOPE.md` for what the product is and `DESIGN.md` before touching UI.

Also read as `CLAUDE.md`; the file is symlinked so both conventions find it.

## Commands

```sh
cargo test --workspace                                   # 30 tests
cargo clippy --workspace --all-targets -- -D warnings     # must be silent
cargo fmt --all

cd ios && xcodegen generate                               # the .xcodeproj is generated, never edited
xcodebuild -project Landline.xcodeproj -scheme Landline \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation build                      # 224 tests via `test`
```

`-skipPackagePluginValidation` is required: SwiftTerm ships a build-tool plugin
that headless `xcodebuild` refuses without it.

**The Xcode project is generated.** Anything set through the Xcode UI is
discarded on the next `xcodegen generate`. Signing, version, capabilities and
Info.plist keys all live in `ios/project.yml`.

## Rules that are not style preferences

**The wire protocol has three copies and they move together.**
`docs/PROTOCOL.md` is normative; `crates/landline-proto/src/frame.rs` and
`ios/Landline/Protocol/Frame.swift` implement it. Change one and you change all
three in the same commit, and bump `proto_version` if the change is not
backward compatible. The daemon and the app ship independently, so version skew
is the normal case, not an edge case.

**`DESIGN.md` is binding for anything with a pixel in it**, including the
measured contrast floor. `inkDim` is 2.32:1 and therefore never carries text.
That rule exists because it was violated once and shipped.

**No em-dashes in user-facing strings**, and no double terminators like `?.`.
Applies to UI copy, store metadata and documentation. Commit messages are
exempt.

## Traps this repository has already hit

Each of these cost real time. They are listed because they will recur.

- **`ascelerate` reports success without writing.** It has silently failed on
  version localizations, on the age rating declaration (3 of 29 fields), and
  `apps review submit` creates a submission it never files. **Always export and
  diff after any write.** The raw App Store Connect API is the reliable path.
- **Pick a built app bundle by mtime, not `find | head -1`.** There are multiple
  DerivedData trees on a typical machine and the first match is often days old.
  Two separate agents reported phantom bugs from a stale bundle.
- **Look at rendered output.** Several bugs here were invisible in code and in
  tests, and obvious in a screenshot: an invisible tick scale, a font that
  resolved by name while the cascade drew every glyph, `0X01` where `0x01` was
  meant. If a change affects pixels, screenshot it and open the file.
- **A terminal query in replayed scrollback will be answered** unless suppressed,
  and the answer is typed at whatever prompt exists now. See
  `TerminalController.dropsOutbound`.
- **`portable-pty` is blocking.** Each session owns three dedicated
  `std::thread`s, deliberately not `spawn_blocking`, because they live for the
  whole session and would occupy pool slots forever.
- **Terminal output fan-out uses a swappable mpsc slot, never `broadcast`.** A
  lagging broadcast receiver drops messages silently, which corrupts a stream.
- **Homebrew needs a bottle.** A formula without one is treated as a source
  build, and Homebrew then refuses on any machine with outdated Command Line
  Tools, even though `install` only copies a compiled binary.

## Non-goals

These will be declined however good the patch is. See `docs/SCOPE.md`.

Screen sharing or remote desktop. A file manager or SFTP browser. Port
forwarding. Android or web clients. A hosted service, accounts, or telemetry of
any kind.

## Setting the daemon up for a user

If you are an agent configuring `landlined` on someone's machine rather than
changing this code, use `skills/landline-setup/SKILL.md`, which carries the
failure modes worth knowing.
