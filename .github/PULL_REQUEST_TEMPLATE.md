## What changed and why

<!-- A couple of sentences. What problem does this solve? -->

Closes #

## Checklist

- [ ] `cargo fmt --all`
- [ ] `cargo clippy --workspace --all-targets -- -D warnings` is clean
- [ ] `cargo test --workspace` passes
- [ ] If this changes the wire format: `docs/PROTOCOL.md`, `crates/landline-proto`, and
      `ios/Landline/Protocol/Frame.swift` were all updated together
- [ ] Docs updated (README, docs/SCOPE.md, or docs/PROTOCOL.md) if relevant

## How was this tested

<!-- Commands you ran, platforms you tried, or "added a test covering X". -->
