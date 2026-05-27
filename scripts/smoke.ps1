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
