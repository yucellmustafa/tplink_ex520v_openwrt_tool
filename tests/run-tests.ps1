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
    Assert-True (Test-Ex520vRootCompatibility -Model 'EX520v' -Firmware 'EX520v-v1.0_250120') '250120 firmware güvenli çekirdek root profiliyle kabul edilir'
    Assert-False (Test-Ex520vRootCompatibility -Model 'EX520v' -Firmware 'EX520v_999999') 'Desteklenmeyen root firmware reddedilir'
    Assert-False (Test-Ex520vRootCompatibility -Model 'EX20v' -Firmware 'EX520v_260514') 'Yanlış model root işleminde reddedilir'

    $missingProfile = [pscustomobject]@{ Kind='Stock'; IdentityFile=(Join-Path $temporary 'missing-key'); KnownHostsFile=(Join-Path $temporary 'missing-hosts') }
    Assert-False (Test-Ex520vSshProfile $missingProfile) 'Eksik SSH anahtarı reddedilir'

    $layout = @('boot','u-boot-env','misc_ro','misc_rw','ubi0','ubi1','bflag','container')
    Assert-True (Test-Ex520vFlashLayout $layout) 'Beklenen MTD düzeni kabul edilir'
    Assert-False (Test-Ex520vFlashLayout @('boot','ubi0','ubi1')) 'Eksik MTD düzeni reddedilir'

    Assert-Equal (Resolve-Ex520vSystemState -Transport Stock -Model EX520v -CommandLine 'ubi.mtd=ubi1') 'Stok' 'Stok ubi1 durumu algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport Stock -Model EX520v -CommandLine 'ubi.mtd=ubi0') 'Stok' 'Tam yedekten dönen birincil stok ubi0 durumu algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport Stock -Model EX20v -CommandLine 'ubi.mtd=ubi1') 'Yanlış cihaz' 'Yanlış cihaz modeli algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs tmpfs -Trial 1 -BootIndex 1 -TrialMarker armed) 'RAM deneme' 'RAM deneme durumu algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs tmpfs -Trial 1 -BootIndex '' -TrialMarker armed) 'RAM deneme' 'Flash hazırlığı sonrası RAM denemesi algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs tmpfs -Trial '' -BootIndex '' -TrialMarker '') 'OpenWrt RAM' 'Fallback henüz etkinleşmemiş initramfs ayrı durum olarak algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs tmpfs -Trial 1 -BootIndex '' -TrialMarker '') 'OpenWrt RAM' 'Stok yazma betiğinin bıraktığı işaretsiz initramfs fallback hazırlığına alınır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs overlay -RomFs squashfs -OverlayFs ubifs -RootSource '/dev/root' -OverlaySource '/dev/ubi0_3' -Trial 1) 'Flash deneme' 'Flash deneme durumu gerçek mount düzeniyle algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs overlay -RomFs squashfs -OverlayFs ubifs -RootSource '/dev/root' -OverlaySource '/dev/ubi0_3' -Trial '') 'Kalıcı OpenWrt' 'Kalıcı OpenWrt durumu gerçek mount düzeniyle algılanır'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs overlay -RomFs squashfs -OverlayFs ubifs -OverlaySource '/dev/ubi1_3' -Trial 1) 'Bilinmiyor' 'Yanlış UBI slotu flash OpenWrt sayılmaz'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'other,router' -RootFs tmpfs -Trial 1 -BootIndex 1 -TrialMarker armed) 'Bilinmiyor' 'Yanlış OpenWrt board reddedilir'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -RootFs overlay -RomFs squashfs -Trial 1 -BootIndex 1 -TrialMarker armed) 'Overlay eksik (RAM)' 'Flash üstündeki geçici overlay initramfs denemesi sayılmaz'
    Assert-Equal (Resolve-Ex520vSystemState -Transport OpenWrt -BoardName 'tplink,ex520v' -CommandLine 'ubi.mtd=ubi0' -RootFs overlay -RomFs squashfs -OverlayFs ubifs -OverlaySource '/dev/ubi2_0' -OverlayMtdName ubi) 'Genişletilmiş OpenWrt' 'Geniş overlay UBI cihaz numarasından bağımsız tanınır'

    $inventory=@'
