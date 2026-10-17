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

function Read-ExactConfirmation {
    param([Parameter(Mandatory = $true)][string]$Message, [Parameter(Mandatory = $true)][string]$Word)
    Write-Warn $Message
    $answer = Read-Host "Devam etmek için $Word yazın"
    return ($answer -ceq $Word)
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
    Write-Host 'A. Cihaz IP adresini değiştir'
    Write-Host '0. Çıkış'
    Write-Host '--------------------------------------------------------'
}

function Get-ReadyFirmware {
    $firmware = Get-Ex520vLocalFirmware
    if ($firmware) { return $firmware }
    Write-Warn 'Doğrulanmış EX520v firmware çifti bulunamadı.'
    Write-Host '1) Son kararlı GitHub sürümünü indir ve doğrula'
    Write-Host '2) Yerel dosyaları seç'
    Write-Host '0) İptal'
    $choice = Read-Host 'Seçim'
    if ($choice -eq '1') {
        Write-Info 'Firmware GitHub Releases üzerinden indiriliyor...'
        return Get-Ex520vReleaseFirmware
    }
    if ($choice -eq '2') {
        $init = Read-Host 'initramfs-kernel.bin tam yolu'
        $sys = Read-Host 'squashfs-sysupgrade.bin tam yolu'
        $sha = Read-Host 'SHA256SUMS.ex520v veya sha256sums tam yolu'
        $result = Test-Ex520vFirmwareSet -InitramfsPath $init -SysupgradePath $sys -ManifestPath $sha
        if (-not $result.Valid) { throw ('Firmware doğrulanamadı: ' + ($result.Errors -join ' ')) }
        return $result
    }
    return $null
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
    Write-Warn 'Root aracı EX520v_260514 (tam) ve EX520v-v1.0_250522 (çekirdek root) profillerini destekler.'
    Write-Warn 'Windows root motoru eski firmware cihazda doğrulandı; temiz sistem bağımlılık kurulumu ayrıca test edilmelidir.'
    Write-Host 'Gerekirse Chrome açılır; stok web panelinde kendi bilgilerinizle giriş yapmanız istenir.'
    if (-not (Read-ExactConfirmation -Message 'Root aracı kendi uyumluluk ve imza kontrollerini çalıştıracaktır.' -Word 'ROOT')) { Write-Warn 'İşlem iptal edildi.'; return }
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
    Write-Info 'İmajlar hazırlanıyor, cihaza aktarılıyor ve yazmasız referans kontrolü çalıştırılıyor...'
    [void](Install-Ex520vRamTrial -LiveState $state -Firmware $firmware -BackupPath $backup)
    if (-not (Read-ExactConfirmation -Message 'Bu işlem pasif ubi0 slotunu biçimlendirip OpenWrt deneme imajını yazacaktır. Çalışan ubi1 stok slotuna dokunulmaz.' -Word 'OPENWRT')) { Write-Warn 'Yazma işlemi iptal edildi.'; return }
    $fresh = Update-LiveState
    $gate = Test-Ex520vOperationAllowed -Action RamTrial -LiveState $fresh -BackupComplete $true -FirmwareValid $true
    if (-not $gate.Allowed) { throw ('Cihaz durumu değişti: ' + ($gate.Reasons -join ' ')) }
    [void](Start-Ex520vRamTrialWrite -LiveState $fresh -BackupPath $backup)
    Write-Ok 'ubi0 yazıldı ve geri okuma doğrulandı. Deneme boot ayarları etkin.'
    if (Read-ExactConfirmation -Message 'Cihaz şimdi yeniden başlatılabilir. Bağlantı kesilmesi tek başına başarı sayılmayacaktır.' -Word 'YENİDEN-BAŞLAT') {
        Restart-Ex520vDevice -LiveState $fresh
        Write-Info 'Cihazın RAM deneme ortamıyla açılması bekleniyor...'
        $verified = Wait-Ex520vDeviceState -DeviceIp $script:DeviceIp -ExpectedSystems @('RAM deneme')
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
    if (-not (Read-ExactConfirmation -Message 'Bu işlem yalnız doğrulanmış RAM deneme ortamındaki ubi0 volume düzenini flash OpenWrt için yeniden yazacaktır.' -Word 'FLASH')) { Write-Warn 'Yazma işlemi iptal edildi.'; return }
    $fresh = Update-LiveState
    $gate = Test-Ex520vOperationAllowed -Action Flash -LiveState $fresh -BackupComplete $true -FirmwareValid $true
    if (-not $gate.Allowed) { throw ('Cihaz durumu değişti: ' + ($gate.Reasons -join ' ')) }
    [void](Install-Ex520vFlashTrial -LiveState $fresh -Firmware $firmware -BackupPath $backup -Execute)
    Write-Ok 'OpenWrt flash volume yazmaları ve geri okuma doğrulaması tamamlandı.'
    if (Read-ExactConfirmation -Message 'Cihaz flash deneme sistemiyle açılmak üzere yeniden başlatılabilir.' -Word 'YENİDEN-BAŞLAT') {
        Restart-Ex520vDevice -LiveState $fresh
        Write-Info 'Flash deneme ortamı bekleniyor...'
        [void](Wait-Ex520vDeviceState -DeviceIp $script:DeviceIp -ExpectedSystems @('Flash deneme'))
        Write-Ok 'OpenWrt flash üzerinden, stok geri dönüşü etkin durumda doğrulandı.'
    }
}

function Invoke-ConfirmAction {
    $state = Update-LiveState
    $gate = Test-Ex520vOperationAllowed -Action Confirm -LiveState $state
    if (-not $gate.Allowed) { throw ($gate.Reasons -join ' ') }
    Write-Warn 'Kalıcılaştırma, her açılışta stoka dönüşü sağlayan deneme bayrağını kaldırır. Stok firmware ubi1 slotunda korunur.'
    if (-not (Read-ExactConfirmation -Message 'OpenWrt işlevlerini test ettiyseniz devam edin.' -Word 'KALICI')) { Write-Warn 'İşlem iptal edildi.'; return }
    $fresh = Update-LiveState
    [void](Confirm-Ex520vOpenWrt -LiveState $fresh)
    $verified = Update-LiveState
    if ($verified.System -ne 'Kalıcı OpenWrt') { throw 'Boot environment değişti ancak kalıcı durum canlı cihazdan doğrulanamadı.' }
    Write-Ok 'OpenWrt kalıcı olarak seçildi; stok firmware ubi1 slotunda korundu.'
}

function Invoke-ReturnStockAction {
    $state = Update-LiveState
    Write-Host 'Bu işlem yedek dosyalarını flasha geri yüklemez; korunmuş ubi1 stok slotunu seçer.'
    [void](Return-Ex520vToStock -LiveState $state)
    if (-not (Read-ExactConfirmation -Message 'Stok slotu doğrulandı. Sonraki açılış için ubi1 seçilecektir.' -Word 'STOKA-DÖN')) { Write-Warn 'İşlem iptal edildi.'; return }
    $fresh = Update-LiveState
    [void](Return-Ex520vToStock -LiveState $fresh -Execute)
    Write-Ok 'Stok slotu bir sonraki açılış için seçildi.'
    if (Read-ExactConfirmation -Message 'Cihaz şimdi yeniden başlatılabilir.' -Word 'YENİDEN-BAŞLAT') {
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
    if ((Read-Host 'Son kararlı firmware sürümünü indirmek ister misiniz? (e/H)') -match '^[eEyY]') {
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
