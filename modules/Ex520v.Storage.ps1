# SPDX-License-Identifier: GPL-3.0-or-later
# Loaded in Ex520v.Core's module scope; uses its SSH and backup primitives.

function Get-Ex520vExpansionReference {
    $firmware=Get-Ex520vFirmwareReference
    [pscustomobject]@{
        Repository = $firmware.Repository
        Commit = $firmware.Commit
        ArchiveName = $firmware.ArchiveName
        ArchiveUrl = $firmware.ArchiveUrl
        InitramfsName = $firmware.InitramfsName
        InitramfsSha256 = $firmware.InitramfsSha256
        SysupgradeName = $firmware.SysupgradeName
        SysupgradeSha256 = $firmware.SysupgradeSha256
        OffsetBytes = [long]76546048
        SizeBytes = [long]426770432
        EndBytes = [long]503316480
    }
}

function ConvertFrom-Ex520vStorageText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $fields = ConvertFrom-KeyValueText $Text
    if ($fields.SCHEMA -ne '1' -or $fields.COMPLETE -ne '1' -or $fields.UID -ne '0' -or $fields.BOARD -ne 'tplink,ex520v') {
        throw 'Depolama envanteri eksik veya UID 0 / EX520v kimliği doğrulanmadı.'
    }
    if ([string]$fields.BOOTID -notmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or [string]$fields.ROOT_TOTAL_KIB -notmatch '^[1-9][0-9]*$' -or [string]$fields.ROOT_AVAILABLE_KIB -notmatch '^[0-9]+$') { throw 'Önyükleme kimliği veya df ölçümü eksik.' }
    $parts = @(); $devices = @(); $volumes = @()
    foreach ($line in ($Text -split '\r?\n')) {
        $match = [regex]::Match($line, '^PART=(mtd[0-9]+)\|([A-Za-z0-9_-]+)\|([0-9]+)\|([0-9]+)\|([0-9]+)$')
        if ($match.Success) {
            $parts += [pscustomobject]@{ Device=$match.Groups[1].Value; Name=$match.Groups[2].Value; OffsetBytes=[long]$match.Groups[3].Value; SizeBytes=[long]$match.Groups[4].Value; EraseBytes=[long]$match.Groups[5].Value }
        } elseif ($line.StartsWith('PART=')) { throw 'MTD envanter kaydı geçersiz.' }
        $match = [regex]::Match($line, '^UBI=(ubi[0-9]+)\|([0-9]+)\|([0-9]+)\|([0-9]+)$')
        if ($match.Success) {
            $devices += [pscustomobject]@{ Device=$match.Groups[1].Value; MtdDevice=('mtd' + $match.Groups[2].Value); LebBytes=[long]$match.Groups[3].Value; AvailableLebs=[long]$match.Groups[4].Value }
        } elseif ($line.StartsWith('UBI=')) { throw 'UBI envanter kaydı geçersiz.' }
        $match = [regex]::Match($line, '^VOL=(ubi[0-9]+)\|(ubi[0-9]+_[0-9]+)\|([A-Za-z0-9_-]+)\|([0-9]+)$')
        if ($match.Success) {
            $volumes += [pscustomobject]@{ UbiDevice=$match.Groups[1].Value; Device=$match.Groups[2].Value; Name=$match.Groups[3].Value; ReservedLebs=[long]$match.Groups[4].Value }
        } elseif ($line.StartsWith('VOL=')) { throw 'UBI volume kaydı geçersiz.' }
    }
    if (-not $parts.Count -or @($parts.Device | Sort-Object -Unique).Count -ne $parts.Count -or @($parts.Name | Sort-Object -Unique).Count -ne $parts.Count) {
        throw 'MTD bölümleri eksik veya yinelenmiş.'
    }
    foreach ($partition in $parts) {
        if ($partition.SizeBytes -le 0 -or $partition.EraseBytes -le 0 -or $partition.OffsetBytes % $partition.EraseBytes -ne 0 -or $partition.SizeBytes % $partition.EraseBytes -ne 0) { throw 'MTD sınırları geçersiz.' }
    }
    $overlayMtdName = ''
    $source = [regex]::Match([string]$fields.OVERLAYSRC, '^/dev/(ubi[0-9]+)_[0-9]+$')
    if ($source.Success) {
        $ubi = @($devices | Where-Object Device -eq $source.Groups[1].Value)
        if ($ubi.Count -eq 1) {
            $partition = @($parts | Where-Object Device -eq $ubi[0].MtdDevice)
            if ($partition.Count -eq 1) { $overlayMtdName=$partition[0].Name }
        }
    }
    [pscustomobject]@{
        BoardName=[string]$fields.BOARD; BootId=[string]$fields.BOOTID
        CommandLine=[string]$fields.CMDLINE; BootIndex=[string]$fields.BOOTIDX; Trial=[string]$fields.TRIAL; TrialMarker=[string]$fields.TRIALMARK
        RootFs=[string]$fields.ROOTFS; RomFs=[string]$fields.ROMFS
        OverlayFs=[string]$fields.OVERLAYFS; OverlaySource=[string]$fields.OVERLAYSRC; OverlayMtdName=$overlayMtdName
        RootTotalBytes=([long]$fields.ROOT_TOTAL_KIB * 1KB); RootAvailableBytes=([long]$fields.ROOT_AVAILABLE_KIB * 1KB)
        Partitions=@($parts); UbiDevices=@($devices); Volumes=@($volumes)
    }
}

function Get-Ex520vStorageReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState)
    if (-not $LiveState.RootSsh -or $LiveState.Transport -ne 'OpenWrt' -or $LiveState.BoardName -ne 'tplink,ex520v') { throw 'OpenWrt EX520v üzerinde root SSH gerekli.' }
    $scriptPath = Join-Path (Get-Ex520vPaths).Install 'openwrt-storage-inspect.sh'
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath $scriptPath -RemotePath '/tmp/ex520v-storage-inspect.sh'
    $raw = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'sh /tmp/ex520v-storage-inspect.sh'
    ConvertFrom-Ex520vStorageText $raw
}

