# Copyright (C) 2026 TP-Link EX520v OpenWrt Tool contributors
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$DeviceIp = '192.168.1.1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch {}
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$applicationRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($applicationRoot)) {
    $applicationRoot = [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}
$modulePath = Join-Path $applicationRoot 'modules\Ex520v.Core.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host 'HATA: Uygulama çekirdek modülü bulunamadı.' -ForegroundColor Red
    exit 2
}
Import-Module $modulePath -Force -DisableNameChecking
$paths = Initialize-Ex520vTool

if (-not (Test-Ex520vIPv4 $DeviceIp)) {
    Write-Host 'HATA: Geçersiz cihaz IPv4 adresi.' -ForegroundColor Red
    exit 2
}

$script:DeviceIp = $DeviceIp
$script:LiveState = $null

function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host $Text -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host $Text -ForegroundColor Cyan }

function Read-YesNoConfirmation {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Warn $Message
    while ($true) {
        $answer = (Read-Host 'Devam etmek istiyor musunuz? (e/H)').Trim()
        if ($answer -match '^[eE]$') { return $true }
        if ($answer -match '^[hH]$') { return $false }
        Write-Warn 'Geçersiz seçim. Yalnızca e veya h yazın; boş bırakılamaz.'
    }
}

function Update-LiveState {
    Write-Host 'Cihaz durumu denetleniyor...' -ForegroundColor DarkGray
    try {
        $script:LiveState = Get-Ex520vLiveState -DeviceIp $script:DeviceIp
    }
    catch {
        Write-Ex520vLog -Level ERROR -Message $_.Exception.Message
        $script:LiveState = [pscustomobject]@{
            DeviceIp = $script:DeviceIp; WebReachable = $false; RootSsh = $false; Transport = 'None'
            System = 'Bilinmiyor'; Model = ''; Firmware = ''; BootIndex = ''; Trial = ''; TrialMarker = ''
            CommandLine = ''; MtdNames = @(); Profile = $null; Error = $_.Exception.Message
        }
    }
    return $script:LiveState
}

