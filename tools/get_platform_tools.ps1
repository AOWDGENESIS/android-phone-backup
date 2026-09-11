# Lädt die offiziellen Android SDK Platform-Tools (adb) von Google
# und entpackt sie in ../platform-tools (relativ zu diesem Skript).
# Downloads the official Android SDK Platform-Tools (adb) from Google
# and extracts them to ../platform-tools (relative to this script).
#
# Quelle / Source: https://developer.android.com/tools/releases/platform-tools
# Lizenz / License: Apache License 2.0 (Copyright (C) Google LLC)

$ErrorActionPreference = 'Stop'
$url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$target = Join-Path $PSScriptRoot '..\platform-tools'
$tmp = Join-Path $env:TEMP 'platform-tools-latest-windows.zip'

Write-Host "Lade platform-tools von Google..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
Write-Host "Entpacke nach $target ..." -ForegroundColor Cyan
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
Expand-Archive -LiteralPath $tmp -DestinationPath (Split-Path $target) -Force
Remove-Item $tmp -Force
Write-Host "Fertig: adb.exe liegt nun in $target" -ForegroundColor Green