function Test-Ex520vExpansionLayout {
    param([Parameter(Mandatory = $true)]$Report)
    $expected = @(
        @('boot',0,2097152), @('u-boot-env',2097152,1048576), @('misc_ro',3145728,15728640),
        @('misc_rw',18874368,15728640), @('ubi0',34603008,41943040), @('ubi',76546048,426770432)
    )
    if (@($Report.Partitions).Count -ne $expected.Count) { return $false }
    foreach ($entry in $expected) {
        $found = @($Report.Partitions | Where-Object Name -eq $entry[0])
        if ($found.Count -ne 1) { return $false }
        if ($found[0].OffsetBytes -ne $entry[1] -or $found[0].SizeBytes -ne $entry[2] -or $found[0].EraseBytes -ne 262144) { return $false }
    }
    return $true
}

function Test-Ex520vOriginalStorageLayout {
    param([Parameter(Mandatory = $true)]$Report)
    $expected=@(
        @('boot',0,2097152),@('u-boot-env',2097152,1048576),@('misc_ro',3145728,15728640),@('misc_rw',18874368,15728640),
        @('ubi0',34603008,41943040),@('ubi1',76546048,41943040),@('bflag',118489088,15728640),
        @('misc_rw_bak',134217728,15728640),@('misc_isp',149946368,15728640),@('runtime_data',165675008,15728640),@('container',181403648,209715200)
    )
    if (@($Report.Partitions).Count -ne 11) { return $false }
    foreach($entry in $expected) {
        $part=@($Report.Partitions | Where-Object Name -eq $entry[0])
        if($part.Count -ne 1 -or $part[0].OffsetBytes -ne $entry[1] -or $part[0].SizeBytes -ne $entry[2] -or $part[0].EraseBytes -ne 262144){return $false}
    }
    return $true
}

function Get-Ex520vExpansionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Report)
    $reference=Get-Ex520vExpansionReference
    $wide=Test-Ex520vExpansionLayout $Report
    $original=Test-Ex520vOriginalStorageLayout $Report
    $reasons=New-Object Collections.Generic.List[string]
    if ($Report.BoardName -ne 'tplink,ex520v') { [void]$reasons.Add('Cihaz EX520v değil.') }
    if (-not $wide -and -not $original) { [void]$reasons.Add('İncelenmiş stok veya 407 MiB bölüm haritası gerekli.') }
    if ($Report.RomFs -ne 'squashfs' -or $Report.OverlayFs -ne 'ubifs' -or $Report.OverlayMtdName -ne 'ubi0') { [void]$reasons.Add('SSH geçişi için ubi0 üzerinde kalıcı overlay gerekli. Eksik overlay önce onarılmalı.') }
    if ($Report.Trial -or $Report.BootIndex -or $Report.TrialMarker) { [void]$reasons.Add('Deneme/stok önyükleme bayrakları temizlenmiş olmalı.') }
    $affected = @($Report.Partitions | Where-Object { $_.OffsetBytes -lt $reference.EndBytes -and ($_.OffsetBytes + $_.SizeBytes) -gt $reference.OffsetBytes } | Select-Object -ExpandProperty Name)
    $overlayVolume=@($Report.Volumes | Where-Object { ('/dev/' + $_.Device) -eq $Report.OverlaySource -and $_.Name -eq 'rootfs_data' })
    [pscustomobject]@{
        ReadyForPreflight=($reasons.Count -eq 0); Reasons=@($reasons); ExpandedLayout=$wide
        Stage=$(if($original){'bootstrap'}elseif($wide){'finalize'}else{'unsupported'})
        AlreadyExpanded=($wide -and $Report.OverlayFs -eq 'ubifs' -and $Report.OverlayMtdName -eq 'ubi' -and $overlayVolume.Count -eq 1)
        OverlayMissing=($Report.RomFs -eq 'squashfs' -and -not $Report.OverlayFs)
        TargetBytes=$reference.SizeBytes; AffectedPartitions=$affected
        StockReturnLost=$true
    }
}

function Get-Ex520vExpansionFirmware {
    [CmdletBinding()]
    param()
    $reference=Get-Ex520vExpansionReference
    $firmware=Get-Ex520vLocalFirmware
    if(-not $firmware){$firmware=Get-Ex520vReleaseFirmware}
    if(-not (Test-Ex520vPinnedFirmware $firmware)){throw 'Yalnız sabitlenmiş wmemcmp/ex520v firmware kullanılabilir.'}
    [pscustomobject]@{ InitramfsPath=$firmware.InitramfsPath;SysupgradePath=$firmware.SysupgradePath;Commit=$reference.Commit;SysupgradeSha256=$reference.SysupgradeSha256 }
}

function Get-Ex520vLiveUbootSha256 {
    param([Parameter(Mandatory=$true)]$LiveState)
    $command='m=$(awk -F: ''$2 ~ /"ubi0"/{sub(/^mtd/,"",$1);print $1}'' /proc/mtd); [ -n "$m" ] || exit 31; u=; for d in /sys/class/ubi/ubi[0-9]*; do [ "$(cat "$d/mtd_num" 2>/dev/null)" = "$m" ] && u=${d##*/}; done; [ -n "$u" ] || exit 32; v=; n=0; for d in /sys/class/ubi/$u/${u}_*; do [ "$(cat "$d/name" 2>/dev/null)" = uboot ] && { v=${d##*/}; n=$((n+1)); }; done; [ "$n" = 1 ] || exit 33; sha256sum /dev/$v | cut -d" " -f1'
    $hash=(Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand $command).Trim().ToLowerInvariant()
    if($hash -notmatch '^[a-f0-9]{64}$'){throw 'İkinci aşama U-Boot özeti doğrulanamadı.'}
    return $hash
}