function Write-ColoredValue {
    param([string]$Label, [string]$Value, [ValidateSet('Good', 'Warn', 'Bad', 'Neutral')][string]$Kind = 'Neutral')
    $color = switch ($Kind) { 'Good' { 'Green' } 'Warn' { 'Yellow' } 'Bad' { 'Red' } default { 'Gray' } }
    Write-Host ('{0,-13}: ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $color
}

function Show-MainMenu {
    Clear-Host
    [void](Update-LiveState)
    $backupText = 'Doğrulanamadı'
    if ($script:LiveState.RootSsh) {
        try {
            $backup = Find-Ex520vBackupForLiveState -LiveState $script:LiveState
            $backupText = if ($backup) { 'Var' } else { 'Yok' }
        }
        catch {
            Write-Ex520vLog -Level WARN -Message ('Yedek kimliği okunamadı: ' + $_.Exception.Message)
            $backupText = 'Doğrulanamadı'
        }
    }
    $firmware = Get-Ex520vLocalFirmware

    Write-Host '========================================================' -ForegroundColor DarkCyan
    Write-Host '  TP-LINK EX520v OPENWRT TOOL' -ForegroundColor Cyan
    Write-Host '========================================================' -ForegroundColor DarkCyan
    Write-ColoredValue 'Cihaz' $(if ($script:LiveState.Model) { $script:LiveState.Model } else { 'EX520v (doğrulanmadı)' }) $(if ($script:LiveState.Model -eq 'EX520v') { 'Good' } else { 'Warn' })
    Write-ColoredValue 'Bağlantı' $(if ($script:LiveState.WebReachable -or $script:LiveState.RootSsh) { 'Başarılı' } else { 'Başarısız' }) $(if ($script:LiveState.WebReachable -or $script:LiveState.RootSsh) { 'Good' } else { 'Bad' })
    Write-ColoredValue 'Root SSH' $(if ($script:LiveState.RootSsh) { "Aktif ($($script:LiveState.Profile.Port)/TCP)" } else { 'Pasif / doğrulanamadı' }) $(if ($script:LiveState.RootSsh) { 'Good' } else { 'Warn' })
    Write-ColoredValue 'Sistem' $script:LiveState.System $(if ($script:LiveState.System -eq 'Bilinmiyor') { 'Warn' } else { 'Good' })
    Write-ColoredValue 'Firmware' $(if ($script:LiveState.Firmware) { $script:LiveState.Firmware } else { 'Bilinmiyor' }) 'Neutral'
    Write-ColoredValue 'Yedek' $backupText $(if ($backupText -eq 'Var') { 'Good' } elseif ($backupText -eq 'Yok') { 'Bad' } else { 'Warn' })
    Write-ColoredValue 'İmajlar' $(if ($firmware) { 'Doğrulandı' } else { 'Hazır değil' }) $(if ($firmware) { 'Good' } else { 'Warn' })
    Write-Host ''
    Write-Host '--------------------------------------------------------'
    Write-Host '1. Cihaz bağlantısını kontrol et'
    Write-Host '2. Root SSH erişimi aç / kontrol et'
    Write-Host '3. Stok firmware yedeği al'
    Write-Host '4. OpenWrt RAM deneme kurulumu'
    Write-Host '5. OpenWrt flash kurulumu'
    Write-Host '6. OpenWrt kurulumunu kalıcı yap'
    Write-Host "7. Stok firmware'e geri dön"
    Write-Host '8. Dosyaları ve gereksinimleri kontrol et'
    Write-Host '9. İşlem kayıtları ve cihaz bilgileri'
    Write-Host 'G. OpenWrt depolama alanını genişlet'
    Write-Host 'A. Cihaz IP adresini değiştir'
    Write-Host '0. Çıkış'
    Write-Host '--------------------------------------------------------'
}

function Get-ReadyFirmware {
    $firmware = Get-Ex520vLocalFirmware
    if ($firmware) { return $firmware }
    Write-Info 'EX520v firmware ZIP paketi indiriliyor, açılıyor ve SHA256 ile doğrulanıyor...'
    return Get-Ex520vReleaseFirmware
}

function Invoke-ConnectionCheck {
    $state = Update-LiveState
    if ($state.WebReachable) { Write-Ok "Web paneli erişilebilir: http://$($state.DeviceIp)/" } else { Write-Fail 'Web paneline ulaşılamadı.' }
    if ($state.RootSsh) {
        Write-Ok "UID 0 SSH bağlantısı doğrulandı: $($state.Profile.Port)/TCP"
        Write-Host "Algılanan sistem: $($state.System)"
    }
    else {
        Write-Warn 'UID 0 SSH bağlantısı doğrulanamadı.'
        if ($state.Error) { Write-Host $state.Error -ForegroundColor DarkGray }
    }
}

function Invoke-RootAccess {
    $state = Update-LiveState
    if ($state.Transport -eq 'Stock' -and $state.RootSsh) { Write-Ok 'Stok sistemde UID 0 SSH zaten aktif; yeniden root işlemi yapılmadı.'; return }
    if (-not $state.WebReachable) { throw 'Stok web paneline ulaşılamıyor. Ethernet bağlantısını ve IP adresini kontrol edin.' }
    Write-Warn 'Root aracı EX520v_260514 (tam), EX520v-v1.0_250522 ve EX520v-v1.0_250120 (çekirdek root) profillerini destekler.'
    Write-Warn 'Windows root motoru eski firmware cihazda doğrulandı; temiz sistem bağımlılık kurulumu ayrıca test edilmelidir.'
    Write-Host 'Gerekirse Chrome açılır; stok web panelinde kendi bilgilerinizle giriş yapmanız istenir.'
    if (-not (Read-YesNoConfirmation -Message 'Root aracı kendi uyumluluk ve imza kontrollerini çalıştıracaktır.')) { Write-Warn 'İşlem iptal edildi.'; return }
    Start-Ex520vRootTool -DeviceIp $script:DeviceIp
    $after = Update-LiveState
    if ($after.Transport -eq 'Stock' -and $after.RootSsh) { Write-Ok 'Root SSH port 2222 üzerinde anahtar tabanlı UID 0 olarak doğrulandı.' }
    else { throw 'Root aracı tamamlandı ancak UID 0 SSH doğrulanamadı; sonraki aşamalar açılmadı.' }
}

function Invoke-BackupAction {
    $state = Update-LiveState
    Write-Host 'Tüm MTD bölümleri salt okunur biçimde bilgisayara aktarılır ve SHA256 ile doğrulanır.'
    $path = Save-Ex520vStockBackup -LiveState $state
    Write-Ok "Doğrulanmış stok yedeği hazır: $path"
}

function Invoke-RamTrialAction {
    $state = Update-LiveState
    $firmware = Get-ReadyFirmware
    if (-not $firmware) { Write-Warn 'İşlem iptal edildi.'; return }
    $backup = Find-Ex520vBackupForLiveState -LiveState $state
    if (-not $backup) { throw 'Bu cihaza ait doğrulanmış tam stok yedeği bulunamadı. Önce menü 3 ile yedek alın.' }
    if ($state.System -eq 'Stok' -and $state.CommandLine -match '(^|\s)ubi\.mtd=ubi0(\s|$)') {
        Write-Warn 'Stok sistem birincil ubi0 slotundan çalışıyor. ubi0 aktifken OpenWrt bu slota güvenle yazılamaz.'
        Write-Info 'Pasif ubi1 slotunun 40 MiB içeriği aynı cihaza ait doğrulanmış yedekle SHA256 üzerinden karşılaştırılıyor...'
        $slot = Test-Ex520vSecondaryStockSlot -LiveState $state -BackupPath $backup
        if (-not (Read-YesNoConfirmation -Message 'Araç yalnız boot seçimini doğrulanmış stok ubi1 slotuna alıp cihazı yeniden başlatacaktır. Bu aşamada hiçbir MTD bölümü yazılmaz.')) { Write-Warn 'İşlem iptal edildi.'; return }
        $fresh = Update-LiveState
        [void](Select-Ex520vSecondaryStockSlot -LiveState $fresh -Verification $slot)
        Restart-Ex520vDevice -LiveState $fresh
        Write-Info 'Cihazın doğrulanmış stok ubi1 slotuyla açılması bekleniyor...'
        $state = Wait-Ex520vDeviceState -DeviceIp $script:DeviceIp -ExpectedSystems @('Stok') -CommandLinePattern '(^|\s)ubi\.mtd=ubi1(\s|$)'
        if ($state.BootIndex -ne '1') { throw 'Stok ubi1 ile açıldı ancak tp_boot_idx=1 doğrulanamadı.' }
        $backup = Find-Ex520vBackupForLiveState -LiveState $state
        if (-not $backup) { throw 'Slot geçişinden sonra aynı cihaza ait doğrulanmış stok yedeği bulunamadı.' }
        Write-Ok 'Stok sistem doğrulanmış ubi1 slotundan açıldı; ubi0 artık pasif ve OpenWrt denemesi için güvenli.'
    }
    Write-Info 'İmajlar hazırlanıyor, cihaza aktarılıyor ve yazmasız referans kontrolü çalıştırılıyor...'
    [void](Install-Ex520vRamTrial -LiveState $state -Firmware $firmware -BackupPath $backup)
    if (-not (Read-YesNoConfirmation -Message 'Bu işlem pasif ubi0 slotunu biçimlendirip OpenWrt deneme imajını yazacaktır. Çalışan ubi1 stok slotuna dokunulmaz.')) { Write-Warn 'Yazma işlemi iptal edildi.'; return }
    $fresh = Update-LiveState
    $gate = Test-Ex520vOperationAllowed -Action RamTrial -LiveState $fresh -BackupComplete $true -FirmwareValid $true
    if (-not $gate.Allowed) { throw ('Cihaz durumu değişti: ' + ($gate.Reasons -join ' ')) }
    [void](Start-Ex520vRamTrialWrite -LiveState $fresh -BackupPath $backup)
    Write-Ok 'ubi0 yazıldı ve geri okuma doğrulandı. Deneme boot ayarları etkin.'
    if (Read-YesNoConfirmation -Message 'Cihaz şimdi yeniden başlatılabilir. Bağlantı kesilmesi tek başına başarı sayılmayacaktır.') {
        Restart-Ex520vDevice -LiveState $fresh
        Write-Info 'Cihazın RAM deneme ortamıyla açılması bekleniyor...'
        $verified = Wait-Ex520vDeviceState -DeviceIp $script:DeviceIp -ExpectedSystems @('RAM deneme', 'OpenWrt RAM')
        if ($verified.System -eq 'OpenWrt RAM') {
            Write-Info 'Initramfs açılışı doğrulandı; stok geri dönüş boot ayarları etkinleştiriliyor...'
            $verified = Arm-Ex520vRamTrialFallback -LiveState $verified
        }
        Write-Ok "RAM deneme ortamı canlı cihazdan doğrulandı: $($verified.Firmware)"
    }
}

function Invoke-FlashAction {
    $state = Update-LiveState
    $firmware = Get-ReadyFirmware
    if (-not $firmware) { Write-Warn 'İşlem iptal edildi.'; return }
    $backup = Find-Ex520vBackupForLiveState -LiveState $state
    if (-not $backup) { throw 'Doğrulanmış stok yedeği bulunamadı.' }
    Write-Info 'Sysupgrade aktarılıyor ve sysupgrade -T kontrolü çalıştırılıyor...'
    [void](Install-Ex520vFlashTrial -LiveState $state -Firmware $firmware -BackupPath $backup)
    if (-not (Read-YesNoConfirmation -Message 'Bu işlem yalnız doğrulanmış RAM deneme ortamındaki ubi0 volume düzenini flash OpenWrt için yeniden yazacaktır.')) { Write-Warn 'Yazma işlemi iptal edildi.'; return }
    $fresh = Update-LiveState
    $gate = Test-Ex520vOperationAllowed -Action Flash -LiveState $fresh -BackupComplete $true -FirmwareValid $true
    if (-not $gate.Allowed) { throw ('Cihaz durumu değişti: ' + ($gate.Reasons -join ' ')) }
    [void](Install-Ex520vFlashTrial -LiveState $fresh -Firmware $firmware -BackupPath $backup -Execute)
    Write-Ok 'OpenWrt flash volume yazmaları ve geri okuma doğrulaması tamamlandı.'
    if (Read-YesNoConfirmation -Message 'Cihaz flash deneme sistemiyle açılmak üzere yeniden başlatılabilir.') {
        Restart-Ex520vDevice -LiveState $fresh
        Write-Info 'Flash deneme ortamı bekleniyor...'
        $verified = Wait-Ex520vDeviceState -DeviceIp $script:DeviceIp -ExpectedSystems @('Flash deneme')
        Write-Info 'Flash deneme açılışı doğrulandı; stok geri dönüş boot ayarı yeniden etkinleştiriliyor...'
        [void](Arm-Ex520vFlashTrialFallback -LiveState $verified -BackupPath $backup)
        Write-Ok 'OpenWrt flash üzerinden, stok geri dönüşü etkin durumda doğrulandı.'
    }
}

function Invoke-ConfirmAction {
    $state = Update-LiveState
    if ($state.System -eq 'Flash deneme' -and $state.Trial -eq '1' -and -not $state.BootIndex) {
        Write-Warn 'Flash deneme açılışının son fallback adımı yarım kalmış; doğrulanmış stok alanı denetlenip boot ayarı tamamlanıyor...'
        $backup = Find-Ex520vBackupForLiveState -LiveState $state
        if (-not $backup) { throw 'Fallback onarımı için bu cihaza ait doğrulanmış tam stok yedeği bulunamadı.' }
        $state = Arm-Ex520vFlashTrialFallback -LiveState $state -BackupPath $backup
        Write-Ok 'Stok geri dönüş boot ayarı yeniden etkinleştirildi.'
    }
    $gate = Test-Ex520vOperationAllowed -Action Confirm -LiveState $state
    if (-not $gate.Allowed) { throw ($gate.Reasons -join ' ') }
    Write-Warn 'Kalıcılaştırma, her açılışta stoka dönüşü sağlayan deneme bayrağını kaldırır. Stok firmware ubi1 slotunda korunur.'
    if (-not (Read-YesNoConfirmation -Message 'OpenWrt işlevlerini test ettiyseniz devam edin.')) { Write-Warn 'İşlem iptal edildi.'; return }
    $fresh = Update-LiveState
    [void](Confirm-Ex520vOpenWrt -LiveState $fresh)
    $verified = Update-LiveState
    if ($verified.System -ne 'Kalıcı OpenWrt') { throw 'Boot environment değişti ancak kalıcı durum canlı cihazdan doğrulanamadı.' }
    Write-Ok 'OpenWrt kalıcı olarak seçildi; stok firmware ubi1 slotunda korundu.'
}

function Invoke-ReturnStockAction {
    $state = Update-LiveState
    if($state.System -eq 'Stok'){
        $restoreRecordPath=Join-Path $paths.State 'stock-restore.json'
        $restorePending=$false
        if(Test-Path -LiteralPath $restoreRecordPath -PathType Leaf){
            try{$restorePending=((Get-Content -LiteralPath $restoreRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json).Status -eq 'pending')}catch{}
        }
        if($restorePending){
            Write-Warn 'Stok sistem açılmış; bekleyen geri yükleme yalnız açılış sonrası doğrulama aşamasından sürdürülecek.'
            $restored=Start-Ex520vStockRestoreFromBackup -DeviceIp $script:DeviceIp -Confirmation 'STOK-YEDEK-GERI-YUKLE'
            Write-Ok ('Stok sistem ve bölüm doğrulamaları tamamlandı: ' + $restored.CommandLine)
        }else{Write-Ok 'Cihaz zaten stok firmware ile çalışıyor.'}
        return
    }
    if($state.System -eq 'Genişletilmiş OpenWrt'){
        $backup=Find-Ex520vStockRestoreBackup -LiveState $state
        if(-not $backup){throw 'Bu cihaza ait doğrulanmış tam stok yedeği bulunamadı.'}
        Write-Warn 'Genişletilmiş NAND düzeninde korunmuş stok slotu yoktur. Doğrulanmış tam yedekteki stok alanı RAM-pivot ile geri yazılacaktır.'
        Write-Host ('Kullanılacak yedek: ' + $backup)
        if(-not (Read-YesNoConfirmation -Message 'Bu işlem 407 MiB overlay ve içindeki tüm OpenWrt ayar/paketlerini siler; iki stok slotunu geri yükleyip cihazı stok ubi0 ile yeniden başlatır.')){Write-Warn 'Geri yükleme iptal edildi.';return}
        Write-Warn 'Stok geri yükleme 10 dakikadan uzun sürebilir. Yazma, geri okuma ve açılış sonrası SHA256 kontrolleri tamamlanana kadar pencereyi kapatmayın ve cihazın gücünü kesmeyin.'
        $restored=Start-Ex520vStockRestoreFromBackup -DeviceIp $script:DeviceIp -BackupPath $backup -Confirmation 'STOK-YEDEK-GERI-YUKLE'
        Write-Ok ('Stok sistem ve 11 bölümlü NAND düzeni doğrulandı: ' + $restored.CommandLine)
        return
    }
    $backup=$null
    if($state.MtdNames -contains 'ubi' -and $state.MtdNames -notcontains 'ubi1'){
        $backup=Find-Ex520vBackupForLiveState -LiveState $state
        if(-not $backup){throw 'Birleşik NAND haritasında stok dönüşünü doğrulamak için bu cihaza ait tam stok yedeği bulunamadı.'}
    }
    Write-Host 'Bu işlem yedek dosyalarını flasha geri yüklemez; korunmuş ubi1 stok slotunu seçer.'
    [void](Return-Ex520vToStock -LiveState $state -BackupPath $backup)
    if (-not (Read-YesNoConfirmation -Message 'Stok slotu doğrulandı. Sonraki açılış için ubi1 seçilecektir.')) { Write-Warn 'İşlem iptal edildi.'; return }
    $fresh = Update-LiveState
    [void](Return-Ex520vToStock -LiveState $fresh -BackupPath $backup -Execute)
    Write-Ok 'Stok slotu bir sonraki açılış için seçildi.'
    if (Read-YesNoConfirmation -Message 'Cihaz şimdi yeniden başlatılabilir.') {
        Restart-Ex520vDevice -LiveState $fresh
        Write-Info 'Stok sistemin açılması bekleniyor...'
        [void](Wait-Ex520vDeviceState -DeviceIp $script:DeviceIp -ExpectedSystems @('Stok'))
        Write-Ok 'Stok sistem canlı cihazdan doğrulandı.'
    }
}

function Invoke-RequirementsAction {
    Write-Host 'Yerel gereksinimler:' -ForegroundColor Cyan
    foreach ($item in @(Test-Ex520vLocalRequirements)) {
        if ($item.Ok) { Write-Ok ('  [OK] {0}: {1}' -f $item.Name, $item.Detail) }
        else { Write-Fail ('  [EKSİK] {0}: {1}' -f $item.Name, $item.Detail) }
    }
    $firmware = Get-Ex520vLocalFirmware
    if ($firmware) {
        Write-Ok 'Firmware çifti SHA256, FIT, sysupgrade tar ve cihaz metadata kontrollerinden geçti.'
        Write-Host "  Initramfs: $($firmware.InitramfsPath)"
        Write-Host "  Sysupgrade: $($firmware.SysupgradePath)"
    }
    else { Write-Warn 'Doğrulanmış yerel firmware çifti yok.' }
    Write-Host ''
    if ((Read-Host 'EX520v firmware ZIP paketini indirip doğrulamak ister misiniz? (e/H)') -match '^[eEyY]') {
        $downloaded = Get-Ex520vReleaseFirmware
        Write-Ok "Firmware indirildi ve doğrulandı: $($downloaded.SysupgradePath)"
    }
}

function Show-LogsAndInfo {
    $state = Update-LiveState
    Write-Host 'Canlı cihaz bilgileri' -ForegroundColor Cyan
    $state | Select-Object DeviceIp, WebReachable, RootSsh, Transport, System, Model, Firmware, BootIndex, Trial, TrialMarker, MtdNames | Format-List
    Write-Host "Günlük: $($paths.CurrentLog)"
    $last = Join-Path $paths.State 'last-operation.json'
    if (Test-Path -LiteralPath $last) {
        Write-Host 'Son yerel işlem kaydı (güvenlik önkoşulu olarak kullanılmaz):'
        Get-Content -LiteralPath $last -Encoding UTF8 | Write-Host
    }
}

function Invoke-StorageExpansionAction {
    $state=Update-LiveState
    $report=$null
    try { $report=Get-Ex520vStorageReport -LiveState $state }
    catch { Write-Warn ('Envanter şu anda okunamadı: ' + $_.Exception.Message) }
    # Analysis remains available before the operator starts a write operation.
    if ($report) {
        $plan=Get-Ex520vExpansionPlan -Report $report
        Write-Host 'NAND bölümleri:' -ForegroundColor Cyan
        $report.Partitions | Sort-Object OffsetBytes | Select-Object Name,@{n='Başlangıç';e={'0x{0:x8}' -f $_.OffsetBytes}},@{n='MiB';e={$_.SizeBytes / 1MB}} | Format-Table -AutoSize
        Write-Host ('Çalışan kök: {0}; /rom: {1}; /overlay: {2} {3} (MTD: {4})' -f $report.RootFs,$report.RomFs,$report.OverlaySource,$report.OverlayFs,$report.OverlayMtdName)
        Write-Host ('Kök toplam/boş: {0:N1}/{1:N1} MiB' -f ($report.RootTotalBytes / 1MB),($report.RootAvailableBytes / 1MB))
        if ($plan.OverlayMissing) { Write-Warn 'Kalıcı overlay bağlı değil. Gösterilen boş alan RAM; ayarlar ve paketler yeniden başlatmada kaybolabilir.' }
        if ($plan.AlreadyExpanded) {
            Write-Ok '407 MiB NAND düzeni ve ayrı UBI üzerindeki kalıcı overlay zaten aktif.'
            if(-not (Get-Ex520vPendingStorageSession -DeviceIp $script:DeviceIp)){return}
            Write-Warn 'Bekleyen geçiş kaydı var; G ayar geri yükleme ve kalıcılık doğrulamasını tamamlar.'
        }
    }
    Write-Warn 'Bu seçenek stok ubi1, bflag, misc_rw_bak, misc_isp, runtime_data ve container alanlarını büyük OpenWrt overlay için kullanır.'
    Write-Host 'Doğrulanmış tam stok yedeği korunursa Menü 7 bu alanları ve iki stok slotunu geri yükleyerek stoka dönebilir.'
    Write-Host 'Hedef: 0x04900000–0x1e000000, 407 MiB ham UBI. Paketler için net boş alan imaj boyutu ve NAND rezervlerine bağlıdır; 356 MB garantisi verilmez.'
    Write-Host 'Bootloader ve kalibrasyon korunur. wmemcmp/ex520v imajı indirilir/doğrulanır; yedek, iki sysupgrade aşaması, ayar geri yükleme ve yeniden açılış kontrolleri otomatik yürütülür.'
    if(-not (Read-YesNoConfirmation -Message 'Tam NAND yedeği alınır; eksik overlay onarılır; iki SSH/sysupgrade aşaması çalışır. İkinci aşama stok firmware/veri alanlarını siler. Stoka dönüş yalnız bu doğrulanmış tam yedekle Menü 7 üzerinden yapılabilir. Ağ ayarları ve SSH anahtarları korunur.')){return}
    $verified=Start-Ex520vSshStorageExpansion -DeviceIp $script:DeviceIp -EraseStockConfirmation 'STOK-SIL-407M'
    Write-Ok ('Genişletilmiş NAND overlay doğrulandı. Toplam {0:N1} MiB, boş {1:N1} MiB.' -f ($verified.RootTotalBytes / 1MB),($verified.RootAvailableBytes / 1MB))
}

while ($true) {
    Show-MainMenu
    $choice = (Read-Host 'Seçim').Trim().ToUpperInvariant()
    if ($choice -eq '0') { break }
    try {
        switch ($choice) {
            '1' { Invoke-ConnectionCheck }
            '2' { Invoke-RootAccess }
            '3' { Invoke-BackupAction }
            '4' { Invoke-RamTrialAction }
            '5' { Invoke-FlashAction }
            '6' { Invoke-ConfirmAction }
            '7' { Invoke-ReturnStockAction }
            '8' { Invoke-RequirementsAction }
            '9' { Show-LogsAndInfo }
            'G' { Invoke-StorageExpansionAction }
            'A' {
                $newIp = Read-Host 'Cihaz IPv4 adresi'
                if (-not (Test-Ex520vIPv4 $newIp)) { throw 'Geçersiz IPv4 adresi.' }
                $script:DeviceIp = $newIp
                Write-Ok "Cihaz adresi değiştirildi: $newIp"
            }
            default { Write-Warn 'Geçersiz seçim.' }
        }
    }
    catch {
        Write-Ex520vLog -Level ERROR -Message $_.Exception.Message
        Write-Fail ('HATA: ' + $_.Exception.Message)
        Write-Warn 'Bir yazma işlemi başlamışsa cihazı kapatmadan önce günlükteki son doğrulanmış adımı inceleyin.'
    }
    Write-Host ''
    [void](Read-Host 'Ana menü için Enter')
}
