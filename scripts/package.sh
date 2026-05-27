#!/usr/bin/env sh
# Assemble a release bundle and archive it.
# Usage: scripts/package.sh <bin_path> <ui_dir> <version> <platform> <out_dir>
#   platform: macos-arm64 | macos-x64 | linux-x64 | windows-x64
# Run from the repo root (reads packaging/README.md and LICENSE relative to cwd).
# Pass an ABSOLUTE out_dir. Prints the archive path on stdout.
set -eu

bin_path=$1
ui_dir=$2
version=$3
platform=$4
out_dir=$5

name="logos-${version}-${platform}"
stage="${out_dir}/${name}"
rm -rf "$stage"
mkdir -p "$stage/ui"

case "$platform" in
  windows-*) cp "$bin_path" "$stage/logos.exe" ;;
  *)         cp "$bin_path" "$stage/logos"; chmod +x "$stage/logos" ;;
esac

cp -R "$ui_dir/." "$stage/ui/"
sed "s/@VERSION@/${version}/g" packaging/README.md > "$stage/README.md"
if [ -f LICENSE ]; then cp LICENSE "$stage/LICENSE"; fi

case "$platform" in
  windows-*) archive="${name}.zip" ;;
  *)         archive="${name}.tar.gz" ;;
esac

# archive from inside out_dir so paths are relative to the bundle dir
old=$(pwd)
cd "$out_dir"
case "$platform" in
  windows-*) zip -rq "$archive" "$name" ;;
  *)         tar -czf "$archive" "$name" ;;
esac
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$archive" > "${archive}.sha256"
else
  shasum -a 256 "$archive" > "${archive}.sha256"
fi
cd "$old"

echo "${out_dir}/${archive}"
