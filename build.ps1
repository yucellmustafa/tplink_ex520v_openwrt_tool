# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$Version = '0.1.0',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$releaseRoot = Join-Path $root 'release'
$packageName = 'EX520v-OpenWrt-Tool-' + ($Version -replace '[^A-Za-z0-9._-]', '_')
$package = Join-Path $releaseRoot $packageName
$zip = Join-Path $releaseRoot ($packageName + '-windows-x64.zip')

if (-not $SkipTests) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\run-tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Testler başarısız; paket oluşturulmadı.' }
}

$ps2exe = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
if (-not $ps2exe) {
    throw "PS2EXE modülü bulunamadı. Bir kez 'Install-Module ps2exe -Scope CurrentUser' çalıştırın."
}

if (-not (Test-Path -LiteralPath $releaseRoot)) { [void](New-Item -ItemType Directory -Path $releaseRoot) }
$resolvedRelease = [IO.Path]::GetFullPath($releaseRoot).TrimEnd('\') + '\'
$resolvedPackage = [IO.Path]::GetFullPath($package).TrimEnd('\') + '\'
if (-not $resolvedPackage.StartsWith($resolvedRelease, [StringComparison]::OrdinalIgnoreCase)) { throw 'Güvensiz paket hedefi.' }
if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
[void](New-Item -ItemType Directory -Path $package)

$exe = Join-Path $package 'ex520v-tool.exe'
Invoke-ps2exe -InputFile (Join-Path $root 'ex520v-tool.ps1') -OutputFile $exe -x64 -STA -Title 'TP-Link EX520v OpenWrt Tool' -Product 'TP-Link EX520v OpenWrt Tool' -Version $Version -Copyright 'GPL-3.0-or-later contributors'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'EXE üretilemedi.' }

foreach ($directory in @('modules', 'install', 'root-tool')) {
    Copy-Item -LiteralPath (Join-Path $root $directory) -Destination (Join-Path $package $directory) -Recurse
}
$packagedRootTool = Join-Path $package 'root-tool'
Get-ChildItem -LiteralPath $packagedRootTool -Directory -Recurse -Force |
    Where-Object { $_.Name -in @('.venv', '__pycache__') } |
    Sort-Object FullName -Descending |
    Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $packagedRootTool -File -Recurse -Filter '*.pyc' -Force |
    Remove-Item -Force
foreach ($file in @('ex520v-tool.ps1', 'build.ps1', 'README.md', 'HARDWARE_TESTS.md', 'LICENSE', 'THIRD_PARTY_NOTICES')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $package $file)
}
Copy-Item -LiteralPath (Join-Path $root 'tests') -Destination (Join-Path $package 'tests') -Recurse
foreach ($directory in @('files', 'Backups', 'logs', 'state')) {
    [void](New-Item -ItemType Directory -Path (Join-Path $package $directory) -Force)
}

Compress-Archive -LiteralPath $package -DestinationPath $zip -CompressionLevel Optimal
$hash = Get-FileHash -LiteralPath $zip -Algorithm SHA256
[IO.File]::WriteAllText(($zip + '.sha256'), ($hash.Hash.ToLowerInvariant() + '  ' + (Split-Path -Leaf $zip) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
Write-Host "Paket hazır: $zip" -ForegroundColor Green
Write-Host "SHA256: $($hash.Hash)"

