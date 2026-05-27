# Release System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a version tag, build the daemon + UI for macOS (arm64/x64), Linux (x64), and Windows (x64), runtime-smoke-test each on its native OS, publish installable bundles to a GitHub Release, and provide `curl|sh` / PowerShell installers.

**Architecture:** All build/install logic lives in small POSIX/PowerShell scripts (locally testable); a single GitHub Actions workflow orchestrates them. Builds use only validated paths (macOS native on macOS runners; Linux native + Windows cross-compiled on Linux). The smoke scripts are the real tests — they run the actual packaged bundle and assert health/UI/upload/slice.

**Tech Stack:** GitHub Actions, Zig 0.16.0 (`mlugg/setup-zig`), Node/Yarn (SvelteKit UI), `tar`/`zip`, `curl`, `softprops/action-gh-release`. Spec: `logos/docs/superpowers/specs/2026-05-27-release-system-design.md`.

**Branch:** `feat/release-system` (spec already committed there).

**Working directory:** repo root `/Users/user/projects/lambe-haath` unless stated. The daemon source is in `logos/`; commands that build the daemon `cd logos` first.

---

## File Structure

```
packaging/README.md          bundle quickstart + unsigned-binary bypass note (@VERSION@ templated)
scripts/package.sh           assemble bundle (binary + ui/ + README + LICENSE) -> archive + .sha256
scripts/smoke.sh             POSIX smoke assertions against an extracted bundle
scripts/smoke.ps1            Windows smoke assertions (mirror of smoke.sh)
scripts/check-version.sh     assert a tag matches logos/build.zig.zon .version
install.sh                   POSIX installer (curl | sh) — mac/linux
install.ps1                  Windows installer (irm | iex)
.github/workflows/release.yml  guard, ui, build(+package), smoke, release, install-verify
```

Each script has one responsibility and is invoked by the workflow. The daemon and `logos/build.zig` are **unchanged** — the daemon already defaults `ui_dir` to `<exe_dir>/ui`, which is exactly the bundle layout.

Naming contract used everywhere (scripts + workflow + installers MUST agree):
- bundle dir / archive base name: `logos-<version>-<platform>`
- `<version>`: the tag verbatim on releases (e.g. `v0.1.0`); a synthetic `0.0.0-dryrun+<sha>` on manual runs.
- `<platform>` ∈ `macos-arm64 | macos-x64 | linux-x64 | windows-x64`.
- archive: `.tar.gz` for unix platforms, `.zip` for windows; checksum file `<archive>.sha256`.

---

### Task 1: Bundle packaging script

Produce a release bundle from a built binary + built UI. Locally verifiable on macOS (our host = the `macos-arm64` target).

**Files:**
- Create: `packaging/README.md`
- Create: `scripts/package.sh`

- [ ] **Step 1: Write the bundle README template**

`packaging/README.md`:

```markdown
# logos — chargesheet slicing tool (@VERSION@)

A self-contained PDF chargesheet slicing tool: one CLI that runs a local daemon
and serves the web UI on http://localhost:7777.

## Run

    ./logos -p 7777        # macOS / Linux
    .\logos.exe -p 7777    # Windows

Then open http://localhost:7777 in your browser. Press Ctrl+C to stop.

The web UI is the `ui/` folder next to this binary; keep them together.

## Unsigned binary note

These binaries are not code-signed.

- macOS: the first run may be blocked ("cannot be opened because the developer
  cannot be verified"). Allow it once with:
      xattr -d com.apple.quarantine ./logos
  or System Settings → Privacy & Security → "Open Anyway".
- Windows: SmartScreen may warn ("Windows protected your PC"). Click
  "More info" → "Run anyway".
```

- [ ] **Step 2: Write `scripts/package.sh`**

```sh
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
```

- [ ] **Step 3: Make it executable**

```bash
chmod +x scripts/package.sh
```

- [ ] **Step 4: Build the daemon + UI locally, then package, and verify the bundle contents**

Run (macOS host = produces a `macos-arm64` bundle):