function Test-Ex520vExpansionBackup {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Identity)
    if (-not (Test-Ex520vBackupMatchesIdentity -Path $Path -Identity $Identity -AllowRecoverySnapshot)) { return $false }
    # Verify the whole stock inventory, not just a manifest containing misc_ro.
    $expected=@{ boot=2MB; 'u-boot-env'=1MB; misc_ro=15MB; misc_rw=15MB; ubi0=40MB; ubi1=40MB; bflag=15MB; misc_rw_bak=15MB; misc_isp=15MB; runtime_data=15MB; container=200MB }
    $manifest=@(Get-Content -LiteralPath (Join-Path $Path 'SHA256SUMS') -Encoding UTF8)
    foreach ($name in $expected.Keys) {
        $files=@(Get-ChildItem -LiteralPath $Path -File | Where-Object Name -match ('^mtd[0-9]+-' + [regex]::Escape($name) + '\.bin$'))
        if ($files.Count -ne 1 -or $files[0].Length -ne $expected[$name]) { return $false }
        $line='{0}  {1}' -f (Get-FileHash -LiteralPath $files[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$files[0].Name
        if (@($manifest | Where-Object { $_ -ieq $line }).Count -ne 1) { return $false }
    }
    return $true
}

function Save-Ex520vRecoverySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState)
    $report=Get-Ex520vStorageReport $LiveState
    if ($report.RomFs -ne 'squashfs' -or $report.CommandLine -notmatch '(^|\s)ubi\.mtd=ubi0(\s|$)' -or $report.Partitions.Count -ne 11 -or -not (Test-Ex520vFlashLayout $report.Partitions.Name)) { throw 'Tam yedek için stok bölüm haritasıyla ubi0 üzerinde çalışan OpenWrt gerekli.' }
    $paths=Get-Ex520vPaths
    $name=(Get-Date -Format 'yyyyMMdd-HHmmss') + '-openwrt-recovery-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $partial=Join-Path $paths.Backups ($name + '.partial')
    $final=Join-Path $paths.Backups $name
    [void](New-Item -ItemType Directory -Path $partial -Force)
    $drive=Get-PSDrive -Name ([IO.Path]::GetPathRoot($partial).TrimEnd('\').TrimEnd(':'))
    if ($drive.Free -lt (($report.Partitions | Measure-Object SizeBytes -Sum).Sum + 128MB)) { throw 'Tam kurtarma yedeği için yerel disk alanı yetersiz.' }
    foreach ($item in @(@('proc_mtd.txt','cat /proc/mtd'),@('fw_printenv.txt','fw_printenv'),@('stock.dtb','cat /sys/firmware/fdt'))) {
        Invoke-Ex520vSshToFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand $item[1] -OutputPath (Join-Path $partial $item[0])
    }
    [void](Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'sysupgrade -b /tmp/ex520v-recovery-settings.tar.gz')
    Invoke-Ex520vSshToFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'cat /tmp/ex520v-recovery-settings.tar.gz' -OutputPath (Join-Path $partial 'settings.tar.gz')
    foreach ($part in ($report.Partitions | Sort-Object OffsetBytes)) {
        Write-Host ('NAND yedeği: {0}, {1:N0} MiB' -f $part.Name,($part.SizeBytes / 1MB))
        $destination=Join-Path $partial ($part.Device + '-' + $part.Name + '.bin')
        Invoke-Ex520vSshToFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand ('cat /dev/' + $part.Device) -OutputPath $destination -TimeoutSeconds 1200
        if ((Get-Item -LiteralPath $destination).Length -ne $part.SizeBytes) { throw ('MTD yedeği eksik: ' + $part.Name) }
    }
    $misc=@($report.Partitions | Where-Object Name -eq misc_ro)
    if ($misc.Count -ne 1) { throw 'misc_ro tekil değil.' }
    $identity=[pscustomobject]@{Sha256=(Get-FileHash (Join-Path $partial ($misc[0].Device + '-misc_ro.bin')) -Algorithm SHA256).Hash.ToLowerInvariant();SizeBytes=$misc[0].SizeBytes}
    $metadata=[ordered]@{complete=$true;kind='openwrt-recovery';model='EX520v';system=$LiveState.System;device_id=$identity.Sha256.Substring(0,16);device_ip=$LiveState.DeviceIp;misc_ro_sha256=$identity.Sha256;partition_count=11;created_at=(Get-Date).ToString('o')}
    $manifest=@(Get-ChildItem -LiteralPath $partial -File | Sort-Object Name | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$_.Name })
    [IO.File]::WriteAllText((Join-Path $partial 'SHA256SUMS'),(($manifest -join "`n") + "`n"),$script:Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $partial 'backup.json'),($metadata | ConvertTo-Json),$script:Utf8NoBom)
    if (-not (Test-Ex520vExpansionBackup -Path $partial -Identity $identity)) { throw ('Tam kurtarma yedeği doğrulanamadı: ' + $partial) }
    Move-Item -LiteralPath $partial -Destination $final
    return $final
}

function Repair-Ex520vPersistentOverlay {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState, [switch]$Execute)
    $report=Get-Ex520vStorageReport $LiveState
    if ($report.RomFs -ne 'squashfs' -or $report.OverlayFs -or @($report.Volumes | Where-Object Name -eq rootfs_data).Count) { throw 'Bu işlem yalnız rootfs_data birimi eksik RAM overlay durumunu onarır.' }
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath (Join-Path (Get-Ex520vPaths).Install 'openwrt-repair-overlay.sh') -RemotePath '/tmp/ex520v-repair-overlay.sh'
    $mode=if($Execute){'--repair'}else{'--check'}
    $output=Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand ('sh /tmp/ex520v-repair-overlay.sh ' + $mode) -TimeoutSeconds 180
    if ($Execute -and $output -notlike '*DONE: persistent overlay created*') { throw 'Overlay onarımı doğrulanmadı.' }
    [pscustomobject]@{Output=$output;PreviousBootId=$report.BootId;NeedsReboot=[bool]$Execute}
}

