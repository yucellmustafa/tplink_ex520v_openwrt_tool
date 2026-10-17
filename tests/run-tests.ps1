# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Ex520v.Core.psm1') -Force -DisableNameChecking

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Name)
    if ($Condition) { Write-Host "[OK] $Name" -ForegroundColor Green; $script:Passed++ }
    else { Write-Host "[HATA] $Name" -ForegroundColor Red; $script:Failed++ }
}

function Assert-False {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Name)
    Assert-True -Condition (-not $Condition) -Name $Name
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Name)
    Assert-True -Condition ($Actual -eq $Expected) -Name "$Name (beklenen=$Expected, bulunan=$Actual)"
}

function New-MockState {
    param(
        [string]$System = 'Stok', [string]$Model = 'EX520v', [bool]$RootSsh = $true,
        [string]$BootIndex = '1', [string]$CommandLine = 'console=ttyS0 ubi.mtd=ubi1',
        [string]$Trial = '', [string]$TrialMarker = ''
    )
    [pscustomobject]@{
        DeviceIp = '192.168.1.1'; System = $System; Model = $Model; RootSsh = $RootSsh
        BootIndex = $BootIndex; CommandLine = $CommandLine; Trial = $Trial; TrialMarker = $TrialMarker
        MtdNames = @('boot','u-boot-env','misc_ro','misc_rw','ubi0','ubi1','bflag','container')
        Profile = [pscustomobject]@{ Id = 'test-device'; Port = 2222 }
    }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ex520v-tests-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporary)
