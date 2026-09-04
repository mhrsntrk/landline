# frozen_string_literal: true

# Template for the mhrsntrk/homebrew-tap formula. This file does not live in
# the tap itself; the release workflow copies/updates a formula derived from
# this template by `sed`-replacing the placeholders below:
#   __VERSION__   e.g. "0.3.0" (no leading "v")
#   __SHA_ARM__   sha256 of landlined-aarch64-apple-darwin
#   __SHA_X86__   sha256 of landlined-x86_64-apple-darwin
#   __SHA_LINUX_ARM__  sha256 of landlined-aarch64-unknown-linux-gnu
#   __SHA_LINUX_X86__  sha256 of landlined-x86_64-unknown-linux-gnu
class Landline < Formula
  desc "Terminal on your iPhone, over your own tailnet"
  homepage "https://github.com/mhrsntrk/landline"
  version "__VERSION__"
  license "MIT"

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

  caveats <<~EOS
    Start the daemon and expose it on your tailnet:

      landlined install
      tailscale serve --bg --https=443 http://127.0.0.1:7777

    Then add this machine's ts.net hostname in the iOS app.

    Check it with `landlined doctor`, which reports the URL to enter.
  EOS

  test do
    system "#{bin}/landlined", "--help"
  end
end