function Test-Ex520vExpansionHandoff {
    param([int]$ExitCode,[string]$StdOut,[string]$StdErr)
    $text=$StdOut + $StdErr
    $procdDisconnect=$ExitCode -ne 0 -and $text -match 'Commencing upgrade\. Closing all shell sessions' -and $text -match 'ubus call system sysupgrade' -and $text -match 'Connection failed'
    return ($text -like '*STARTING: expansion sysupgrade*' -and ($ExitCode -in @(0,255) -or $procdDisconnect) -and $text -notmatch '(?i)(\[ex520v\] ERROR:|sysupgrade failed|image check rejected|permission denied)')
}

function Install-Ex520vExpandedStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$LiveState,
        [Parameter(Mandatory = $true)][string]$SysupgradePath,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [switch]$Execute,
        [string]$EraseStockConfirmation
    )
    # Re-read the device every time; a previous preflight never authorizes writes.
    $fresh=Get-Ex520vLiveState -DeviceIp $LiveState.DeviceIp
    $report=Get-Ex520vStorageReport $fresh
    $plan=Get-Ex520vExpansionPlan $report
    if (-not $plan.ReadyForPreflight) { throw ($plan.Reasons -join ' ') }
    $reference=Get-Ex520vExpansionReference
    if ((Get-FileHash -LiteralPath $SysupgradePath -Algorithm SHA256).Hash -ne $reference.SysupgradeSha256) { throw 'Genişletme imajının sabit SHA256 değeri doğrulanmadı.' }
    $identity=Get-Ex520vLiveMiscRoIdentity $fresh
    $ubootSha256=Get-Ex520vLiveUbootSha256 $fresh
    if (-not (Test-Ex520vExpansionBackup -Path $BackupPath -Identity $identity)) { throw 'Bu cihaza ait tüm 11 stok MTD bölümünü içeren doğrulanmış yedek gerekli.' }
    if ($Execute -and $EraseStockConfirmation -cne 'STOK-SIL-407M') { throw 'Stok alanını silmek için STOK-SIL-407M onayı gerekli.' }
    Send-Ex520vFile -Profile $fresh.Profile -DeviceIp $fresh.DeviceIp -LocalPath $SysupgradePath -RemotePath '/tmp/ex520v-expanded-sysupgrade.bin'
    Send-Ex520vFile -Profile $fresh.Profile -DeviceIp $fresh.DeviceIp -LocalPath (Join-Path (Get-Ex520vPaths).Install 'openwrt-expand-storage.sh') -RemotePath '/tmp/ex520v-expand-storage.sh'
    $command='sh /tmp/ex520v-expand-storage.sh /tmp/ex520v-expanded-sysupgrade.bin'
    $check=Invoke-Ex520vSsh -Profile $fresh.Profile -DeviceIp $fresh.DeviceIp -RemoteCommand ($command + ' --check ' + $ubootSha256) -TimeoutSeconds 120
    if ($check -notlike '*CHECK OK:*') { throw 'Genişletme ön denetimi doğrulanmadı.' }
    if (-not $Execute) { return [pscustomobject]@{ Ready=$true; CheckOutput=$check; PreviousBootId=$report.BootId } }
    Write-Ex520vLog -Level WARN -Message '407 MiB genişletme başlatılıyor; stok ubi1 ve stok veri alanları silinecek.'
    Reset-Ex520vOpenWrtKnownHost -Phase Expanded
    $result=Invoke-Ex520vNativeText -FilePath (Get-Ex520vCommand 'ssh.exe') -Arguments (Get-SshArguments $fresh.Profile $fresh.DeviceIp ($command + ' --erase-stock-407m ' + $ubootSha256)) -TimeoutSeconds 600
    if (-not (Test-Ex520vExpansionHandoff -ExitCode $result.ExitCode -StdOut $result.StdOut -StdErr $result.StdErr)) {
        throw ('Genişletme başlatılamadı veya hata verdi. ' + $result.StdOut + $result.StdErr)
    }
    Write-Ex520vOperationRecord -Action 'ExpansionStarted' -LiveState $fresh -Result 'pending-reboot-verification'
    [pscustomobject]@{ Started=$true; Verified=$false; Stage=$plan.Stage; PreviousBootId=$report.BootId;ExpectedMiscRoSha256=$identity.Sha256;ExpectedUbootSha256=$ubootSha256 }
}

function Wait-Ex520vExpandedStorage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceIp, [Parameter(Mandatory = $true)][string]$PreviousBootId, [ValidateSet('Expanded','WidePending')][string]$Expected='Expanded', [string]$ExpectedMiscRoSha256, [string]$ExpectedUbootSha256, [int]$TimeoutSeconds=420)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $live=Get-Ex520vLiveState -DeviceIp $DeviceIp
            if ($live.RootSsh) {
                $report=Get-Ex520vStorageReport $live
                $plan=Get-Ex520vExpansionPlan $report
                $targetReady=if($Expected -eq 'WidePending'){$plan.AlreadyExpanded -or ($plan.ExpandedLayout -and $report.OverlayFs -eq 'ubifs' -and $report.OverlayMtdName -eq 'ubi0')}else{$plan.AlreadyExpanded -and $report.RootTotalBytes -gt 300MB}
                if ($report.BootId -and $report.BootId -ne $PreviousBootId -and $targetReady -and -not $report.Trial -and -not $report.BootIndex) {
                    if($ExpectedMiscRoSha256 -and (Get-Ex520vLiveMiscRoSha256 $live) -ne $ExpectedMiscRoSha256){throw 'Yeni açılışın kalibrasyon kimliği eşleşmedi.'}
                    if($ExpectedUbootSha256 -and (Get-Ex520vLiveUbootSha256 $live) -ne $ExpectedUbootSha256){throw 'Yeni açılışın U-Boot özeti eşleşmedi.'}
                    Write-Ex520vOperationRecord -Action 'ExpansionBootVerified' -LiveState $live -Result 'layout-verified'
                    return $report
                }
            }
        } catch { Write-Ex520vLog -Level DEBUG -Message ('Genişletme açılışı bekleniyor: ' + $_.Exception.Message) }
        Start-Sleep -Seconds 5
    }
    throw 'Genişletilmiş kalıcı overlay yeniden açılışta doğrulanamadı. Kurulum başarılı sayılmadı.'
}