try {
    Assert-True (Test-Ex520vIPv4 '192.168.1.1') 'Geçerli IPv4 kabul edilir'
    Assert-False (Test-Ex520vIPv4 '192.168.1.1; reboot') 'Komut eklenmiş adres reddedilir'
    Assert-False (Test-Ex520vIPv4 '::1') 'IPv6 cihaz adresi reddedilir'

    $coreModule = Get-Module Ex520v.Core
    $parsedLines = & $coreModule { ConvertFrom-KeyValueText "FIRST=one`nSECOND=two`n" }
    Assert-Equal $parsedLines.FIRST 'one' 'LF satır sonlu cihaz çıktısının ilk alanı ayrıştırılır'
    Assert-Equal $parsedLines.SECOND 'two' 'LF satır sonlu cihaz çıktısının sonraki alanı ayrıştırılır'

    Assert-True (Test-Ex520vRootCompatibility -Model 'EX520v' -Firmware 'EX520v_260514') 'Desteklenen root firmware kabul edilir'
    Assert-True (Test-Ex520vRootCompatibility -Model 'EX520v' -Firmware 'EX520v-v1.0_250522') 'Eski firmware çekirdek root profili kabul edilir'
    Assert-False (Test-Ex520vRootCompatibility -Model 'EX520v' -Firmware 'EX520v_999999') 'Desteklenmeyen root firmware reddedilir'
    Assert-False (Test-Ex520vRootCompatibility -Model 'EX20v' -Firmware 'EX520v_260514') 'Yanlış model root işleminde reddedilir'

    $missingProfile = [pscustomobject]@{ Kind='Stock'; IdentityFile=(Join-Path $temporary 'missing-key'); KnownHostsFile=(Join-Path $temporary 'missing-hosts') }
    Assert-False (Test-Ex520vSshProfile $missingProfile) 'Eksik SSH anahtarı reddedilir'

    $layout = @('boot','u-boot-env','misc_ro','misc_rw','ubi0','ubi1','bflag','container')
    Assert-True (Test-Ex520vFlashLayout $layout) 'Beklenen MTD düzeni kabul edilir'
    Assert-False (Test-Ex520vFlashLayout @('boot','ubi0','ubi1')) 'Eksik MTD düzeni reddedilir'

    Assert-Equal (Resolve-Ex520vSystemState -Transport Stock -Model EX520v -CommandLine 'ubi.mtd=ubi1') 'Stok' 'Stok ubi1 durumu algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport Stock -Model EX20v -CommandLine 'ubi.mtd=ubi1') 'Yanlış cihaz' 'Yanlış cihaz modeli algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs tmpfs -Trial 1 -BootIndex 1 -TrialMarker armed) 'RAM deneme' 'RAM deneme durumu algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs tmpfs -Trial 1 -BootIndex '' -TrialMarker armed) 'RAM deneme' 'Flash hazırlığı sonrası RAM denemesi algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs overlay -RomFs squashfs -OverlayFs ubifs -RootSource '/dev/root' -OverlaySource '/dev/ubi0_3' -Trial 1) 'Flash deneme' 'Flash deneme durumu gerçek mount düzeniyle algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs overlay -RomFs squashfs -OverlayFs ubifs -RootSource '/dev/root' -OverlaySource '/dev/ubi0_3' -Trial '') 'Kalıcı OpenWrt' 'Kalıcı OpenWrt durumu gerçek mount düzeniyle algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs overlay -RomFs squashfs -OverlayFs ubifs -OverlaySource '/dev/ubi1_3' -Trial 1) 'Bilinmiyor' 'Yanlış UBI slotu flash OpenWrt sayılmaz'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'other,router' -RootFs tmpfs -Trial 1 -BootIndex 1 -TrialMarker armed) 'Bilinmiyor' 'Yanlış OpenWrt board reddedilir'

    $stock = New-MockState
    Assert-True (Test-Ex520vOperationAllowed -Action Backup -LiveState $stock).Allowed 'Doğru stok durumda yedeklemeye izin verilir'
    Assert-False (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $stock -BackupComplete:$false -FirmwareValid:$true).Allowed 'Yedeksiz RAM kurulumu engellenir'
    Assert-False (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $stock -BackupComplete:$true -FirmwareValid:$false).Allowed 'Hatalı firmware ile RAM kurulumu engellenir'
    Assert-True (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $stock -BackupComplete:$true -FirmwareValid:$true).Allowed 'Doğru sırada RAM kurulumuna izin verilir'

    $wrongSlot = New-MockState -BootIndex '0' -CommandLine 'ubi.mtd=ubi0'
    Assert-False (Test-Ex520vOperationAllowed -Action Backup -LiveState $wrongSlot).Allowed 'Yanlış stok slotunda yedek işlemi engellenir'
    Assert-False (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $wrongSlot -BackupComplete:$true -FirmwareValid:$true).Allowed 'Yanlış stok slotunda kurulum engellenir'

    $ram = New-MockState -System 'RAM deneme' -BootIndex '1' -CommandLine '' -Trial '1' -TrialMarker 'armed'
    Assert-True (Test-Ex520vOperationAllowed -Action Flash -LiveState $ram -BackupComplete:$true -FirmwareValid:$true).Allowed 'Doğrulanmış RAM ortamında flash aşaması açılır'
    $ramNoFallback = New-MockState -System 'RAM deneme' -BootIndex '' -CommandLine '' -Trial '1' -TrialMarker 'failed'
    Assert-False (Test-Ex520vOperationAllowed -Action Flash -LiveState $ramNoFallback -BackupComplete:$true -FirmwareValid:$true).Allowed 'Stok fallback yoksa flash engellenir'
    Assert-False (Test-Ex520vOperationAllowed -Action Confirm -LiveState $ram).Allowed 'RAM ortamında kalıcılaştırma engellenir'

    $flash = New-MockState -System 'Flash deneme' -BootIndex '1' -CommandLine '' -Trial '1' -TrialMarker 'armed'
    Assert-True (Test-Ex520vOperationAllowed -Action Confirm -LiveState $flash).Allowed 'Flash deneme ortamında kalıcılaştırma açılır'
    $disconnected = New-MockState -System 'Flash deneme' -RootSsh:$false -Trial '1'
    Assert-False (Test-Ex520vOperationAllowed -Action Confirm -LiveState $disconnected).Allowed 'SSH kesilmişse kritik aşama engellenir'

    Assert-True (Test-Ex520vRemoteCompletion -Action RamTrial -ExitCode 0 -Output '[ex520v] DONE: slot ubi0 holds OpenWrt, next boot is a trial boot') 'RAM yazma başarı işareti kabul edilir'
    Assert-False (Test-Ex520vRemoteCompletion -Action RamTrial -ExitCode 255 -Output '') 'SSH kopması başarı sayılmaz'
    Assert-False (Test-Ex520vRemoteCompletion -Action Flash -ExitCode 0 -Output 'read-back mismatch on rootfs') 'UBI geri okuma hatası başarı sayılmaz'
    Assert-False (Test-Ex520vRemoteCompletion -Action Confirm -ExitCode 0 -Output 'tp_boot_idx still set') 'Boot environment doğrulama hatası başarı sayılmaz'
    Assert-False (Test-Ex520vRemoteCompletion -Action Flash -ExitCode 0 -Output 'rebooting') 'Beklenmeyen yeniden başlatma başarı sayılmaz'

    $vector = Join-Path $temporary 'crc-vector.bin'
    [IO.File]::WriteAllText($vector, '123456789', (New-Object Text.UTF8Encoding($false)))
    Assert-Equal (Get-UbiCrc32 $vector) '0x340bc6d9' 'UBI CRC32 başlangıç değeri standart CRC32 ile karıştırılmaz'

    $badInit = Join-Path $temporary 'openwrt-tplink_ex520v-initramfs-kernel.bin'
    $badSys = Join-Path $temporary 'openwrt-tplink_ex520v-squashfs-sysupgrade.bin'
    $manifest = Join-Path $temporary 'SHA256SUMS.ex520v'
    [IO.File]::WriteAllBytes($badInit, [byte[]](1,2,3,4))
    [IO.File]::WriteAllBytes($badSys, [byte[]](5,6,7,8))
    [IO.File]::WriteAllText($manifest, (('0' * 64) + '  ' + (Split-Path -Leaf $badInit) + "`n" + ('0' * 64) + '  ' + (Split-Path -Leaf $badSys) + "`n"))
    $badFirmware = Test-Ex520vFirmwareSet -InitramfsPath $badInit -SysupgradePath $badSys -ManifestPath $manifest
    Assert-False $badFirmware.Valid 'SHA256 uyuşmazlığı ve bozuk imaj reddedilir'
    Assert-True (($badFirmware.Errors -join ' ') -match 'SHA256') 'SHA256 hata nedeni raporlanır'

    $partialBackup = Join-Path $temporary 'partial-backup'
    [void](New-Item -ItemType Directory -Path $partialBackup)
    [IO.File]::WriteAllText((Join-Path $partialBackup 'backup.json'), '{"complete":false,"device_id":"test-device"}')
    [IO.File]::WriteAllText((Join-Path $partialBackup 'SHA256SUMS'), '')
    Assert-False (Test-Ex520vBackupDirectory -Path $partialBackup -DeviceId 'test-device') 'Yarım yedek tamamlanmış sayılmaz'

    $unknownAfterRestart = New-MockState -System 'Bilinmiyor'
    Assert-False (Test-Ex520vOperationAllowed -Action Flash -LiveState $unknownAfterRestart -BackupComplete:$true -FirmwareValid:$true).Allowed 'Program yeniden açıldığında yerel ilerleme canlı durum yerine geçmez'

    $rootScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'install\stock-install-trial.sh')
    Assert-True ($rootScript -match 'ubi\.mtd=ubi1') 'Referans RAM betiği aktif ubi1 kontrolünü korur'
    Assert-True ($rootScript -match 'read-back mismatch') 'Referans RAM betiği geri okuma kontrolünü korur'
    Assert-True ($rootScript -match 'ex520v_trial 1') 'Referans RAM betiği deneme bayrağını korur'
    foreach ($shellName in @('backup-stock.sh', 'stock-install-trial.sh', 'openwrt-trial-to-flash.sh', 'openwrt-confirm.sh', 'openwrt-return-stock.sh')) {
        $shellBytes = [IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $PSScriptRoot) "install\$shellName"))
        Assert-False ($shellBytes -contains 13) "$shellName yalnız LF satır sonu içerir"
    }
    $confirmScript = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'install\openwrt-confirm.sh'))
    Assert-True ($confirmScript.Contains('ubi\.mtd=ubi0')) 'Kalıcılaştırma betiği aktif ubi0 boot kontrolünü korur'
    Assert-True ($confirmScript.Contains('/dev/ubi0_3')) 'Kalıcılaştırma betiği ubi0 overlay kontrolünü korur'
    foreach ($powerShellName in @('ex520v-tool.ps1', 'build.ps1', 'modules\Ex520v.Core.psm1', 'tests\run-tests.ps1')) {
        $powerShellBytes = [IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $PSScriptRoot) $powerShellName))
        $hasUtf8Bom = $powerShellBytes.Length -ge 3 -and $powerShellBytes[0] -eq 0xEF -and $powerShellBytes[1] -eq 0xBB -and $powerShellBytes[2] -eq 0xBF
        Assert-True $hasUtf8Bom "$powerShellName Windows PowerShell 5.1 için UTF-8 BOM içerir"
    }
    $rootPython = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'root-tool\ex520_oneclick.py')
    Assert-False ($rootPython -match 'StrictHostKeyChecking=no') 'Entegre root aracı SSH host key doğrulamasını kapatmaz'
    Assert-True ($rootPython -match '"EX520v-v1\.0_250522": "legacy-core"') 'Eski firmware yalnız açık uyumluluk profiliyle desteklenir'
    $persistentHook = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'root-tool\persistent-local-root.sh')
    Assert-True ($persistentHook -match 'if \[ "\$enable_panel_root" != ''1'' \]') 'Firmware bağımlı panel yamaları profil korumasındadır'
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}

Write-Host ''
Write-Host ("Sonuç: {0} başarılı, {1} başarısız" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
