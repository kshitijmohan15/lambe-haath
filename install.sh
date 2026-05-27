#!/usr/bin/env sh
# Install logos (chargesheet tool) into ~/.local. macOS + Linux.
# Usage:  curl -fsSL https://raw.githubusercontent.com/kshitijmohan15/lambe-haath/main/install.sh | sh
# Pin a version:  LOGOS_VERSION=v0.1.0 sh install.sh
set -eu

REPO="kshitijmohan15/lambe-haath"
VERSION="${LOGOS_VERSION:-latest}"

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Darwin) os_part=macos ;;
  Linux)  os_part=linux ;;
  *) echo "unsupported OS: $os"; exit 1 ;;
esac
case "$arch" in
  arm64|aarch64) arch_part=arm64 ;;
  x86_64|amd64)  arch_part=x64 ;;
  *) echo "unsupported arch: $arch"; exit 1 ;;
esac
platform="${os_part}-${arch_part}"
case "$platform" in
  macos-arm64|macos-x64|linux-x64) ;;
  *) echo "unsupported platform: $platform (published: macos-arm64, macos-x64, linux-x64)"; exit 1 ;;
esac

# Resolve "latest" to a concrete vX.Y.Z via the releases/latest redirect (public repo, no API token).
if [ "$VERSION" = "latest" ]; then
  eff=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
  VERSION="${eff##*/}"
  case "$VERSION" in v*) ;; *) echo "could not resolve latest version (got '$VERSION')"; exit 1 ;; esac
fi

asset="logos-${VERSION}-${platform}.tar.gz"
url="https://github.com/$REPO/releases/download/${VERSION}/${asset}"

tmp=$(mktemp -d)
echo "Downloading $asset ..."
curl -fsSL "$url" -o "$tmp/$asset"
curl -fsSL "${url}.sha256" -o "$tmp/$asset.sha256"

echo "Verifying checksum ..."
( cd "$tmp"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$asset.sha256"
  else
    want=$(awk '{print $1}' "$asset.sha256")
    got=$(shasum -a 256 "$asset" | awk '{print $1}')
    [ "$want" = "$got" ] || { echo "checksum mismatch"; exit 1; }
  fi
)

dest="$HOME/.local/lib/lambe-haath"
bindir="$HOME/.local/bin"
echo "Installing to $dest ..."
rm -rf "$dest"
mkdir -p "$dest" "$bindir"
tar -xzf "$tmp/$asset" -C "$tmp"
cp -R "$tmp/logos-${VERSION}-${platform}/." "$dest/"
chmod +x "$dest/logos"
ln -sf "$dest/logos" "$bindir/logos"

echo "Installed logos $VERSION to $dest"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "NOTE: add $bindir to your PATH, e.g.:"; echo "  export PATH=\"$bindir:\$PATH\"" ;;
esac
echo "Run:  logos -p 7777   then open http://localhost:7777"