function Restore-Ex520vExpansionSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState,[Parameter(Mandatory = $true)][string]$BackupPath,[string]$SettingsPath,[string]$SettingsSha256)
    $report=Get-Ex520vStorageReport $LiveState
    if(-not (Get-Ex520vExpansionPlan $report).AlreadyExpanded){throw 'Ayar geri yüklemesi için büyük kalıcı overlay gerekli.'}
    $identity=Get-Ex520vLiveMiscRoIdentity $LiveState
    if(-not (Test-Ex520vExpansionBackup -Path $BackupPath -Identity $identity)){throw 'Ayar yedeği bu cihazın tam NAND yedeğiyle eşleşmiyor.'}
    $settings=if($SettingsPath){$SettingsPath}else{Join-Path $BackupPath 'settings.tar.gz'}
    if(-not (Test-Path -LiteralPath $settings -PathType Leaf)){throw 'Kurtarma ayar arşivi eksik.'}
    if($SettingsPath -and ($SettingsSha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash -ne $SettingsSha256)){throw 'Güncel ayar arşivinin SHA256 değeri doğrulanmadı.'}
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath $settings -RemotePath '/tmp/ex520v-restore-settings.tar.gz'
    [void](Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'sysupgrade -r /tmp/ex520v-restore-settings.tar.gz && sync')
    # Dropbear can start using the restored host key on the very next session.
    # Re-select the pre-migration profile, rather than deleting its host entry.
    $LiveState=Get-Ex520vLiveState -DeviceIp $LiveState.DeviceIp
    if(-not $LiveState.RootSsh){throw 'Geri yüklenen SSH kimliği ile bağlantı doğrulanamadı.'}
    # Verify restored files against the local archive without logging their data.
    $tar=Get-Ex520vCommand 'tar.exe'
    foreach($name in @('etc/config/network','etc/config/wireless','etc/dropbear/dropbear_ed25519_host_key')){
        $temp=[IO.Path]::GetTempFileName()
        try{
            $extract=Invoke-Ex520vNativeToFile -FilePath $tar -Arguments @('-xOf',$settings,$name) -OutputPath $temp
            if($extract.ExitCode -ne 0){throw ('Ayar arşivi eksik: ' + $name)}
            $hash=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
            $remote=Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand ('sha256sum /' + $name)
            if(-not $remote.StartsWith($hash + ' ')){throw ('Ayar geri yükleme doğrulaması başarısız: ' + $name)}
        }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
    }
    $proof=$report.BootId
    if($proof -notmatch '^[a-f0-9-]{36}$'){throw 'Boot kimliği geçersiz.'}
    [void](Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand ("echo '$proof' > /etc/ex520v-storage-proof; sync"))
    [pscustomobject]@{SettingsVerified=$true;Proof=$proof;PreviousBootId=$report.BootId}
}

