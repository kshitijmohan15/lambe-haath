#!/usr/bin/env sh
# Assert a release tag matches logos/build.zig.zon .version.
# Usage: scripts/check-version.sh <tag>   (e.g. v0.1.0). Prints the version on success.
set -eu
tag=$1
ver=$(sed -n 's/.*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' logos/build.zig.zon | head -1)
[ -n "$ver" ] || { echo "could not read .version from logos/build.zig.zon"; exit 1; }
expected="v${ver}"
if [ "$tag" != "$expected" ]; then
  echo "tag ($tag) != build.zig.zon version ($expected)"
  exit 1
fi
echo "$ver"