```bash
cd /Users/user/projects/lambe-haath
( cd chargesheet-ui && yarn install --frozen-lockfile && yarn build )
( cd logos && zig build -Doptimize=ReleaseSafe )
out=$(mktemp -d)
scripts/package.sh logos/zig-out/bin/logos chargesheet-ui/build v0.0.0-test macos-arm64 "$out"
echo "--- archive ---"; ls -la "$out"
echo "--- contents ---"; tar -tzf "$out/logos-v0.0.0-test-macos-arm64.tar.gz"
```
Expected: a `logos-v0.0.0-test-macos-arm64.tar.gz` + `.sha256`; the listing contains `logos-v0.0.0-test-macos-arm64/logos`, `.../ui/index.html`, `.../README.md`.

- [ ] **Step 5: Commit**

```bash
cd /Users/user/projects/lambe-haath
git add packaging/README.md scripts/package.sh
git commit -m "feat(release): bundle packaging script + README template"
```

---

### Task 2: Smoke-test script (the runtime test)

Start the packaged daemon and assert health + UI + upload + slice. Fully verifiable on macOS.

**Files:**
- Create: `scripts/smoke.sh`

- [ ] **Step 1: Write `scripts/smoke.sh`**

```sh
#!/usr/bin/env sh
# Smoke-test an EXTRACTED release bundle: start the daemon, assert health, UI,
# upload (page_count==10), and slice. Non-zero exit on any failed assertion.
# Usage: scripts/smoke.sh <bundle_dir> [port]
# Env: SMOKE_FIXTURE = path to the 10-page test PDF (required).
set -eu

bundle=$1
port=${2:-8799}
fixture=${SMOKE_FIXTURE:?SMOKE_FIXTURE must point to the 10-page test PDF}

bin="$bundle/logos"
[ -f "$bin" ] || bin="$bundle/logos.exe"
[ -f "$bin" ] || { echo "FAIL: no logos binary in $bundle"; exit 1; }

base="http://127.0.0.1:${port}"
data=$(mktemp -d)
log="$data/daemon.log"

CHARGESHEET_DATA_DIR="$data/store" "$bin" -p "$port" >"$log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
trap cleanup EXIT

fail() { echo "FAIL: $1"; echo "--- daemon log ---"; cat "$log" || true; exit 1; }

# wait up to ~10s for health
i=0
until curl -fsS "$base/api/v1/health" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -ge 50 ] && fail "daemon did not become healthy"
  sleep 0.2
done

# 1. health
curl -fsS "$base/api/v1/health" | grep -q '"status":"ok"' || fail "health body"

# 2. UI index served from ./ui
curl -fsS "$base/" | grep -qi "<!doctype html" || fail "index.html not served"

# 3. a referenced JS/mjs asset has a JS mime type
asset=$(curl -fsS "$base/" | grep -oE '/_app/[^"]+\.(mjs|js)' | head -1)
[ -n "$asset" ] || fail "no /_app asset referenced by index.html"
ct=$(curl -fsS -o /dev/null -w '%{content_type}' "$base$asset")
echo "$ct" | grep -q "text/javascript" || fail "asset mime not js: $ct"

# 4. create a project with the fixture (field name MUST be 'chargesheet')
resp=$(curl -fsS -X POST "$base/api/v1/projects" \
  -F 'name=Smoke' -F "chargesheet=@${fixture};type=application/pdf")
echo "$resp" | grep -q '"page_count":10' || fail "create/page_count: $resp"
proj=$(printf '%s' "$resp" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
[ -n "$proj" ] || fail "no project id in: $resp"

# 5. slice page 1; the slice file must exist and be smaller than the source
curl -fsS -X POST "$base/api/v1/projects/$proj/jobs/slice" \
  -H 'Content-Type: application/json' \
  -d '{"slices":[{"filename":"page1.pdf","start_page":1,"end_page":1}]}' >/dev/null \
  || fail "slice request failed"
slice_size=$(curl -fsS -o "$data/page1.pdf" -w '%{size_download}' \
  "$base/api/v1/projects/$proj/slices/page1.pdf") || fail "slice download failed"
src_size=$(wc -c < "$fixture")
[ "$slice_size" -gt 0 ] || fail "slice is empty"
[ "$slice_size" -lt "$src_size" ] || fail "slice ($slice_size) not smaller than source ($src_size)"

echo "SMOKE OK ($bundle)"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/smoke.sh
```

