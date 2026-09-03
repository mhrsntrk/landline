#!/bin/sh
# landline installer: fetches the latest `landlined` release for this
# machine's OS/arch, verifies its checksum, and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/mhrsntrk/landline/main/packaging/install.sh | sh
#
# macOS and Linux only (arm64 + x86_64). Windows: grab the .exe from the
# GitHub releases page directly.
set -eu

REPO="mhrsntrk/landline"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

say() {
    printf '%s\n' "$1"
}

err() {
    printf 'landline install: %s\n' "$1" >&2
    exit 1
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "missing required command: $1"
    fi
}

need_cmd curl
need_cmd uname
need_cmd mktemp
need_cmd awk

os_raw=$(uname -s)
case "$os_raw" in
    Darwin) os_part="apple-darwin" ;;
    Linux) os_part="unknown-linux-gnu" ;;
    *) err "unsupported OS: ${os_raw} (landline ships prebuilt binaries for macOS and Linux only)" ;;
esac

arch_raw=$(uname -m)
case "$arch_raw" in
    arm64|aarch64) arch_part="aarch64" ;;
    x86_64|amd64) arch_part="x86_64" ;;
    *) err "unsupported architecture: ${arch_raw}" ;;
esac

target="${arch_part}-${os_part}"
asset="landlined-${target}"

say "landline install: detected ${target}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM

release_json="${tmpdir}/release.json"
if ! curl -fsSL "$API_URL" -o "$release_json"; then
    err "failed to fetch latest release metadata from ${API_URL}"
fi

# Pull the browser_download_url for our asset out of the release JSON.
# Avoids a hard jq dependency: greps the raw text for the field.
find_asset_url() {
    name="$1"
    grep -o '"browser_download_url": *"[^"]*"' "$release_json" \
        | sed -e 's/^"browser_download_url": *"//' -e 's/"$//' \
        | grep "/${name}\$" \
        | head -n 1
}

bin_url=$(find_asset_url "$asset")
sha_url=$(find_asset_url "${asset}.sha256")

[ -n "$bin_url" ] || err "no release asset found for ${asset} (checked ${API_URL})"
[ -n "$sha_url" ] || err "no checksum asset found for ${asset}.sha256"

bin_path="${tmpdir}/${asset}"
sha_path="${tmpdir}/${asset}.sha256"

say "landline install: downloading ${asset}"
curl -fsSL "$bin_url" -o "$bin_path"
curl -fsSL "$sha_url" -o "$sha_path"

say "landline install: verifying checksum"
if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$bin_path" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$bin_path" | awk '{print $1}')
else
    err "need shasum or sha256sum to verify the download"
fi
expected=$(awk '{print $1}' "$sha_path")

if [ "$expected" != "$actual" ]; then
    err "checksum mismatch for ${asset}: expected ${expected}, got ${actual}"
fi

chmod +x "$bin_path"

# Prefer /usr/local/bin if we can write to it; never sudo. Fall back to
# ~/.local/bin, creating it if needed.
install_dir=""
if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    install_dir="/usr/local/bin"
elif mkdir -p /usr/local/bin 2>/dev/null && [ -w /usr/local/bin ]; then
    install_dir="/usr/local/bin"
fi

if [ -z "$install_dir" ]; then
    install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"
fi

install_path="${install_dir}/landlined"
cp "$bin_path" "$install_path"
chmod +x "$install_path"

say "landline install: installed to ${install_path}"

case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *)
        say "landline install: warning: ${install_dir} is not on your PATH."
        say "  Add it, e.g.: export PATH=\"${install_dir}:\$PATH\""
        ;;
esac

say ""
say "Next steps:"
say "  landlined install                                        # launchd / systemd / scheduled task"
say "  tailscale serve --bg --https=443 http://127.0.0.1:7777"
say ""
say "Then add this machine's ts.net hostname (e.g. macbook.<tailnet>.ts.net) in the iOS app."