SCHEMA=1
BOARD=tplink,ex520v
UID=0
BOOTID=de305d54-75b4-431b-adb2-eb6b9e546014
CMDLINE=ubi.mtd=ubi0
ROOTFS=overlay
ROMFS=squashfs
OVERLAYFS=ubifs
OVERLAYSRC=/dev/ubi0_3
BOOTIDX=
TRIAL=
TRIALMARK=
ROOT_TOTAL_KIB=248000
ROOT_AVAILABLE_KIB=247000
PART=mtd0|boot|0|2097152|262144
PART=mtd1|u-boot-env|2097152|1048576|262144
PART=mtd2|misc_ro|3145728|15728640|262144
PART=mtd3|misc_rw|18874368|15728640|262144
PART=mtd4|ubi0|34603008|41943040|262144
PART=mtd5|ubi|76546048|426770432|262144
UBI=ubi2|5|253952|1500
VOL=ubi2|ubi2_0|rootfs_data|1500
UBI=ubi0|4|253952|0
VOL=ubi0|ubi0_3|rootfs_data|70
COMPLETE=1
'@
    $storage=& $coreModule { param($value) ConvertFrom-Ex520vStorageText $value } $inventory
    Assert-True (Get-Ex520vExpansionPlan $storage).ReadyForPreflight 'Geniş DTS ile açılmış küçük kalıcı overlay son aşamaya alınır'
    Assert-Equal (Get-Ex520vExpansionPlan $storage).TargetBytes 426770432 '407 MiB ham UBI boyutu kesin hesaplanır'
    $badBoundary=& $coreModule { param($value) ConvertFrom-Ex520vStorageText $value } ($inventory.Replace('76546048|426770432','76808192|426770432'))
    Assert-False (Get-Ex520vExpansionPlan $badBoundary).ReadyForPreflight 'Bir eraseblock kaymış başlangıç yazmayı engeller'
    $stockTail="PART=mtd5|ubi1|76546048|41943040|262144`nPART=mtd6|bflag|118489088|15728640|262144`nPART=mtd7|misc_rw_bak|134217728|15728640|262144`nPART=mtd8|misc_isp|149946368|15728640|262144`nPART=mtd9|runtime_data|165675008|15728640|262144`nPART=mtd10|container|181403648|209715200|262144"
    $small=& $coreModule { param($value) ConvertFrom-Ex520vStorageText $value } ($inventory.Replace('PART=mtd5|ubi|76546048|426770432|262144',$stockTail))
    Assert-True (Get-Ex520vExpansionPlan $small).ReadyForPreflight 'Tam stok haritası ve kalıcı overlay SSH bootstrap aşamasına alınır'
    Assert-Equal (Get-Ex520vExpansionPlan $small).Stage 'bootstrap' 'SSH başlangıcı ile stok silme aşaması ayrılır'
    $ramOverlay=& $coreModule { param($value) ConvertFrom-Ex520vStorageText $value } ($inventory.Replace('OVERLAYFS=ubifs','OVERLAYFS=').Replace('OVERLAYSRC=/dev/ubi0_3','OVERLAYSRC='))
    Assert-False (Get-Ex520vExpansionPlan $ramOverlay).ReadyForPreflight 'tmpfs overlay kullanan flash sistemi genişletmede reddedilir'
    Assert-True (Get-Ex520vExpansionPlan $ramOverlay).OverlayMissing 'Eksik kalıcı overlay açıkça raporlanır'
    $expandedText=$inventory.Replace('OVERLAYSRC=/dev/ubi0_3','OVERLAYSRC=/dev/ubi2_0')
    $expanded=& $coreModule { param($value) ConvertFrom-Ex520vStorageText $value } $expandedText
    Assert-Equal $expanded.OverlayMtdName 'ubi' 'Overlay doğru MTD bölümüne sysfs üzerinden bağlanır'
    Assert-True (Get-Ex520vExpansionPlan $expanded).AlreadyExpanded 'Genişletilmiş kalıcı sistem ikinci kez biçimlendirmeye alınmaz'
    Assert-False (Get-Ex520vExpansionPlan $expanded).ReadyForPreflight 'Çalışan kalıcı kök üzerinde genişletme yazması engellenir'
    foreach ($invalidInventory in @($inventory.Replace('COMPLETE=1',''), $inventory.Replace('UID=0','UID=1000'), ($inventory + "`nPART=mtd5|ubi|76546048|426770432|262144"))) {
        $rejected=$false
        try { & $coreModule { param($value) ConvertFrom-Ex520vStorageText $value } $invalidInventory | Out-Null } catch { $rejected=$true }
        Assert-True $rejected 'Eksik, yetkisiz veya yinelenmiş envanter reddedilir'
    }

    $stock = New-MockState
    Assert-True (Test-Ex520vOperationAllowed -Action Backup -LiveState $stock).Allowed 'Doğru stok durumda yedeklemeye izin verilir'
    Assert-False (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $stock -BackupComplete:$false -FirmwareValid:$true).Allowed 'Yedeksiz RAM kurulumu engellenir'
    Assert-False (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $stock -BackupComplete:$true -FirmwareValid:$false).Allowed 'Hatalı firmware ile RAM kurulumu engellenir'
    Assert-True (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $stock -BackupComplete:$true -FirmwareValid:$true).Allowed 'Doğru sırada RAM kurulumuna izin verilir'

    $primaryStock = New-MockState -BootIndex '' -CommandLine 'ubi.mtd=ubi0'
    Assert-True (Test-Ex520vOperationAllowed -Action Backup -LiveState $primaryStock).Allowed 'Birincil ubi0 üzerinden çalışan stok sistem yedeklenebilir'
    Assert-False (Test-Ex520vOperationAllowed -Action RamTrial -LiveState $primaryStock -BackupComplete:$true -FirmwareValid:$true).Allowed 'RAM kurulumu öncesinde stok ubi1 şartı korunur'
    $unknownStockSlot = New-MockState -BootIndex '' -CommandLine 'ubi.mtd=ubi2'
    Assert-False (Test-Ex520vOperationAllowed -Action Backup -LiveState $unknownStockSlot).Allowed 'Bilinmeyen stok UBI slotunda yedekleme engellenir'

    $ram = New-MockState -System 'RAM deneme' -BootIndex '1' -CommandLine '' -Trial '1' -TrialMarker 'armed'
    Assert-True (Test-Ex520vOperationAllowed -Action Flash -LiveState $ram -BackupComplete:$true -FirmwareValid:$true).Allowed 'Doğrulanmış RAM ortamında flash aşaması açılır'
    $expandedRam = New-MockState -System 'RAM deneme' -BootIndex '1' -CommandLine 'ubi.mtd=ubi0' -Trial '1' -TrialMarker 'armed'
    $expandedRam.MtdNames = @('boot','u-boot-env','misc_ro','misc_rw','ubi0','ubi')
    Assert-True (Test-Ex520vOperationAllowed -Action Flash -LiveState $expandedRam -BackupComplete:$true -FirmwareValid:$true).Allowed 'Geniş DTS initramfs düzeni flash aşamasında kabul edilir'
    $ramNoFallback = New-MockState -System 'RAM deneme' -BootIndex '' -CommandLine '' -Trial '1' -TrialMarker 'failed'
    Assert-False (Test-Ex520vOperationAllowed -Action Flash -LiveState $ramNoFallback -BackupComplete:$true -FirmwareValid:$true).Allowed 'Stok fallback yoksa flash engellenir'
    Assert-False (Test-Ex520vOperationAllowed -Action Confirm -LiveState $ram).Allowed 'RAM ortamında kalıcılaştırma engellenir'

    $flash = New-MockState -System 'Flash deneme' -BootIndex '1' -CommandLine '' -Trial '1' -TrialMarker 'armed'
    Assert-True (Test-Ex520vOperationAllowed -Action Confirm -LiveState $flash).Allowed 'Flash deneme ortamında kalıcılaştırma açılır'
    $flashNoFallback = New-MockState -System 'Flash deneme' -BootIndex '' -CommandLine '' -Trial '1' -TrialMarker ''
    Assert-False (Test-Ex520vOperationAllowed -Action Confirm -LiveState $flashNoFallback).Allowed 'Stok fallback yeniden kurulmadan kalıcılaştırma engellenir'
    $disconnected = New-MockState -System 'Flash deneme' -RootSsh:$false -Trial '1'
    Assert-False (Test-Ex520vOperationAllowed -Action Confirm -LiveState $disconnected).Allowed 'SSH kesilmişse kritik aşama engellenir'

    Assert-True (Test-Ex520vRemoteCompletion -Action RamTrial -ExitCode 0 -Output '[ex520v] DONE: slot ubi0 holds OpenWrt, next boot is a trial boot') 'RAM yazma başarı işareti kabul edilir'
    Assert-False (Test-Ex520vRemoteCompletion -Action RamTrial -ExitCode 255 -Output '') 'SSH kopması başarı sayılmaz'
    Assert-False (Test-Ex520vRemoteCompletion -Action Flash -ExitCode 0 -Output 'read-back mismatch on rootfs') 'UBI geri okuma hatası başarı sayılmaz'
    Assert-False (Test-Ex520vRemoteCompletion -Action Confirm -ExitCode 0 -Output 'tp_boot_idx still set') 'Boot environment doğrulama hatası başarı sayılmaz'
    Assert-False (Test-Ex520vRemoteCompletion -Action Flash -ExitCode 0 -Output 'rebooting') 'Beklenmeyen yeniden başlatma başarı sayılmaz'
    $launch='[ex520v] STARTING: expansion sysupgrade stage=bootstrap; reboot verification required'
    $procdClose="upgrade: Commencing upgrade. Closing all shell sessions.`nCommand failed: ubus call system sysupgrade (Connection failed)"
    Assert-True (& $coreModule {param($o,$e) Test-Ex520vExpansionHandoff -ExitCode 1 -StdOut $o -StdErr $e} $launch $procdClose) 'procd shell kapanması yalnız yeni açılışın beklenmesine izin verir'
    Assert-True (& $coreModule {param($o,$e) Test-Ex520vExpansionHandoff -ExitCode 2 -StdOut '' -StdErr ($o+$e)} $launch $procdClose) 'procd kapanışı stderr ve kod 2 ile döndüğünde yeniden açılış doğrulamasına geçilir'
    Assert-False (& $coreModule {param($o) Test-Ex520vExpansionHandoff -ExitCode 1 -StdOut $o -StdErr 'permission denied'} $launch) 'Gerçek sysupgrade başlatma hatası beklenen kopma sayılmaz'
    Assert-False (& $coreModule {param($o) Test-Ex520vExpansionHandoff -ExitCode 0 -StdOut ($o + ' sysupgrade failed') -StdErr ''} $launch) 'Flash yazma hatası başarılı handoff sayılmaz'

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
    Assert-False (& $coreModule { param($path) Test-Ex520vExpansionBackup -Path $path -Identity ([pscustomobject]@{Sha256=('0'*64);SizeBytes=15MB}) } $partialBackup) 'Yarım stok yedeği genişletmeyi açmaz'
    $calibrationOnly=Join-Path $temporary 'calibration-only'
    [void](New-Item -ItemType Directory -Path $calibrationOnly)
    $miscPath=Join-Path $calibrationOnly 'mtd2-misc_ro.bin'
    $stream=[IO.File]::Create($miscPath)
    try { $stream.SetLength(15MB) } finally { $stream.Dispose() }
    $miscHash=(Get-FileHash -LiteralPath $miscPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $calibrationOnly 'SHA256SUMS'), ($miscHash + "  mtd2-misc_ro.bin`n"))
    $metadata=@{ complete=$true; model='EX520v'; system='Stok'; misc_ro_sha256=$miscHash }
    [IO.File]::WriteAllText((Join-Path $calibrationOnly 'backup.json'), ($metadata | ConvertTo-Json))
    $identity=[pscustomobject]@{ Sha256=$miscHash; SizeBytes=15MB }
    Assert-True (& $coreModule { param($path,$id) Test-Ex520vBackupMatchesIdentity -Path $path -Identity $id } $calibrationOnly $identity) 'Kalibrasyon eşleşmesi kendi başına tam stok yedeği kanıtı değildir'
    Assert-False (& $coreModule { param($path,$id) Test-Ex520vExpansionBackup -Path $path -Identity $id } $calibrationOnly $identity) 'Doğru misc_ro olsa bile eksik kalan 10 MTD genişletmeyi engeller'

    $partitionProof=Join-Path $temporary 'partition-proof'
    [void](New-Item -ItemType Directory -Path $partitionProof)
    $proofFile=Join-Path $partitionProof 'mtd6-ubi1.bin'
    [IO.File]::WriteAllBytes($proofFile,[byte[]](1,2,3,4))
    $proofHash=(Get-FileHash -LiteralPath $proofFile -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $partitionProof 'SHA256SUMS'),($proofHash + "  mtd6-ubi1.bin`n"))
    [IO.File]::WriteAllText((Join-Path $partitionProof 'backup.json'),' {"complete":true}')
    Assert-Equal (& $coreModule {param($path) Get-Ex520vBackupPartitionHash -Path $path -FileName 'mtd6-ubi1.bin' -ExpectedSize 4} $partitionProof) $proofHash 'Korunmuş stok slotu özeti yedek manifestinden doğrulanır'

    $unknownAfterRestart = New-MockState -System 'Bilinmiyor'
    Assert-False (Test-Ex520vOperationAllowed -Action Flash -LiveState $unknownAfterRestart -BackupComplete:$true -FirmwareValid:$true).Allowed 'Program yeniden açıldığında yerel ilerleme canlı durum yerine geçmez'

    $rootScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'install\stock-install-trial.sh')
    Assert-True ($rootScript -match 'ubi\.mtd=ubi1') 'Referans RAM betiği aktif ubi1 kontrolünü korur'
    Assert-True ($rootScript -match 'read-back mismatch') 'Referans RAM betiği geri okuma kontrolünü korur'
    Assert-True ($rootScript -match 'ex520v_trial 1') 'Referans RAM betiği deneme bayrağını korur'
    $slotScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'install\stock-select-secondary.sh')
    Assert-True ($slotScript.Contains('ubi\.mtd=ubi0') -and $slotScript.Contains('ubicrc32 /dev/mtd$MTD')) 'Stok slot geçişi aktif ubi0 ve yedek CRC değerini yeniden doğrular'
    Assert-True ($slotScript -match 'fw_setenv ex520v_trial\s*\nfw_setenv tp_boot_idx 1') 'Stok slot geçişi güvenli environment yazma sırasını korur'
    Assert-False ($slotScript -match 'ubiformat|ubiupdatevol|\bmtd\s+.*\bwrite\b') 'Stok slot geçişi hiçbir MTD veya UBI yazma komutu içermez'
    $armScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'install\openwrt-arm-trial.sh')
    Assert-True ($armScript -match 'fw_printenv -c "\$ENV_CONFIG"' -and $armScript -match 'fw_setenv -c "\$ENV_CONFIG" tp_boot_idx 1') 'RAM denemesi firmware yapılandırmasına bağlı olmadan stok fallback etkinleştirir'
    Assert-True ($armScript -match 'printf ''armed\\n'' > /tmp/ex520v-trial') 'RAM denemesi yalnız environment geri okumasından sonra canlı işaret üretir'
    Assert-False ($armScript -match 'ubiformat|ubiupdatevol|\bmtd\s+.*\bwrite\b') 'RAM fallback hazırlığı MTD veya UBI veri bölümü yazmaz'
    $flashArmScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'install\openwrt-arm-flash-trial.sh')
    Assert-True ($flashArmScript -match 'ex520v_trial' -and $flashArmScript -match 'tp_boot_idx 1') 'Flash deneme açılışı stok fallback değerini yeniden kurar'
    Assert-True ($flashArmScript -match 'expected-merged-ubi1' -and $flashArmScript -match 'count=160' -and $flashArmScript -match 'preserved stock ubi1 does not match') 'Birleşik DTS düzeninde fallback yalnız yedekteki stok slotu birebir eşleşirse kurulur'
    Assert-False ($flashArmScript -match 'ubiformat|ubiupdatevol|\bmtd\s+.*\bwrite\b') 'Flash fallback hazırlığı MTD veya UBI veri bölümü yazmaz'
    $returnStockScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'install\openwrt-return-stock.sh')
    Assert-True ($returnStockScript -match 'expected-merged-ubi1' -and $returnStockScript -match 'count=160') 'Stok dönüşü birleşik DTS altında korunmuş 40 MiB slotu yedek özetiyle doğrular'
    Assert-True ($returnStockScript -match '/sys/class/ubi/ubi\$\{UBIDEV\}_\*') 'Klasik ubi1 doğrulaması gerçek sysfs volume yollarını kullanır'
    $stockRestoreScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'install\openwrt-restore-stock-expanded.sh')
    $storageSource = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Ex520v.Storage.ps1')
    Assert-True ($stockRestoreScript -match 'check_member mtd5-ubi0\.bin 41943040') 'Geniş düzenden stok dönüş birincil stok slotunu pakette doğrular'
    Assert-True ($stockRestoreScript -match 'ubidetach -m "\$BOOT_MTD"') 'Birincil stok slotu yalnız RAM pivotundan sonra ayrılır'
    Assert-True ($stockRestoreScript -match 'read-back mismatch: mtd5-ubi0\.bin') 'Birincil stok slotu geri okuma ile doğrulanır'
    Assert-True ($stockRestoreScript -match 'fw_setenv -c "\$ENV_CONFIG" tp_boot_idx\s*\n') 'Tam stok dönüş varsayılan ubi0 slotunu seçer'
    Assert-True ($stockRestoreScript -match 'cat /tmp/sysinfo/board_name') 'RAM pivot kimlik denetimi minimal stage2 kullanıcı alanıyla çalışır'
    Assert-True ($stockRestoreScript -match 'busybox tr -d') 'RAM pivot manifest denetimi kopyalanmayan tr bağlantısına bağımlı değildir'
    Assert-True ($stockRestoreScript -match 'install_file /lib/upgrade/stage2') 'İncelenmiş stage2 dosyası RAM köküne açıkça kopyalanır'
    Assert-False ($stockRestoreScript -match '192\.168\.1\.2|19876|execute-check|stage2-check') 'Geçici RAM tanı ağı üretim betiğinde kalmaz'
    Assert-True ($stockRestoreScript -match 'mtd -q -f -p "\$offset" write - "/dev/mtd\$DATA_MTD"') 'Doğrulanmış ham stok bölgeleri doğrudan MTD aygıt yoluna yazılır'
    Assert-True ($stockRestoreScript -match 'mtd -q -f write - "/dev/mtd\$BOOT_MTD"') 'Doğrulanmış ham birincil stok slotu doğrudan MTD aygıt yoluna yazılır'
    Assert-True ($storageSource -match 'boot-slots-hashed-and-mutable-regions-readable') 'Stok açılışı kalıcı boot slotlarını hashleyip değişebilir veri bölgelerini okunabilirlikle doğrular'
    $toolSource = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'ex520v-tool.ps1')
    Assert-True ($toolSource -match "(?s)restorePending.*Start-Ex520vStockRestoreFromBackup") 'Menü 7 stok açılışından sonra bekleyen doğrulamayı NAND yazmadan sürdürür'
    Assert-True ($stockRestoreScript -match '/sys/class/mtd/mtd\$index/dev') 'RAM pivot eksik MTD aygıt düğümünü çekirdeğin major/minor değeriyle kurar'
    Assert-True ($stockRestoreScript -match 'mknod "\$node" c "\$major" "\$minor"') 'RAM pivot MTD karakter aygıtını güvenilir sysfs değeriyle oluşturur'
    foreach ($shellName in @('backup-stock.sh', 'stock-select-secondary.sh', 'stock-install-trial.sh', 'openwrt-arm-trial.sh', 'openwrt-arm-flash-trial.sh', 'openwrt-trial-to-flash.sh', 'openwrt-confirm.sh', 'openwrt-return-stock.sh', 'openwrt-storage-inspect.sh', 'openwrt-expand-storage.sh', 'openwrt-repair-overlay.sh', 'openwrt-restore-stock-expanded.sh')) {
        $shellBytes = [IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $PSScriptRoot) "install\$shellName"))
        Assert-False ($shellBytes -contains 13) "$shellName yalnız LF satır sonu içerir"
    }
    $confirmScript = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'install\openwrt-confirm.sh'))
    Assert-True ($confirmScript.Contains('ubi\.mtd=ubi0')) 'Kalıcılaştırma betiği aktif ubi0 boot kontrolünü korur'
    Assert-True ($confirmScript.Contains('/dev/ubi0_3')) 'Kalıcılaştırma betiği ubi0 overlay kontrolünü korur'
    foreach ($powerShellName in @('ex520v-tool.ps1', 'build.ps1', 'modules\Ex520v.Core.psm1', 'modules\Ex520v.Storage.ps1', 'tests\run-tests.ps1')) {
        $powerShellBytes = [IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $PSScriptRoot) $powerShellName))
        $hasUtf8Bom = $powerShellBytes.Length -ge 3 -and $powerShellBytes[0] -eq 0xEF -and $powerShellBytes[1] -eq 0xBB -and $powerShellBytes[2] -eq 0xBF
        Assert-True $hasUtf8Bom "$powerShellName Windows PowerShell 5.1 için UTF-8 BOM içerir"
    }
    $rootPython = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'root-tool\ex520_oneclick.py')
    Assert-False ($rootPython -match 'StrictHostKeyChecking=no') 'Entegre root aracı SSH host key doğrulamasını kapatmaz'
    Assert-True ($rootPython -match '"EX520v-v1\.0_250522": "legacy-core"') 'Eski firmware yalnız açık uyumluluk profiliyle desteklenir'
    Assert-True ($rootPython -match '"EX520v-v1\.0_250120": "legacy-core"') '250120 firmware açık legacy-core profiline bağlıdır'
    $persistentHook = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'root-tool\persistent-local-root.sh')
    Assert-True ($persistentHook -match 'if \[ "\$enable_panel_root" != ''1'' \]') 'Firmware bağımlı panel yamaları profil korumasındadır'
    $coreSource=Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Ex520v.Core.psm1')
    $menuSource=Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'ex520v-tool.ps1')
    Assert-True ($menuSource -match 'Test-Ex520vSecondaryStockSlot' -and $menuSource -match 'Read-YesNoConfirmation') 'Menü 4 stok ubi0 açılışını doğrulanmış ubi1 geçişiyle otomatik hazırlar'
    Assert-True ($menuSource -match "Read-Host 'Devam etmek istiyor musunuz\? \(e/H\)'" -and $menuSource -match "Geçersiz seçim\. Yalnızca e veya h yazın; boş bırakılamaz\.") 'Tüm kullanıcı onayları e/H kullanır; boş ve geçersiz girdiyi yeniden sorar'
    Assert-False ($menuSource -match 'if \(-not \$answer -or') 'Boş Enter hiçbir onay ekranında iptal sayılmaz'
    Assert-False ($menuSource -match 'Read-ExactConfirmation|Devam etmek için \$Word yazın|\s-Word\s') 'Kullanıcıdan uzun onay kelimesi istenmez'
    Assert-True ($menuSource -match "@\('RAM deneme', 'OpenWrt RAM'\)" -and $menuSource -match 'Arm-Ex520vRamTrialFallback') 'Menü 4 çıplak initramfs açılışında fallback hazırlığını tamamlar'
    Assert-True ($menuSource -match 'Arm-Ex520vFlashTrialFallback') 'Menü 5 ilk flash açılışında stok fallback değerini yeniden kurar'
    Assert-True ($menuSource -match '(?s)Invoke-ConfirmAction.*BootIndex.*Arm-Ex520vFlashTrialFallback') 'Menü 6 yarım kalan flash yeniden başlatma doğrulamasını güvenle sürdürür'
    Assert-True ($menuSource -match 'Return-Ex520vToStock -LiveState \$state -BackupPath \$backup') 'Menü 7 birleşik DTS stok doğrulamasına aynı cihazın yedeğini verir'
    Assert-True ($menuSource -match 'Stok geri yükleme 10 dakikadan uzun sürebilir' -and $menuSource -match 'pencereyi kapatmayın ve cihazın gücünü kesmeyin') 'Genişletilmiş düzenden stok dönüş uzun süre ve güç kesme uyarısını gösterir'
    Assert-True ($coreSource -match 'fw_printenv -c \"\$envcfg\" -n tp_boot_idx') 'Canlı OpenWrt algılama firmware fw_env.config dosyasına bağımlı değildir'
    foreach ($envScriptName in @('openwrt-trial-to-flash.sh','openwrt-confirm.sh','openwrt-return-stock.sh','openwrt-storage-inspect.sh')) {
        $envScript = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) "install\$envScriptName")
        Assert-True ($envScript -match 'fw_printenv -c "\$ENV_CONFIG"') "$envScriptName açık U-Boot environment yapılandırması kullanır"
    }
    Assert-True ($coreSource -match "ReleaseRepository = 'wmemcmp/ex520v'" -and $coreSource -match "FirmwareCommit = '4c42b65bb00fafde863610fd0e86fdb51ba074cd'") 'Kurulum ve genişletme aynı sabit wmemcmp/ex520v kaynağını kullanır'
    Assert-True ($coreSource -match [regex]::Escape('https://github.com/yucellmustafa/tplink_ex520v_openwrt_tool/releases/download/OpenWrt/tplink_ex520v_openwrt.zip')) 'Firmware tek proje release ZIP adresinden indirilir'
    Assert-False ($coreSource -match '(?m)^\s*Expand-Archive\b') 'Firmware ZIP açma Microsoft.PowerShell.Archive modülüne bağımlı değildir'
    Assert-True ($coreSource -match '\[IO\.Compression\.ZipFile\]::ExtractToDirectory') 'Firmware ZIP yerleşik .NET API ile açılır'
    $buildSource = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'build.ps1')
    $iconPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'icon.png'
    Assert-True (Test-Path -LiteralPath $iconPath -PathType Leaf) 'Uygulama simgesi icon.png kök dizinde bulunur'
    Add-Type -AssemblyName System.Drawing
    $iconImage = [Drawing.Image]::FromFile($iconPath)
    try { Assert-True ($iconImage.Width -eq $iconImage.Height -and $iconImage.Width -ge 256) 'Uygulama simgesi kare ve Windows icon üretimi için yeterli çözünürlüktedir' }
    finally { $iconImage.Dispose() }
    Assert-True ($buildSource -match 'New-Ex520vWindowsIcon' -and $buildSource -match '-IconFile \$iconFile') 'Build icon.png dosyasını çok çözünürlüklü ICO olarak EXE içine gömer'
    Assert-True ($buildSource -match "'icon\.png'") 'Kaynak uygulama simgesi release paketine eklenir'
    Assert-False ($buildSource -match '(?m)^\s*Compress-Archive\b') 'Release ZIP üretimi Microsoft.PowerShell.Archive modülüne bağımlı değildir'
    Assert-True ($buildSource -match 'Get-Command tar\.exe') 'Release ZIP üretimi doğrulanmış Windows tar.exe aracını kullanır'
    Assert-False ($coreSource -match 'raw\.githubusercontent\.com') 'Firmware dosyaları başka deponun raw uçlarından ayrı ayrı indirilmez'
    Assert-True ($coreSource -match 'Test-Ex520vPinnedFirmware') 'Başka EX520v imajları yalnız dosya adına güvenilerek kabul edilmez'
    Assert-False ($menuSource -match 'G > 2|Yalnız eksik kalıcı overlay|Genişletme imajını indir') 'G menüsü tek işlem akışıdır'

    # Exercise the real orchestrator with every device primitive replaced.
    # This proves an already usable big overlay skips a second NAND write and
    # that interrupted config restoration resumes without another sysupgrade.
    $orchestration=& $coreModule {
        param($directory)
        $names=@('Get-Ex520vPaths','Get-Ex520vLiveState','Get-Ex520vStorageReport','Get-Ex520vExpansionPlan','Get-Ex520vLiveMiscRoIdentity','Get-Ex520vLiveUbootSha256','Test-Ex520vExpansionBackup','Save-Ex520vExpansionSettings','Get-Ex520vExpansionFirmware','Install-Ex520vExpandedStorage','Wait-Ex520vExpandedStorage','Restore-Ex520vExpansionSettings','Restart-Ex520vDevice','Invoke-Ex520vSsh','Write-Ex520vOperationRecord')
        $saved=@{}
        foreach($name in $names){$saved[$name]=(Get-Command $name).ScriptBlock}
        $script:storageTest=@{Stage=0;Writes=0;Restores=0;Restarts=0;Directory=$directory;Hash=('a'*64);Fresh=(Join-Path $directory 'fresh-settings.tar.gz')}
        [IO.File]::WriteAllText($script:storageTest.Fresh,'fresh-settings')
        try {
            function script:Get-Ex520vPaths { [pscustomobject]@{State=$script:storageTest.Directory} }
            function script:Get-Ex520vLiveState { param($DeviceIp) [pscustomobject]@{DeviceIp=$DeviceIp;RootSsh=$true;Profile='mock'} }
            function script:Get-Ex520vStorageReport {param($LiveState) [pscustomobject]@{BootId='mock-boot'} }
            function script:Get-Ex520vExpansionPlan {param($Report) [pscustomobject]@{AlreadyExpanded=($script:storageTest.Stage -gt 0);OverlayMissing=$false;Stage='bootstrap'} }
            function script:Get-Ex520vLiveMiscRoIdentity {param($LiveState) [pscustomobject]@{Sha256=$script:storageTest.Hash;SizeBytes=15MB} }
            function script:Get-Ex520vLiveUbootSha256 {param($LiveState) ('b'*64) }
            function script:Test-Ex520vExpansionBackup {param($Path,$Identity) $true }
            function script:Save-Ex520vExpansionSettings {param($LiveState) [pscustomobject]@{Path=$script:storageTest.Fresh;Sha256=(Get-FileHash $script:storageTest.Fresh -Algorithm SHA256).Hash.ToLowerInvariant()} }
            function script:Get-Ex520vExpansionFirmware { [pscustomobject]@{SysupgradePath='mock-image'} }
            function script:Install-Ex520vExpandedStorage {param($LiveState,$SysupgradePath,$BackupPath,[switch]$Execute,$EraseStockConfirmation) $script:storageTest.Writes++;$script:storageTest.Stage=1;[pscustomobject]@{Stage='bootstrap';PreviousBootId='old';ExpectedMiscRoSha256=$script:storageTest.Hash;ExpectedUbootSha256=('b'*64)} }
            function script:Wait-Ex520vExpandedStorage {param($DeviceIp,$PreviousBootId,$Expected,$ExpectedMiscRoSha256,$ExpectedUbootSha256) [pscustomobject]@{BootId='new';OverlaySource='/dev/ubi2_0'} }
            function script:Restore-Ex520vExpansionSettings {param($LiveState,$BackupPath,$SettingsPath,$SettingsSha256) if($SettingsPath -ne $script:storageTest.Fresh){throw 'Stale settings were selected'};$script:storageTest.Restores++;[pscustomobject]@{PreviousBootId='new';Proof='proof'} }
            function script:Restart-Ex520vDevice {param($LiveState) $script:storageTest.Restarts++ }
            function script:Invoke-Ex520vSsh {param($Profile,$DeviceIp,$RemoteCommand) 'proof' }
            function script:Write-Ex520vOperationRecord {param($Action,$LiveState,$Result) }
            [void](Start-Ex520vSshStorageExpansion -DeviceIp '192.168.1.1' -BackupPath 'mock-full-backup' -EraseStockConfirmation 'STOK-SIL-407M')
            $oneWrite=$script:storageTest.Writes -eq 1 -and $script:storageTest.Restores -eq 1 -and $script:storageTest.Restarts -eq 1
            $sessionPath=Join-Path $directory 'storage-expansion.json'
            $record=Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
            $completed=$record.Status -eq 'complete'
            $record.Status='pending'
            [IO.File]::WriteAllText($sessionPath,($record|ConvertTo-Json))
            [void](Start-Ex520vSshStorageExpansion -DeviceIp '192.168.1.1' -EraseStockConfirmation 'STOK-SIL-407M')
            $resumed=$script:storageTest.Writes -eq 1 -and $script:storageTest.Restores -eq 2
            [void](Start-Ex520vSshStorageExpansion -DeviceIp '192.168.1.1' -EraseStockConfirmation 'STOK-SIL-407M')
            [pscustomobject]@{OneWrite=$oneWrite;Completed=$completed;ResumeWithoutFlash=$resumed;CompletedIsNoOp=($script:storageTest.Writes -eq 1 -and $script:storageTest.Restores -eq 2)}
        } finally {
            foreach($name in $names){Set-Item -LiteralPath ('Function:script:'+$name) -Value $saved[$name]}
            Remove-Variable -Name storageTest -Scope Script
        }
    } $temporary
    Assert-True $orchestration.OneWrite 'İlk açılışta büyük overlay hazırsa ikinci NAND yazması atlanır; güncel ayarlar geri yüklenir'
    Assert-True $orchestration.Completed 'Tamamlandı kaydı yalnız ayar ve reboot doğrulamasından sonra yazılır'
    Assert-True $orchestration.ResumeWithoutFlash 'Yarım ayar geri yükleme NAND yeniden yazılmadan sürdürülür'
    Assert-True $orchestration.CompletedIsNoOp 'Tamamlanmış genişletme yeniden çalıştırıldığında ayarlar veya NAND değiştirilmez'
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}

Write-Host ''
Write-Host ("Sonuç: {0} başarılı, {1} başarısız" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