function Save-Ex520vExpansionSettings {
    param([Parameter(Mandatory = $true)]$LiveState)
    # A full NAND snapshot may be older. Always capture today's settings just
    # before migration instead of restoring potentially stale snapshot settings.
    $directory=Join-Path (Get-Ex520vPaths).State ('storage-settings-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $directory)
    [void](Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'sysupgrade -b /tmp/ex520v-current-settings.tar.gz')
    $path=Join-Path $directory 'settings.tar.gz'
    Invoke-Ex520vSshToFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'cat /tmp/ex520v-current-settings.tar.gz' -OutputPath $path
    $check=Invoke-Ex520vNativeText -FilePath (Get-Ex520vCommand 'tar.exe') -Arguments @('-tzf',$path)
    if($check.ExitCode -ne 0 -or $check.StdOut -notmatch '(?m)^etc/config/network\r?$' -or $check.StdOut -notmatch '(?m)^etc/dropbear/dropbear_ed25519_host_key\r?$'){throw 'Güncel ağ/SSH ayar arşivi eksik.'}
    [pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}

function Find-Ex520vExpansionBackup {
    param([Parameter(Mandatory = $true)]$LiveState)
    $identity=Get-Ex520vLiveMiscRoIdentity $LiveState
    foreach($dir in @(Get-ChildItem -LiteralPath (Get-Ex520vPaths).Backups -Directory | Sort-Object LastWriteTime -Descending)) {
        if($dir.Name -like '*.partial'){continue}
        if(Test-Ex520vExpansionBackup -Path $dir.FullName -Identity $identity){return $dir.FullName}
    }
    return $null
}

function Get-Ex520vPendingStorageSession {
    param([Parameter(Mandatory = $true)][string]$DeviceIp)
    $path=Join-Path (Get-Ex520vPaths).State 'storage-expansion.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try {
        $session=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if($session.DeviceIp -eq $DeviceIp -and $session.Status -eq 'pending'){return $session}
    }catch{}
    return $null
}

function Complete-Ex520vStorageSession {
    param([Parameter(Mandatory = $true)]$Session)
    $live=Get-Ex520vLiveState -DeviceIp $Session.DeviceIp
    $restored=Restore-Ex520vExpansionSettings -LiveState $live -BackupPath $Session.BackupPath -SettingsPath $Session.SettingsPath -SettingsSha256 $Session.SettingsSha256
    $live=Get-Ex520vLiveState -DeviceIp $Session.DeviceIp
    Restart-Ex520vDevice $live
    $final=Wait-Ex520vExpandedStorage -DeviceIp $Session.DeviceIp -PreviousBootId $restored.PreviousBootId -ExpectedMiscRoSha256 $Session.MiscRoSha256 -ExpectedUbootSha256 $Session.UbootSha256
    $live=Get-Ex520vLiveState -DeviceIp $Session.DeviceIp
    $proof=Invoke-Ex520vSsh -Profile $live.Profile -DeviceIp $Session.DeviceIp -RemoteCommand 'cat /etc/ex520v-storage-proof'
    if($proof.Trim() -ne $restored.Proof){throw 'Genişletilmiş overlay kalıcılık işareti korunmadı.'}
    $Session.Status='complete'
    [IO.File]::WriteAllText((Join-Path (Get-Ex520vPaths).State 'storage-expansion.json'),($Session | ConvertTo-Json),$script:Utf8NoBom)
    Write-Ex520vOperationRecord -Action 'ExpansionVerified' -LiveState $live -Result 'settings-and-persistence-verified'
    return $final
}

function Start-Ex520vSshStorageExpansion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceIp, [string]$BackupPath, [Parameter(Mandatory = $true)][string]$EraseStockConfirmation)
    if($EraseStockConfirmation -cne 'STOK-SIL-407M'){throw 'STOK-SIL-407M onayı gerekli.'}
    $live=Get-Ex520vLiveState -DeviceIp $DeviceIp
    $report=Get-Ex520vStorageReport $live
    $plan=Get-Ex520vExpansionPlan $report
    $session=Get-Ex520vPendingStorageSession -DeviceIp $DeviceIp
    if($plan.AlreadyExpanded -and -not $session){return $report}
    if($session -and -not $BackupPath){$BackupPath=$session.BackupPath}
    if(-not $BackupPath){$BackupPath=Find-Ex520vExpansionBackup $live}
    if(-not $BackupPath){
        if(-not (Test-Ex520vOriginalStorageLayout $report)){throw 'Geçişin ilk açılışından önce alınan tam NAND yedeği bulunamadı; yedek dizinini belirtin.'}
        $BackupPath=Save-Ex520vRecoverySnapshot $live
    }
    $identity=Get-Ex520vLiveMiscRoIdentity $live
    if(-not (Test-Ex520vExpansionBackup -Path $BackupPath -Identity $identity)){throw 'Kurtarma yedeği cihazla eşleşmiyor veya eksik.'}
    if($session){
        $reference=Get-Ex520vExpansionReference
        if($session.MiscRoSha256 -ne $identity.Sha256 -or $session.SettingsSha256 -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $session.SettingsPath -Algorithm SHA256).Hash -ne $session.SettingsSha256 -or $session.UbootSha256 -notmatch '^[a-f0-9]{64}$' -or $session.FirmwareCommit -ne $reference.Commit -or $session.SysupgradeSha256 -ne $reference.SysupgradeSha256){throw 'Bekleyen geçiş kaydı canlı cihaz/ayar/firmware kayıtlarıyla eşleşmedi.'}
        if($plan.AlreadyExpanded){return (Complete-Ex520vStorageSession -Session $session)}
    }
    Write-Host ('Doğrulanmış kurtarma yedeği: ' + $BackupPath)
    if($plan.OverlayMissing){
        $repair=Repair-Ex520vPersistentOverlay -LiveState $live -Execute
        Write-Host $repair.Output
        Restart-Ex520vDevice $live
        $live=Wait-Ex520vDeviceState -DeviceIp $DeviceIp -ExpectedSystems @('Kalıcı OpenWrt')
        $proof=Invoke-Ex520vSsh -Profile $live.Profile -DeviceIp $DeviceIp -RemoteCommand 'cat /etc/ex520v-overlay-repair-proof'
        if($proof.Trim() -ne $repair.PreviousBootId){throw 'Onarımın kalıcılık işareti yeniden açılışta doğrulanmadı.'}
    }
    if(-not $session){
        $currentSettings=Save-Ex520vExpansionSettings $live
        $reference=Get-Ex520vExpansionReference
        $session=[pscustomobject]@{Status='pending';DeviceIp=$DeviceIp;BackupPath=$BackupPath;SettingsPath=$currentSettings.Path;SettingsSha256=$currentSettings.Sha256;MiscRoSha256=$identity.Sha256;UbootSha256=(Get-Ex520vLiveUbootSha256 $live);FirmwareCommit=$reference.Commit;SysupgradeSha256=$reference.SysupgradeSha256}
        [IO.File]::WriteAllText((Join-Path (Get-Ex520vPaths).State 'storage-expansion.json'),($session | ConvertTo-Json),$script:Utf8NoBom)
    }
    $firmware=Get-Ex520vExpansionFirmware
    for($stageIndex=0;$stageIndex -lt 2;$stageIndex++){
        $live=Get-Ex520vLiveState -DeviceIp $DeviceIp
        $report=Get-Ex520vStorageReport $live
        $plan=Get-Ex520vExpansionPlan $report
        if($plan.AlreadyExpanded){return (Complete-Ex520vStorageSession -Session $session)}
        Write-Host ('SSH genişletme aşaması: ' + $plan.Stage)
        $started=Install-Ex520vExpandedStorage -LiveState $live -SysupgradePath $firmware.SysupgradePath -BackupPath $BackupPath -Execute -EraseStockConfirmation $EraseStockConfirmation
        $expected=if($started.Stage -eq 'bootstrap'){'WidePending'}else{'Expanded'}
        $verified=Wait-Ex520vExpandedStorage -DeviceIp $DeviceIp -PreviousBootId $started.PreviousBootId -Expected $expected -ExpectedMiscRoSha256 $started.ExpectedMiscRoSha256 -ExpectedUbootSha256 $started.ExpectedUbootSha256
        if((Get-Ex520vExpansionPlan $verified).AlreadyExpanded){
            return (Complete-Ex520vStorageSession -Session $session)
        }
        Write-Host 'Geniş bölüm haritası açıldı; ayarlar küçük kalıcı overlay üzerinde korundu. Büyük overlay aşamasına geçiliyor.'
    }
    throw 'İki aşamalı genişletmenin son durumu doğrulanamadı.'
}

