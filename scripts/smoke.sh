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
