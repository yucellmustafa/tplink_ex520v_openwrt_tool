# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$Version = '0.7.8',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$releaseRoot = Join-Path $root 'release'
$packageName = 'EX520v-OpenWrt-Tool-' + ($Version -replace '[^A-Za-z0-9._-]', '_')
$package = Join-Path $releaseRoot $packageName
$zip = Join-Path $releaseRoot ($packageName + '-windows-x64.zip')
$sourceIcon = Join-Path $root 'icon.png'

function New-Ex520vWindowsIcon {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePng,
        [Parameter(Mandatory = $true)][string]$DestinationIco
    )

    Add-Type -AssemblyName System.Drawing
    if (-not (Test-Path -LiteralPath $SourcePng -PathType Leaf)) { throw 'Uygulama simgesi icon.png bulunamadı.' }
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $images = New-Object 'System.Collections.Generic.List[byte[]]'
    $source = [Drawing.Image]::FromFile($SourcePng)
    try {
        if ($source.Width -ne $source.Height -or $source.Width -lt 256) { throw 'icon.png kare ve en az 256x256 piksel olmalıdır.' }
        foreach ($size in $sizes) {
            $bitmap = New-Object Drawing.Bitmap($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([Drawing.Color]::Transparent)
                    $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
                    $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.DrawImage($source, 0, 0, $size, $size)
                }
                finally { $graphics.Dispose() }
                $memory = New-Object IO.MemoryStream
                try {
                    $bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
                    [void]$images.Add($memory.ToArray())
                }
                finally { $memory.Dispose() }
            }
            finally { $bitmap.Dispose() }
        }
    }
    finally { $source.Dispose() }

    $stream = [IO.File]::Open($DestinationIco, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        [uint32]$offset = 6 + (16 * $sizes.Count)
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $dimension = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$index].Length)
            $writer.Write($offset)
            $offset += [uint32]$images[$index].Length
        }
        foreach ($image in $images) { $writer.Write([byte[]]$image) }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

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
$iconFile = Join-Path $package 'icon.ico'
New-Ex520vWindowsIcon -SourcePng $sourceIcon -DestinationIco $iconFile
Invoke-ps2exe -InputFile (Join-Path $root 'ex520v-tool.ps1') -OutputFile $exe -x64 -STA -IconFile $iconFile -Title 'TP-Link EX520v OpenWrt Tool' -Product 'TP-Link EX520v OpenWrt Tool' -Version $Version -Copyright 'GPL-3.0-or-later contributors'
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
foreach ($file in @('ex520v-tool.ps1', 'build.ps1', 'README.md', 'HARDWARE_TESTS.md', 'LICENSE', 'THIRD_PARTY_NOTICES', 'icon.png')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $package $file)
}
Copy-Item -LiteralPath (Join-Path $root 'tests') -Destination (Join-Path $package 'tests') -Recurse
Get-ChildItem -LiteralPath (Join-Path $package 'tests') -Directory -Recurse -Filter '__pycache__' |
    Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath (Join-Path $package 'tests') -File -Recurse -Filter '*.pyc' |
    Remove-Item -Force
foreach ($directory in @('files', 'Backups', 'logs', 'state')) {
    [void](New-Item -ItemType Directory -Path (Join-Path $package $directory) -Force)
}

$tar = Get-Command tar.exe -ErrorAction Stop
& $tar.Source -a -cf $zip -C $releaseRoot $packageName
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zip -PathType Leaf)) {
    throw 'Windows ZIP paketi tar.exe ile oluşturulamadı.'
}
$hash = Get-FileHash -LiteralPath $zip -Algorithm SHA256
[IO.File]::WriteAllText(($zip + '.sha256'), ($hash.Hash.ToLowerInvariant() + '  ' + (Split-Path -Leaf $zip) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
Write-Host "Paket hazır: $zip" -ForegroundColor Green
Write-Host "SHA256: $($hash.Hash)"