function Find-Ex520vStockRestoreBackup {
    param([Parameter(Mandatory=$true)]$LiveState)
    $identity=Get-Ex520vLiveMiscRoIdentity $LiveState
    foreach($dir in @(Get-ChildItem -LiteralPath (Get-Ex520vPaths).Backups -Directory | Sort-Object Name -Descending)){
        $metadataPath=Join-Path $dir.FullName 'backup.json'
        if(-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)){continue}
        try{$metadata=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json}catch{continue}
        if($metadata.system -ne 'Stok'){continue}
        if(Test-Ex520vExpansionBackup -Path $dir.FullName -Identity $identity){return $dir.FullName}
    }
    return $null
}

function New-Ex520vStockRestoreBundle {
    param([Parameter(Mandatory=$true)][string]$BackupPath)
    $directory=Join-Path (Get-Ex520vPaths).State ('stock-restore-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $bundle=Join-Path $directory 'stock-restore.tar.gz'
    $members=@('SHA256SUMS','mtd5-ubi0.bin','mtd6-ubi1.bin','mtd7-bflag.bin','mtd8-misc_rw_bak.bin','mtd9-misc_isp.bin','mtd10-runtime_data.bin','mtd11-container.bin')
    $tar=Get-Ex520vCommand 'tar.exe'
    $result=Invoke-Ex520vNativeText -FilePath $tar -Arguments (@('-czf',$bundle,'-C',$BackupPath) + $members) -TimeoutSeconds 600
    if($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $bundle -PathType Leaf)){throw ('Stok geri yükleme paketi oluşturulamadı. ' + $result.StdErr)}
    $listing=Invoke-Ex520vNativeText -FilePath $tar -Arguments @('-tzf',$bundle) -TimeoutSeconds 120
    $found=@($listing.StdOut -split '\r?\n' | Where-Object {$_})
    if($listing.ExitCode -ne 0 -or (Compare-Object ($members | Sort-Object) ($found | Sort-Object))){throw 'Stok geri yükleme paketinin içeriği doğrulanamadı.'}
    [pscustomobject]@{Path=$bundle;Sha256=(Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant();Members=$members}
}

function Test-Ex520vStockRestoreHandoff {
    param([int]$ExitCode,[string]$StdOut,[string]$StdErr)
    $text=$StdOut+$StdErr
    $disconnect=$ExitCode -ne 0 -and $text -match 'ubus call system sysupgrade' -and $text -match 'Connection failed'
    return ($text -like '*STARTING: stock restore RAM pivot*' -and ($ExitCode -in @(0,255) -or $disconnect) -and $text -notmatch '(?i)(\[ex520v\] ERROR:|permission denied|invalid argument)')
}

function Complete-Ex520vStockRestoreVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$StockState,
        [Parameter(Mandatory=$true)][string]$BackupPath,
        [Parameter(Mandatory=$true)][string]$ExpectedMiscRoSha256,
        [Parameter(Mandatory=$true)]$Record
    )
    if($StockState.System -ne 'Stok' -or -not $StockState.RootSsh -or $StockState.Transport -ne 'Stock'){throw 'Stok açılışı root SSH üzerinden doğrulanamadı.'}
    if(-not (Test-Ex520vFlashLayout $StockState.MtdNames)){throw 'Stok sistem açıldı ancak 11 bölümlü MTD düzeni doğrulanmadı.'}
    if((Get-Ex520vLiveMiscRoSha256 $StockState) -ne $ExpectedMiscRoSha256){throw 'Stok açılışında cihaz kalibrasyon kimliği değişti.'}
    # The two boot slots and bflag must remain byte-identical after boot. The
    # stock firmware legitimately updates its writable backup/runtime/container
    # regions during first boot; those were already hashed immediately after
    # each RAM-stage write, so post-boot we verify their exact map and that the
    # complete character devices remain readable instead of requiring stale
    # pre-boot content.
    foreach($entry in @(@('mtd5','mtd5-ubi0.bin'),@('mtd6','mtd6-ubi1.bin'),@('mtd7','mtd7-bflag.bin'))){
        $source=Join-Path $BackupPath $entry[1]
        $temp=[IO.Path]::GetTempFileName()
        try{
            Invoke-Ex520vSshToFile -Profile $StockState.Profile -DeviceIp $StockState.DeviceIp -RemoteCommand ('cat /dev/' + $entry[0]) -OutputPath $temp -TimeoutSeconds 1200
            if((Get-Item -LiteralPath $temp).Length -ne (Get-Item -LiteralPath $source).Length){throw ('Stok açılışı sonrası bölüm boyutu eşleşmedi: ' + $entry[1])}
            $expected=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            $actual=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
            if($actual -ne $expected){throw ('Stok açılışı sonrası bölüm özeti eşleşmedi: ' + $entry[1])}
        }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
    }
    $mtdText=Invoke-Ex520vSsh -Profile $StockState.Profile -DeviceIp $StockState.DeviceIp -RemoteCommand 'cat /proc/mtd'
    foreach($entry in @(@('mtd8','misc_rw_bak','mtd8-misc_rw_bak.bin'),@('mtd9','misc_isp','mtd9-misc_isp.bin'),@('mtd10','runtime_data','mtd10-runtime_data.bin'),@('mtd11','container','mtd11-container.bin'))){
        $match=[regex]::Match($mtdText,('(?m)^'+[regex]::Escape($entry[0])+':\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+"'+[regex]::Escape($entry[1])+'"\s*$'))
        if(-not $match.Success){throw ('Stok açılışı sonrası yazılabilir bölüm haritası eşleşmedi: ' + $entry[1])}
        $expectedSize=(Get-Item -LiteralPath (Join-Path $BackupPath $entry[2])).Length
        if([Convert]::ToInt64($match.Groups[1].Value,16) -ne $expectedSize){throw ('Stok açılışı sonrası yazılabilir bölüm boyutu eşleşmedi: ' + $entry[1])}
    }
    $readable=Invoke-Ex520vSsh -Profile $StockState.Profile -DeviceIp $StockState.DeviceIp -RemoteCommand '/bin/busybox cat /dev/mtd8 /dev/mtd9 /dev/mtd10 /dev/mtd11 >/dev/null && /bin/busybox echo READABLE' -TimeoutSeconds 600
    if($readable.Trim() -ne 'READABLE'){throw 'Stok açılışı sonrası yazılabilir veri bölümleri bütünüyle okunamadı.'}
    $Record.Status='complete'
    $Record | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date).ToString('o') -Force
    [IO.File]::WriteAllText((Join-Path (Get-Ex520vPaths).State 'stock-restore.json'),(($Record|ConvertTo-Json)+"`n"),$script:Utf8NoBom)
    Write-Ex520vOperationRecord -Action 'StockBackupRestored' -LiveState $StockState -Result 'boot-slots-hashed-and-mutable-regions-readable'
    return $StockState
}

