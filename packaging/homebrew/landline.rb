# frozen_string_literal: true

# Template for the mhrsntrk/homebrew-tap formula. This file does not live in
# the tap itself; the release workflow renders a formula from it by replacing
# the double-underscore placeholders below with the version and the checksums
# the release actually published: VERSION, SHA ARM, SHA X86, SHA LINUX ARM,
# SHA LINUX X86, and BOTTLE BLOCK.
#
# Those names are written without their underscores on purpose. The render
# step asserts that no placeholder survives, and a comment that spells one out
# literally would either be rewritten into nonsense or trip that assertion,
# depending on which placeholder it names. This comment cost a release once.
#
# BOTTLE BLOCK is emptied on the first pass and filled in later by the
# bottle-publish job, which runs `brew bottle --merge --write` against the
# formula already in the tap.
#
# The bottle block is not decoration. Without a bottle Homebrew treats this as
# a source build, even though `install` only copies an already-compiled binary,
# and it then refuses to proceed on any machine whose Command Line Tools are
# out of date. A bottle installs with no developer tools at all, and unlike a
# cask it carries no Gatekeeper quarantine, which matters while these binaries
# are still unsigned.
class Landline < Formula
  desc "Terminal on your iPhone, over your own tailnet"
  homepage "https://github.com/mhrsntrk/landline"
  version "__VERSION__"
  license "MIT"

__BOTTLE_BLOCK__

  on_macos do
    on_arm do
      url "https://github.com/mhrsntrk/landline/releases/download/v__VERSION__/landlined-aarch64-apple-darwin"
      sha256 "__SHA_ARM__"
    end

    on_intel do
      url "https://github.com/mhrsntrk/landline/releases/download/v__VERSION__/landlined-x86_64-apple-darwin"
      sha256 "__SHA_X86__"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/mhrsntrk/landline/releases/download/v__VERSION__/landlined-aarch64-unknown-linux-gnu"
      sha256 "__SHA_LINUX_ARM__"
    end

    on_intel do
      url "https://github.com/mhrsntrk/landline/releases/download/v__VERSION__/landlined-x86_64-unknown-linux-gnu"
      sha256 "__SHA_LINUX_X86__"
    end
  end

  def install
    # Upstream ships one bare binary per platform (no archive), named after
    # its target triple. Install whichever one on_macos/on_arm/on_intel
    # resolved to as `landlined`.
    bin.install Dir["landlined-*"].first => "landlined"
  end

  # `caveats` is a method, not a DSL call. Written as `caveats <<~EOS`
  # Homebrew raises "undefined method 'caveats'" at install time, which
  # only shows up when someone actually installs the formula.
  def caveats
    <<~EOS
      Start the daemon and expose it on your tailnet:

        landlined install
        tailscale serve --bg --https=443 http://127.0.0.1:7777

      Then add this machine's ts.net hostname in the iOS app.

      Check it with `landlined doctor`, which reports the URL to enter.
    EOS
  end

  test do
    system "#{bin}/landlined", "--help"
  end
end