- [ ] **Step 3: Verify end-to-end on macOS against the Task 1 bundle**

```bash
cd /Users/user/projects/lambe-haath
out=$(mktemp -d)
scripts/package.sh logos/zig-out/bin/logos chargesheet-ui/build v0.0.0-test macos-arm64 "$out"
ext=$(mktemp -d); tar -xzf "$out/logos-v0.0.0-test-macos-arm64.tar.gz" -C "$ext"
SMOKE_FIXTURE="$PWD/mupdf-zig/tests/fixtures/sample-10pages.pdf" \
  scripts/smoke.sh "$ext/logos-v0.0.0-test-macos-arm64" 8799
```
Expected: ends with `SMOKE OK (...)` and exit code 0. (Re-run Task 1 Step 4 builds first if `logos/zig-out/bin/logos` or `chargesheet-ui/build` are stale.)

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke.sh
git commit -m "feat(release): smoke-test script (health, UI, upload, slice)"
```

---

### Task 3: Version guard script

Assert a release tag matches `logos/build.zig.zon` `.version`.

**Files:**
- Create: `scripts/check-version.sh`

- [ ] **Step 1: Write `scripts/check-version.sh`**

```sh
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
```

- [ ] **Step 2: Make it executable + verify both branches**

```bash
cd /Users/user/projects/lambe-haath
chmod +x scripts/check-version.sh
echo "matching tag (zon is 0.1.0):"; scripts/check-version.sh v0.1.0 && echo "PASS"
echo "mismatching tag:"; scripts/check-version.sh v9.9.9 && echo "should not print" || echo "PASS (rejected)"
```
Expected: first prints `0.1.0` then `PASS`; second prints the mismatch error then `PASS (rejected)`.

- [ ] **Step 3: Commit**

```bash
git add scripts/check-version.sh
git commit -m "feat(release): version guard (tag must match build.zig.zon)"
```

---

### Task 4: POSIX installer (`install.sh`)

`curl | sh` installer for macOS/Linux. Full download path is verified post-release (Task 7); here verify syntax + platform detection.

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Write `install.sh`**

```sh
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
```

- [ ] **Step 2: Verify syntax + detection**

```bash
cd /Users/user/projects/lambe-haath
chmod +x install.sh
sh -n install.sh && echo "SYNTAX OK"
command -v shellcheck >/dev/null && shellcheck install.sh scripts/*.sh || echo "(shellcheck not installed; skipped)"
```
Expected: `SYNTAX OK`. (A real download test requires a published Release — done in Task 7. Do NOT pipe to `sh` yet; no release exists.)

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat(release): POSIX installer (curl | sh)"
```

---

### Task 5: Windows installer + Windows smoke script

PowerShell mirrors of `install.sh` and `smoke.sh`. Not runnable on the macOS host — verified by the Windows CI jobs (Tasks 6/7).

**Files:**
- Create: `install.ps1`
- Create: `scripts/smoke.ps1`

- [ ] **Step 1: Write `install.ps1`**

```powershell
#requires -version 5
# Install logos (chargesheet tool) on Windows (x64).
# Usage:  irm https://raw.githubusercontent.com/kshitijmohan15/lambe-haath/main/install.ps1 | iex
# Pin:    $env:LOGOS_VERSION='v0.1.0'; irm .../install.ps1 | iex
$ErrorActionPreference = 'Stop'
$Repo = 'kshitijmohan15/lambe-haath'
$Version = if ($env:LOGOS_VERSION) { $env:LOGOS_VERSION } else { 'latest' }

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') { throw "unsupported arch: $arch (only x64 is published)" }
$platform = 'windows-x64'

if ($Version -eq 'latest') {
    $resp = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest" -MaximumRedirection 5 -UseBasicParsing
    $Version = ($resp.BaseResponse.ResponseUri.AbsoluteUri -split '/')[-1]
    if ($Version -notmatch '^v') { throw "could not resolve latest version (got '$Version')" }
}

$asset = "logos-$Version-$platform.zip"
$url = "https://github.com/$Repo/releases/download/$Version/$asset"
$tmp = Join-Path $env:TEMP ("logos-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

Write-Host "Downloading $asset ..."
Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp $asset) -UseBasicParsing
Invoke-WebRequest -Uri "$url.sha256" -OutFile (Join-Path $tmp "$asset.sha256") -UseBasicParsing

Write-Host "Verifying checksum ..."
$want = (Get-Content (Join-Path $tmp "$asset.sha256")).Split(' ')[0].ToLower()
$got = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $asset)).Hash.ToLower()
if ($want -ne $got) { throw "checksum mismatch" }

$dest = Join-Path $env:LOCALAPPDATA 'lambe-haath'
Write-Host "Installing to $dest ..."
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Path $dest | Out-Null
Expand-Archive -Path (Join-Path $tmp $asset) -DestinationPath $tmp -Force
Copy-Item -Recurse -Force (Join-Path $tmp "logos-$Version-$platform\*") $dest

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$dest*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$dest", 'User')
    Write-Host "Added $dest to your user PATH (open a new terminal to use 'logos')."
}
Write-Host "Installed logos $Version to $dest"
Write-Host "Run:  logos -p 7777   then open http://localhost:7777"
```

- [ ] **Step 2: Write `scripts/smoke.ps1`**

```powershell
#requires -version 5
# Smoke-test an extracted bundle on Windows. Usage: smoke.ps1 -Bundle <dir> [-Port 8799]
# Env: SMOKE_FIXTURE = path to the 10-page test PDF.
param([Parameter(Mandatory=$true)][string]$Bundle, [int]$Port = 8799)
$ErrorActionPreference = 'Stop'
$fixture = $env:SMOKE_FIXTURE
if (-not $fixture) { throw "SMOKE_FIXTURE must point to the 10-page test PDF" }

$bin = Join-Path $Bundle 'logos.exe'
if (-not (Test-Path $bin)) { throw "no logos.exe in $Bundle" }
$base = "http://127.0.0.1:$Port"
$data = Join-Path $env:TEMP ("smoke-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $data | Out-Null
$env:CHARGESHEET_DATA_DIR = (Join-Path $data 'store')

$proc = Start-Process -FilePath $bin -ArgumentList "-p $Port" -PassThru `
    -RedirectStandardOutput (Join-Path $data 'out.log') -RedirectStandardError (Join-Path $data 'err.log') -NoNewWindow
try {
    $ok = $false
    for ($i = 0; $i -lt 50; $i++) {
        try { Invoke-RestMethod "$base/api/v1/health" -TimeoutSec 2 | Out-Null; $ok = $true; break } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ok) { throw "daemon did not become healthy" }

    $h = Invoke-RestMethod "$base/api/v1/health"
    if ($h.status -ne 'ok') { throw "health status: $($h.status)" }

    $idx = Invoke-WebRequest "$base/" -UseBasicParsing
    if ($idx.Content -notmatch '(?i)<!doctype html') { throw "index.html not served" }

    if ($idx.Content -notmatch '(/_app/[^"]+\.(mjs|js))') { throw "no /_app asset referenced" }
    $asset = $Matches[1]
    $a = Invoke-WebRequest "$base$asset" -UseBasicParsing
    if ($a.Headers['Content-Type'] -notmatch 'text/javascript') { throw "asset mime: $($a.Headers['Content-Type'])" }

    $form = @{ name = 'Smoke'; chargesheet = Get-Item $fixture }
    $created = Invoke-RestMethod "$base/api/v1/projects" -Method Post -Form $form
    if ($created.chargesheet.page_count -ne 10) { throw "page_count: $($created.chargesheet.page_count)" }
    $proj = $created.id

    $body = '{"slices":[{"filename":"page1.pdf","start_page":1,"end_page":1}]}'
    Invoke-RestMethod "$base/api/v1/projects/$proj/jobs/slice" -Method Post -ContentType 'application/json' -Body $body | Out-Null
    $slicePath = Join-Path $data 'page1.pdf'
    Invoke-WebRequest "$base/api/v1/projects/$proj/slices/page1.pdf" -OutFile $slicePath -UseBasicParsing
    $sliceSize = (Get-Item $slicePath).Length
    $srcSize = (Get-Item $fixture).Length
    if ($sliceSize -le 0 -or $sliceSize -ge $srcSize) { throw "slice size $sliceSize not smaller than source $srcSize" }

    Write-Host "SMOKE OK ($Bundle)"
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}
```

- [ ] **Step 3: Verify PowerShell syntax (parse-only, no execution)**

If `pwsh` is available locally:
```bash
cd /Users/user/projects/lambe-haath
pwsh -NoProfile -Command "\$null = [System.Management.Automation.Language.Parser]::ParseFile('install.ps1',[ref]\$null,[ref]\$null); \$null = [System.Management.Automation.Language.Parser]::ParseFile('scripts/smoke.ps1',[ref]\$null,[ref]\$null); 'PARSE OK'"
```
Expected: `PARSE OK`. If `pwsh` is not installed, note it — these are exercised by the Windows CI jobs in Task 7.

- [ ] **Step 4: Commit**

```bash
git add install.ps1 scripts/smoke.ps1
git commit -m "feat(release): Windows installer + Windows smoke script"
```

---

### Task 6: GitHub Actions workflow

Orchestrate guard → ui → build(+package) → smoke → release → install-verify.

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write `.github/workflows/release.yml`**

```yaml
name: release

on:
  push:
    tags: ["v*.*.*"]
  workflow_dispatch: {}

permissions:
  contents: write

jobs:
  guard:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.v.outputs.version }}
      is_release: ${{ steps.v.outputs.is_release }}
    steps:
      - uses: actions/checkout@v4
      - id: v
        shell: bash
        run: |
          if [ "${{ github.ref_type }}" = "tag" ]; then
            tag="${{ github.ref_name }}"
            scripts/check-version.sh "$tag"   # fails on mismatch
            echo "version=$tag" >> "$GITHUB_OUTPUT"
            echo "is_release=true" >> "$GITHUB_OUTPUT"
          else
            echo "version=0.0.0-dryrun+${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
            echo "is_release=false" >> "$GITHUB_OUTPUT"
          fi

  ui:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - working-directory: chargesheet-ui
        run: |
          yarn install --frozen-lockfile
          yarn build
      - uses: actions/upload-artifact@v4
        with:
          name: ui
          path: chargesheet-ui/build

  build:
    needs: [guard, ui]
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: macos-14,     target: aarch64-macos,     platform: macos-arm64 }
          - { os: macos-13,     target: x86_64-macos,      platform: macos-x64 }
          - { os: ubuntu-latest, target: x86_64-linux-musl, platform: linux-x64 }
          - { os: ubuntu-latest, target: x86_64-windows-gnu, platform: windows-x64 }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with: { version: "0.16.0" }
      - name: Cache MuPDF/zig build
        uses: actions/cache@v4
        with:
          path: |
            ~/.cache/zig
            logos/.zig-cache
          key: zigbuild-${{ matrix.platform }}-${{ hashFiles('mupdf-zig/**', 'logos/build.zig.zon', 'logos/build.zig') }}
      - name: Build daemon
        working-directory: logos
        run: zig build -Dtarget=${{ matrix.target }} -Doptimize=ReleaseSafe
      - uses: actions/download-artifact@v4
        with: { name: ui, path: ui-build }
      - name: Package bundle
        shell: bash
        run: |
          bin="logos/zig-out/bin/logos"
          [ "${{ matrix.platform }}" = "windows-x64" ] && bin="logos/zig-out/bin/logos.exe"
          out="$PWD/dist"; mkdir -p "$out"
          scripts/package.sh "$bin" ui-build "${{ needs.guard.outputs.version }}" "${{ matrix.platform }}" "$out"
      - uses: actions/upload-artifact@v4
        with:
          name: bundle-${{ matrix.platform }}
          path: dist/*

  smoke:
    needs: [guard, build]
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: macos-14,      platform: macos-arm64, ext: tar.gz }
          - { os: macos-13,      platform: macos-x64,   ext: tar.gz }
          - { os: ubuntu-latest, platform: linux-x64,   ext: tar.gz }
          - { os: windows-latest, platform: windows-x64, ext: zip }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: bundle-${{ matrix.platform }}, path: dist }
      - name: Smoke (unix)
        if: matrix.platform != 'windows-x64'
        shell: bash
        run: |
          v="${{ needs.guard.outputs.version }}"
          mkdir -p ext
          tar -xzf "dist/logos-${v}-${{ matrix.platform }}.tar.gz" -C ext
          SMOKE_FIXTURE="$PWD/mupdf-zig/tests/fixtures/sample-10pages.pdf" \
            scripts/smoke.sh "ext/logos-${v}-${{ matrix.platform }}" 8799
      - name: Smoke (windows)
        if: matrix.platform == 'windows-x64'
        shell: pwsh
        run: |
          $v = "${{ needs.guard.outputs.version }}"
          Expand-Archive -Path "dist/logos-$v-windows-x64.zip" -DestinationPath ext -Force
          $env:SMOKE_FIXTURE = "$PWD/mupdf-zig/tests/fixtures/sample-10pages.pdf"
          scripts/smoke.ps1 -Bundle "ext/logos-$v-windows-x64" -Port 8799

  release:
    needs: [guard, smoke]
    if: needs.guard.outputs.is_release == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { pattern: bundle-*, path: dist, merge-multiple: true }
      - name: Build SHA256SUMS
        shell: bash
        run: |
          cd dist
          rm -f SHA256SUMS
          cat *.sha256 > SHA256SUMS || true
          ls -la
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ needs.guard.outputs.version }}
          files: |
            dist/*.tar.gz
            dist/*.zip
            dist/SHA256SUMS

  install-verify:
    needs: [guard, release]
    if: needs.guard.outputs.is_release == 'true'
    strategy:
      fail-fast: false
      matrix:
        os: [macos-14, macos-13, ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Install + verify (unix)
        if: runner.os != 'Windows'
        shell: bash
        run: |
          LOGOS_VERSION="${{ needs.guard.outputs.version }}" sh install.sh
          "$HOME/.local/bin/logos" -V
      - name: Install + verify (windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          $env:LOGOS_VERSION = "${{ needs.guard.outputs.version }}"
          ./install.ps1
          & "$env:LOCALAPPDATA/lambe-haath/logos.exe" -V
```

- [ ] **Step 2: Lint the workflow**

```bash
cd /Users/user/projects/lambe-haath
command -v actionlint >/dev/null && actionlint .github/workflows/release.yml || echo "(actionlint not installed; will validate by running the workflow in Task 7)"
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```
Expected: `YAML OK` (and no actionlint errors if installed).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat(release): CI workflow (guard, ui, build, smoke, release, install-verify)"
```

---

### Task 7: Dry-run, then first real release

Validate the whole pipeline with a no-publish dry run across all four OSes, fix any failures, then cut the first real release and confirm the install one-liners.

**Files:** none (operational).

- [ ] **Step 1: Push the branch**

```bash
cd /Users/user/projects/lambe-haath
git push -u origin feat/release-system
```

- [ ] **Step 2: Trigger the dry-run on the branch**

```bash
gh auth switch --user kshitijmohan15
gh workflow run release.yml --ref feat/release-system
gh run watch "$(gh run list --workflow=release.yml --branch=feat/release-system --limit=1 --json databaseId -q '.[0].databaseId')"
gh auth switch --user kshitij4myfi
```
Expected: `guard`, `ui`, all four `build`, and all four `smoke` jobs succeed; `release` and `install-verify` are **skipped** (not a tag). If a job fails, read its log (`gh run view --log-failed`), fix the relevant script/workflow, commit, push, and re-run this step. The windows `smoke` job is the first real runtime test of the cross-built Windows binary — it MUST pass.

- [ ] **Step 3: Open the PR and merge**

```bash
gh auth switch --user kshitijmohan15
gh pr create --base main --head feat/release-system \
  --title "feat: release system (CI build, GitHub Releases, install scripts)" \
  --body "Builds daemon + UI for macOS/Linux/Windows, smoke-tests each on its native OS, publishes installable bundles on tag. Dry-run green across all four platforms."
gh pr merge --squash --delete-branch
git checkout main && git pull --ff-only origin main
gh auth switch --user kshitij4myfi
```

- [ ] **Step 4: Cut the first release (tag matching build.zig.zon)**

`logos/build.zig.zon` is `0.1.0`, so tag `v0.1.0`:
```bash
cd /Users/user/projects/lambe-haath
git tag v0.1.0
git push origin v0.1.0
gh auth switch --user kshitijmohan15
gh run watch "$(gh run list --workflow=release.yml --limit=1 --json databaseId -q '.[0].databaseId')"
gh auth switch --user kshitij4myfi
```
Expected: this time `release` publishes the GitHub Release with four archives + `SHA256SUMS`, and `install-verify` installs from the published release on all four OSes and prints `0.1.0`.

> Note: `v0.1.0` is currently only a local/loose tag from the initial seed. If `git push origin v0.1.0` reports the tag already exists remotely, bump `.version` in `logos/build.zig.zon` (e.g. `0.1.1`), commit via a PR to main, then tag `v0.1.1` instead.

- [ ] **Step 5: Confirm the public install one-liners**

On macOS (this host):
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/kshitijmohan15/lambe-haath/main/install.sh)"
"$HOME/.local/bin/logos" -V   # expect the released version
```
Expected: installs and prints the version. (Windows/Linux equivalents are already covered by the `install-verify` CI job in Step 4.)

---

## Acceptance Criteria

- `scripts/package.sh` produces a correct bundle (binary + `ui/` + README) and archive + checksum (Task 1 Step 4).
- `scripts/smoke.sh` passes against a real macOS bundle: health, UI, JS-mime asset, upload `page_count==10`, slice smaller than source (Task 2 Step 3).
- `scripts/check-version.sh` accepts a matching tag and rejects a mismatch (Task 3 Step 2).
- Dry-run (`workflow_dispatch`) builds + smokes all four platforms green and publishes nothing (Task 7 Step 2).
- Tagging `vX.Y.Z` (matching `build.zig.zon`) publishes a Release with the four archives + `SHA256SUMS` only after all smoke jobs pass; `install-verify` then installs from the published release on all four OSes (Task 7 Step 4).
- The public `curl|sh` / `irm|iex` one-liners install a working `logos` (Task 7 Steps 4–5).

## Self-Review

**1. Spec coverage:** targets/build matrix (Task 6 build) ✓; no-signing + bypass note (Task 1 README) ✓; script+archive install (Tasks 4/5) ✓; native smoke tests incl. Windows (Tasks 2/5/6 smoke) ✓; Approach C build orchestration (Task 6 matrix: macOS native, Windows cross-from-Linux) ✓; command name `logos` + user-local install (Tasks 4/5) ✓; ReleaseSafe (Task 6 build) ✓; version guard + dry-run + release gating (Tasks 3/6/7) ✓; bundle layout with `ui/` beside binary (Task 1) ✓; SHA256SUMS (Task 6 release) ✓; smoke fixture `sample-10pages.pdf` (Tasks 2/6) ✓. Spec said the *smoke* job would also run the install scripts; that's impossible pre-publish (chicken-and-egg), so install scripts are instead CI-verified post-publish via the `install-verify` job (Task 6) — a refinement that still satisfies "install scripts are CI-tested."

**2. Placeholder scan:** No TBD/TODO. All scripts and the workflow are complete and runnable. Verification commands have concrete expected output. The one conditional ("if the remote tag already exists, bump version") is an explicit operational branch, not a placeholder.

**3. Consistency:** The `logos-<version>-<platform>` naming and the platform set `{macos-arm64,macos-x64,linux-x64,windows-x64}` are identical across `package.sh`, `smoke.sh`/`smoke.ps1`, `install.sh`/`install.ps1`, and every workflow job. `guard.outputs.version` feeds package/smoke/release/install-verify uniformly. Archive extensions (`.tar.gz` unix / `.zip` windows) are consistent between producer (package.sh) and consumers (smoke, install). The upload field name `chargesheet` and slice JSON shape match the daemon handlers.

## Known follow-ups (out of this plan)

- `respondProjectsJobsSlice` in `logos/src/api/server.zig` still uses `readerExpectNone` (same `Expect: 100-continue` crash class fixed for upload in PR #1). Small JSON slice requests don't send that header, so smoke passes, but it should be switched to `readerExpectContinue` before broad release. Track separately.
- Add `.env`/secret globs to `.gitignore` now that the repo is public (no such files exist today).
- A `LICENSE` file is not yet in the repo; `package.sh` includes it only if present. Choosing a license is a separate decision.