function Start-Ex520vStockRestoreFromBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$DeviceIp,
        [string]$BackupPath,
        [Parameter(Mandatory=$true)][string]$Confirmation
    )
    if($Confirmation -cne 'STOK-YEDEK-GERI-YUKLE'){throw 'STOK-YEDEK-GERI-YUKLE onayı gerekli.'}
    $live=Get-Ex520vLiveState -DeviceIp $DeviceIp
    if($live.System -eq 'Stok'){
        $recordPath=Join-Path (Get-Ex520vPaths).State 'stock-restore.json'
        if(-not (Test-Path -LiteralPath $recordPath -PathType Leaf)){return $live}
        $pending=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if($pending.Status -ne 'pending'){return $live}
        $pendingBackup=[string]$pending.BackupPath
        if(-not (Test-Path -LiteralPath $pendingBackup -PathType Container)){throw 'Bekleyen stok geri yüklemesinin yedek klasörü bulunamadı.'}
        $resumeIdentity=Get-Ex520vLiveMiscRoIdentity $live
        if($resumeIdentity.Sha256 -ne [string]$pending.MiscRoSha256 -or -not (Test-Ex520vExpansionBackup -Path $pendingBackup -Identity $resumeIdentity)){throw 'Bekleyen stok geri yüklemesinin cihaz kimliği veya tam yedeği yeniden doğrulanamadı.'}
        return Complete-Ex520vStockRestoreVerification -StockState $live -BackupPath $pendingBackup -ExpectedMiscRoSha256 ([string]$pending.MiscRoSha256) -Record $pending
    }
    $report=Get-Ex520vStorageReport $live
    $plan=Get-Ex520vExpansionPlan $report
    if(-not $plan.AlreadyExpanded){throw 'Tam stok yedeği geri yükleme yalnız doğrulanmış genişletilmiş düzende çalışır.'}
    $identity=Get-Ex520vLiveMiscRoIdentity $live
    if(-not $BackupPath){$BackupPath=Find-Ex520vStockRestoreBackup $live}
    if(-not $BackupPath -or -not (Test-Ex520vExpansionBackup -Path $BackupPath -Identity $identity)){throw 'Bu cihaza ait doğrulanmış 11 bölümlü stok yedeği bulunamadı.'}
    $metadata=Get-Content -LiteralPath (Join-Path $BackupPath 'backup.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($metadata.system -ne 'Stok'){throw 'Seçilen yedek stok sistemden alınmamış.'}
    $firmware=Get-Ex520vExpansionFirmware
    $bundle=New-Ex520vStockRestoreBundle -BackupPath $BackupPath
    $scriptPath=Join-Path (Get-Ex520vPaths).Install 'openwrt-restore-stock-expanded.sh'
    Send-Ex520vFile -Profile $live.Profile -DeviceIp $DeviceIp -LocalPath $bundle.Path -RemotePath '/tmp/ex520v-stock-restore.tar.gz' -TimeoutSeconds 1200
    Send-Ex520vFile -Profile $live.Profile -DeviceIp $DeviceIp -LocalPath $firmware.SysupgradePath -RemotePath '/tmp/ex520v-stock-validator.bin' -TimeoutSeconds 600
    Send-Ex520vFile -Profile $live.Profile -DeviceIp $DeviceIp -LocalPath $scriptPath -RemotePath '/tmp/ex520v-stock-restore.sh'
    $command='sh /tmp/ex520v-stock-restore.sh /tmp/ex520v-stock-restore.tar.gz ' + $bundle.Sha256
    $check=Invoke-Ex520vSsh -Profile $live.Profile -DeviceIp $DeviceIp -RemoteCommand ($command + ' --check') -TimeoutSeconds 600
    if($check -notlike '*CHECK OK:*'){throw 'Stok geri yükleme yazmasız ön kontrolü başarısız.'}
    $record=[ordered]@{Status='pending';DeviceIp=$DeviceIp;BackupPath=$BackupPath;BundleSha256=$bundle.Sha256;MiscRoSha256=$identity.Sha256;PreviousBootId=$report.BootId;StartedAt=(Get-Date).ToString('o')}
    [IO.File]::WriteAllText((Join-Path (Get-Ex520vPaths).State 'stock-restore.json'),(($record|ConvertTo-Json)+"`n"),$script:Utf8NoBom)
    Write-Ex520vLog -Level WARN -Message ('Genişletilmiş alan, doğrulanmış stok yedeğinden geri yükleniyor: ' + $BackupPath)
    $result=Invoke-Ex520vNativeText -FilePath (Get-Ex520vCommand 'ssh.exe') -Arguments (Get-SshArguments $live.Profile $DeviceIp ($command + ' --execute /tmp/ex520v-stock-validator.bin')) -TimeoutSeconds 600
    if(-not (Test-Ex520vStockRestoreHandoff -ExitCode $result.ExitCode -StdOut $result.StdOut -StdErr $result.StdErr)){throw ('Stok geri yükleme RAM aşaması başlatılamadı. ' + $result.StdOut + $result.StdErr)}
    $stock=Wait-Ex520vDeviceState -DeviceIp $DeviceIp -ExpectedSystems @('Stok') -TimeoutSeconds 420
    return Complete-Ex520vStockRestoreVerification -StockState $stock -BackupPath $BackupPath -ExpectedMiscRoSha256 $identity.Sha256 -Record $record
}
