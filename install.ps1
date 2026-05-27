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
