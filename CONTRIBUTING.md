# Contributing to Landline

Thanks for looking at this. Landline is a solo, spare-time project, so review can be slow,
sometimes weeks. If you're planning anything larger than a small fix, please open an issue
first and describe what you want to do. It saves both of us from a big PR that gets declined
after the fact.

## Non-goals

These are declined regardless of how well the patch is written. Please read this before
writing code. Full reasoning in [`docs/SCOPE.md`](docs/SCOPE.md).

- Screen sharing or remote desktop. Terminal only, forever.
- A file manager or SFTP browser.
- A port forwarding UI.
- Android or web clients.
- A hosted service, accounts, or team features.

If you think one of these should be reconsidered, open an issue and make the case there
before sending code.

## Development setup

### Rust workspace (`landline-proto`, `landlined`, `landline-cli`)

Requires Rust stable.

```sh
cargo build
cargo test --workspace
```

### iOS app

```sh
brew install xcodegen
cd ios && xcodegen generate
```

Open `ios/Landline.xcodeproj` in Xcode from there.

If you ever need to build it headlessly with `xcodebuild`, pass
`-skipPackagePluginValidation`: SwiftTerm ships a build-tool plugin via SPM and `xcodebuild`
refuses it without that flag.

## Running the daemon locally

Build it:

```sh
cargo build -p landlined
```

Write a config (see `landlined config-path` for where it should live, or drop one at
`~/.config/landline/config.toml` on Linux/macOS):

```toml
listen         = "127.0.0.1:7777"
allowed_logins = ["you@example.com"]
shell          = ""
```

Run it, then connect with the CLI test client:

```sh
cargo run -p landlined -- serve
cargo run -p landline-cli -- ws://127.0.0.1:7777/v1/shell --login you@example.com
```

### The `harness` feature

`cargo build -p landlined --features harness` serves a browser-based terminal at `/` and
skips the tailnet identity check, which is convenient when you don't have `tailscale serve`
in front of the daemon during development. It deliberately refuses to compile with
`--release`, so it can never end up in a distributed binary by accident.

## Bar for a PR to be merged

- `cargo fmt --all`
- `cargo clippy --workspace --all-targets -- -D warnings`, zero warnings
- `cargo test --workspace` green
- CI green on macOS, Linux, and Windows
- New behavior comes with a test

## Changing the wire protocol

[`docs/PROTOCOL.md`](docs/PROTOCOL.md) is the normative spec. Any change to the wire format
must update, together, in the same PR:

1. The spec in `docs/PROTOCOL.md`.
2. The Rust codec in `crates/landline-proto`.
3. The Swift mirror in `ios/Landline/Protocol/Frame.swift`.

If the change is not backward compatible, bump `proto_version`. The daemon and the iOS app
ship independently, so a phone can be talking to an old daemon or a new daemon at any given
moment. Version skew is the normal case, not an edge case, and the protocol has to keep
working (or fail cleanly with `ERR PROTOCOL_VERSION`) across it.

## Commit style

Short, imperative subject line. `Fix session resume race`, not `Fixed a bug` or `Fixes #12`.
Conventional Commit prefixes (`fix:`, `feat:`, `docs:`, ...) are welcome if you use them, but
not required.

## License

By contributing, you agree your contribution is licensed under the MIT license that covers
the rest of the repo. There is no CLA.
