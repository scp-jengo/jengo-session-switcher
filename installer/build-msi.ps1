param([string]$Version = "1.0.0")
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$out = Join-Path $dist "JengoSessions-$Version.msi"
wix build "$PSScriptRoot\Package.wxs" -d Version=$Version -d SrcDir=$root -arch x64 -o $out
if ($LASTEXITCODE -ne 0) { throw "wix build failed" }
Write-Host "Built $out"
