# Copyright (C) 2026 TP-Link EX520v OpenWrt Tool contributors
# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:SupportedModel = 'EX520v'
$script:SupportedRootFirmware = @('EX520v_260514', 'EX520v-v1.0_250522')
$script:ReleaseRepository = 'yibudak/ex520v-openwrt'

function Get-Ex520vPaths {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Root       = $script:ProjectRoot
        Backups    = Join-Path $script:ProjectRoot 'Backups'
        Files      = Join-Path $script:ProjectRoot 'files'
        Install    = Join-Path $script:ProjectRoot 'install'
        Logs       = Join-Path $script:ProjectRoot 'logs'
        State      = Join-Path $script:ProjectRoot 'state'
        RootTool   = Join-Path $script:ProjectRoot 'root-tool'
        CurrentLog = Join-Path (Join-Path $script:ProjectRoot 'logs') ('ex520v-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    }
}

function Initialize-Ex520vTool {
    [CmdletBinding()]
    param()

    $paths = Get-Ex520vPaths
    foreach ($path in @($paths.Backups, $paths.Files, $paths.Logs, $paths.State)) {
        if (-not (Test-Path -LiteralPath $path)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
    }
    Write-Ex520vLog -Level INFO -Message 'Uygulama başlatıldı.'
    return $paths
}

function Protect-LogText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }
    $safe = $Text
    $safe = [regex]::Replace($safe, '(?im)(password|parola|token|secret)\s*[:=]\s*\S+', '$1=[GİZLENDİ]')
    $safe = [regex]::Replace($safe, '(?im)^-----BEGIN [^-]+ PRIVATE KEY-----[\s\S]*?^-----END [^-]+ PRIVATE KEY-----', '[ÖZEL ANAHTAR GİZLENDİ]')
    return $safe
}

function Write-Ex520vLog {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory = $true)][string]$Message
    )

    $paths = Get-Ex520vPaths
    if (-not (Test-Path -LiteralPath $paths.Logs)) {
        [void](New-Item -ItemType Directory -Path $paths.Logs -Force)
    }
    $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, (Protect-LogText $Message), [Environment]::NewLine
    [IO.File]::AppendAllText($paths.CurrentLog, $line, $script:Utf8NoBom)
}

function Test-Ex520vIPv4 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Address)

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    if ($Address -in @('0.0.0.0', '255.255.255.255')) { return $false }
    return $true
}

function Test-TcpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 1200
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    if ($Value.Length -eq 0) { return '""' }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Ex520vNativeText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30,
        [switch]$DoNotLogArguments
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $DoNotLogArguments) {
        Write-Ex520vLog -Level DEBUG -Message ('Çalıştırılıyor: {0} {1}' -f $FilePath, ($Arguments -join ' '))
    }
    else {
        Write-Ex520vLog -Level DEBUG -Message ('Çalıştırılıyor: {0} [argümanlar gizli]' -f $FilePath)
    }
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        throw "İşlem zaman aşımına uğradı: $FilePath"
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()
    [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
}

function Invoke-Ex520vNativeToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [int]$TimeoutSeconds = 300
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    Write-Ex520vLog -Level DEBUG -Message ('İkili çıktı alınıyor: {0} -> {1}' -f $FilePath, $OutputPath)
    [void]$process.Start()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stream = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($stream)
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "İşlem zaman aşımına uğradı: $FilePath"
        }
        $copyTask.Wait()
    }
    finally { $stream.Dispose() }
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()
    [pscustomobject]@{ ExitCode = $exitCode; StdErr = $stderr }
}

function Invoke-Ex520vNativeFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$InputPath,
        [int]$TimeoutSeconds = 300
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    Write-Ex520vLog -Level DEBUG -Message ('İkili girdi gönderiliyor: {0} <- {1}' -f $FilePath, $InputPath)
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $input = [IO.File]::OpenRead($InputPath)
    try {
        $copyTask = $input.CopyToAsync($process.StandardInput.BaseStream)
        if (-not $copyTask.Wait($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "İkili aktarım zaman aşımına uğradı: $InputPath"
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Uzak doğrulama zaman aşımına uğradı: $InputPath"
        }
    }
    finally {
        $input.Dispose()
        if (-not $process.HasExited) { try { $process.Kill() } catch {} }
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()
    [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
}

function Get-Ex520vCommand {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Source
}

function Get-Ex520vRootProfiles {
    [CmdletBinding()]
    param()

    $base = if ($env:EX520_ROOT_STATE) { $env:EX520_ROOT_STATE } else { Join-Path $env:USERPROFILE '.local\state\ex520-root' }
    $candidates = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $base) { [void]$candidates.Add($base) }
    $devices = Join-Path $base 'devices'
    if (Test-Path -LiteralPath $devices) {
        Get-ChildItem -LiteralPath $devices -Directory -ErrorAction SilentlyContinue | ForEach-Object { [void]$candidates.Add($_.FullName) }
    }
    foreach ($directory in $candidates) {
        $key = Join-Path $directory 'ssh-id-rsa'
        $known = Join-Path $directory 'known_hosts'
        if ((Test-Path -LiteralPath $key -PathType Leaf) -and (Test-Path -LiteralPath $known -PathType Leaf)) {
            [pscustomobject]@{
                Kind = 'Stock'
                Id = Split-Path -Leaf $directory
                Directory = $directory
                IdentityFile = $key
                KnownHostsFile = $known
                Port = 2222
            }
        }
    }
}

function Get-Ex520vOpenWrtProfile {
    [CmdletBinding()]
    param([ValidateSet('Ram', 'Flash')][string]$Phase = 'Ram')
    $paths = Get-Ex520vPaths
    [pscustomobject]@{
        Kind = 'OpenWrt'
        Id = ('openwrt-' + $Phase.ToLowerInvariant())
        Directory = $paths.State
        IdentityFile = $null
        KnownHostsFile = Join-Path $paths.State ('known_hosts_openwrt_' + $Phase.ToLowerInvariant())
        Port = 22
    }
}

function Reset-Ex520vOpenWrtKnownHost {
    param([Parameter(Mandatory = $true)][ValidateSet('Ram', 'Flash')][string]$Phase)
    $profile = Get-Ex520vOpenWrtProfile -Phase $Phase
    if (Test-Path -LiteralPath $profile.KnownHostsFile) {
        Remove-Item -LiteralPath $profile.KnownHostsFile -Force
        Write-Ex520vLog -Level INFO -Message "Beklenen yeni $Phase OpenWrt açılışı için eski yerel host key kaydı kaldırıldı."
    }
}

function Test-Ex520vSshProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Profile)

    if ($Profile.Kind -eq 'Stock') {
        if (-not (Test-Path -LiteralPath $Profile.IdentityFile -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $Profile.KnownHostsFile -PathType Leaf)) { return $false }
    }
    return ($null -ne (Get-Ex520vCommand 'ssh.exe'))
}

function Get-SshArguments {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$DeviceIp,
        [Parameter(Mandatory = $true)][string]$RemoteCommand
    )

    $strict = if ($Profile.Kind -eq 'Stock') { 'yes' } else { 'accept-new' }
    $arguments = @(
        '-p', [string]$Profile.Port,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=8',
        '-o', 'ConnectionAttempts=1',
        '-o', "StrictHostKeyChecking=$strict",
        '-o', "UserKnownHostsFile=$($Profile.KnownHostsFile)",
        '-o', 'LogLevel=ERROR'
    )
    if ($Profile.IdentityFile) {
        $arguments += @('-o', 'IdentitiesOnly=yes', '-i', $Profile.IdentityFile)
    }
    $arguments += @("root@$DeviceIp", $RemoteCommand)
    return $arguments
}

function Invoke-Ex520vSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$DeviceIp,
        [Parameter(Mandatory = $true)][string]$RemoteCommand,
        [int]$TimeoutSeconds = 30
    )

    if (-not (Test-Ex520vIPv4 $DeviceIp)) { throw 'Geçersiz cihaz IPv4 adresi.' }
    if (-not (Test-Ex520vSshProfile $Profile)) { throw 'SSH istemcisi veya cihaz kimlik dosyası bulunamadı.' }
    $ssh = Get-Ex520vCommand 'ssh.exe'
    $result = Invoke-Ex520vNativeText -FilePath $ssh -Arguments (Get-SshArguments $Profile $DeviceIp $RemoteCommand) -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        $detail = (Protect-LogText $result.StdErr).Trim()
        Write-Ex520vLog -Level ERROR -Message "SSH başarısız (kod $($result.ExitCode)): $detail"
        throw "SSH bağlantısı başarısız (kod $($result.ExitCode)). $detail"
    }
    return $result.StdOut
}

function Invoke-Ex520vSshToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$DeviceIp,
        [Parameter(Mandatory = $true)][string]$RemoteCommand,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [int]$TimeoutSeconds = 600
    )

    $ssh = Get-Ex520vCommand 'ssh.exe'
    if (-not $ssh) { throw 'Windows OpenSSH istemcisi bulunamadı.' }
    $result = Invoke-Ex520vNativeToFile -FilePath $ssh -Arguments (Get-SshArguments $Profile $DeviceIp $RemoteCommand) -OutputPath $OutputPath -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "SSH veri aktarımı başarısız (kod $($result.ExitCode)): $($result.StdErr.Trim())"
    }
}

function Send-Ex520vFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$DeviceIp,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][ValidatePattern('^/tmp/[A-Za-z0-9._/-]+$')][string]$RemotePath,
        [int]$TimeoutSeconds = 300
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) { throw "Aktarılacak dosya bulunamadı: $LocalPath" }
    $ssh = Get-Ex520vCommand 'ssh.exe'
    if (-not $ssh) { throw 'Windows OpenSSH istemcisi bulunamadı.' }
    $expected = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $temporary = $RemotePath + '.new'
    $remoteCommand = @"
set -e; umask 077; /bin/busybox rm -f '$temporary';
/bin/busybox dd of='$temporary' bs=65536 2>/dev/null;
if command -v sha256sum >/dev/null 2>&1; then
got=`$(sha256sum '$temporary' | /bin/busybox awk '{print `$1}');
elif [ -x /usr/sbin/openssl ]; then
got=`$(/usr/sbin/openssl dgst -sha256 -r '$temporary' | /bin/busybox awk '{print `$1}');
else exit 91; fi;
[ "`$got" = '$expected' ];
/bin/busybox mv '$temporary' '$RemotePath'
"@
    $remoteCommand = ($remoteCommand -replace '\r?\n', ' ').Trim()
    $result = Invoke-Ex520vNativeFromFile -FilePath $ssh -Arguments (Get-SshArguments $Profile $DeviceIp $remoteCommand) -InputPath $LocalPath -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "SSH veri aktarımı veya SHA256 doğrulaması başarısız: $($result.StdErr.Trim())"
    }
}

function ConvertFrom-KeyValueText {
    param([AllowEmptyString()][string]$Text)
    $values = @{}
    foreach ($line in ($Text -split '\r?\n')) {
        $match = [regex]::Match($line, '^([A-Z0-9_]+)=(.*)$')
        if ($match.Success) {
            $values[$match.Groups[1].Value] = $match.Groups[2].Value.Trim()
        }
    }
    return $values
}

function Resolve-Ex520vSystemState {
    [CmdletBinding()]
    param(
        [string]$Transport,
        [string]$Model,
        [string]$CommandLine,
        [string]$BoardName,
        [string]$RootFs,
        [string]$RomFs,
        [string]$OverlayFs,
        [string]$RootSource,
        [string]$OverlaySource,
        [string]$Trial,
        [string]$TrialMarker,
        [string]$BootIndex
    )

    if ($Transport -eq 'Stock') {
        if ($Model -ne $script:SupportedModel) { return 'Yanlış cihaz' }
        if ($CommandLine -match '(^|\s)ubi\.mtd=ubi1(\s|$)') { return 'Stok' }
        return 'Bilinmiyor'
    }
    if ($Transport -ne 'OpenWrt' -or $BoardName -ne 'tplink,ex520v') { return 'Bilinmiyor' }
    # A normal OpenWrt squashfs installation exposes / as overlayfs.  /rom is
    # the read-only squashfs and /overlay must come from ubi0, the OpenWrt
    # slot.  Checking RootFs=squashfs therefore misclassifies a real flash
    # boot as initramfs.
    if ($RomFs -eq 'squashfs' -and $OverlayFs -eq 'ubifs' -and $OverlaySource -match '^/dev/ubi0_') {
        if ($Trial -eq '1') { return 'Flash deneme' }
        if ([string]::IsNullOrWhiteSpace($Trial)) { return 'Kalıcı OpenWrt' }
        return 'Bilinmiyor'
    }
    if ($RootFs -ne 'squashfs') {
        # Flash deneme volume'leri hazırlandıktan sonra tp_boot_idx kasıtlı
        # olarak silinir; çalışan initramfs yine güvenli RAM denemesidir.
        if ($Trial -eq '1' -and $BootIndex -in @('', '1') -and $TrialMarker -eq 'armed') { return 'RAM deneme' }
        return 'Bilinmiyor'
    }
    return 'Bilinmiyor'
}

function Get-Ex520vLiveState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceIp)

    if (-not (Test-Ex520vIPv4 $DeviceIp)) { throw 'Geçersiz cihaz IPv4 adresi.' }
    $web = Test-TcpPort -Address $DeviceIp -Port 80
    $base = [ordered]@{
        DeviceIp = $DeviceIp; WebReachable = $web; RootSsh = $false; Transport = 'None'
        System = 'Bilinmiyor'; Model = ''; Firmware = ''; Hardware = ''; BoardName = ''
        CommandLine = ''; BootIndex = ''; Trial = ''; TrialMarker = ''; MtdNames = @()
        RootFs = ''; RomFs = ''; OverlayFs = ''; RootSource = ''; OverlaySource = ''
        Profile = $null; Error = ''
    }

    if (Test-TcpPort -Address $DeviceIp -Port 2222) {
        # Eski stok firmware'in BusyBox derlemesinde printf/id appletleri yoktur.
        # Tek satırlı, mutlak yollu komut aynı zamanda Windows ProcessStartInfo
        # üzerinden çok satırlı argüman aktarımındaki kaçış farklarını önler.
        $stockCommand = @(
            '/bin/busybox echo MODEL=$(/bin/busybox cat /proc/sys/kernel/hostname)'
            '/bin/busybox echo CMDLINE=$(/bin/busybox cat /proc/cmdline)'
            '/bin/busybox echo BOOTIDX=$(/usr/bin/fw_printenv -n tp_boot_idx 2>/dev/null)'
            '/bin/busybox echo TRIAL=$(/usr/bin/fw_printenv -n ex520v_trial 2>/dev/null)'
            '/bin/busybox echo MTD=$(/bin/busybox awk -F''"'' ''/^mtd/{print $2}'' /proc/mtd | /bin/busybox tr ''\n'' '','')'
        ) -join '; '
        foreach ($profile in @(Get-Ex520vRootProfiles)) {
            try {
                $data = ConvertFrom-KeyValueText (Invoke-Ex520vSsh -Profile $profile -DeviceIp $DeviceIp -RemoteCommand $stockCommand)
                $base.RootSsh = $true; $base.Transport = 'Stock'; $base.Profile = $profile
                $base.Model = [string]$data.MODEL; $base.CommandLine = [string]$data.CMDLINE
                $base.BootIndex = [string]$data.BOOTIDX; $base.Trial = [string]$data.TRIAL
                $base.MtdNames = @(([string]$data.MTD -split ',') | Where-Object { $_ })
                $base.System = Resolve-Ex520vSystemState -Transport Stock -Model $base.Model -CommandLine $base.CommandLine
                $base.Error = ''
                return [pscustomobject]$base
            }
            catch { $base.Error = $_.Exception.Message }
        }
    }

    if (Test-TcpPort -Address $DeviceIp -Port 22) {
        $openWrtCommand = @(
            '. /lib/functions.sh'
            'echo BOARD=$(board_name)'
            'echo ROOTFS=$(awk ''$2=="/"{print $3;exit}'' /proc/mounts)'
            'echo ROMFS=$(awk ''$2=="/rom"{print $3;exit}'' /proc/mounts)'
            'echo OVERLAYFS=$(awk ''$2=="/overlay"{print $3;exit}'' /proc/mounts)'
            'echo ROOTSRC=$(awk ''$2=="/rom"{print $1;exit}'' /proc/mounts)'
            'echo OVERLAYSRC=$(awk ''$2=="/overlay"{print $1;exit}'' /proc/mounts)'
            'echo BOOTIDX=$(fw_printenv -n tp_boot_idx 2>/dev/null)'
            'echo TRIAL=$(fw_printenv -n ex520v_trial 2>/dev/null)'
            'echo TRIALMARK=$(cat /tmp/ex520v-trial 2>/dev/null)'
            '. /etc/openwrt_release; echo FIRMWARE=$DISTRIB_DESCRIPTION'
            'echo MTD=$(awk -F''"'' ''/^mtd/{print $2}'' /proc/mtd | tr ''\n'' '','')'
        ) -join '; '
        foreach ($profile in @((Get-Ex520vOpenWrtProfile -Phase Ram), (Get-Ex520vOpenWrtProfile -Phase Flash))) {
            try {
                $data = ConvertFrom-KeyValueText (Invoke-Ex520vSsh -Profile $profile -DeviceIp $DeviceIp -RemoteCommand $openWrtCommand)
                $base.RootSsh = $true; $base.Transport = 'OpenWrt'; $base.Profile = $profile
                $base.BoardName = [string]$data.BOARD; $base.Model = if ($base.BoardName -eq 'tplink,ex520v') { 'EX520v' } else { $base.BoardName }
                $base.Firmware = [string]$data.FIRMWARE; $base.BootIndex = [string]$data.BOOTIDX
                $base.Trial = [string]$data.TRIAL; $base.TrialMarker = [string]$data.TRIALMARK
                $base.RootFs = [string]$data.ROOTFS; $base.RomFs = [string]$data.ROMFS
                $base.OverlayFs = [string]$data.OVERLAYFS; $base.RootSource = [string]$data.ROOTSRC
                $base.OverlaySource = [string]$data.OVERLAYSRC
                $base.MtdNames = @(([string]$data.MTD -split ',') | Where-Object { $_ })
                $base.System = Resolve-Ex520vSystemState -Transport OpenWrt -BoardName $base.BoardName -RootFs $base.RootFs -RomFs $base.RomFs -OverlayFs $base.OverlayFs -RootSource $base.RootSource -OverlaySource $base.OverlaySource -Trial $base.Trial -TrialMarker $base.TrialMarker -BootIndex $base.BootIndex
                $base.Error = ''
                return [pscustomobject]$base
            }
            catch { $base.Error = $_.Exception.Message }
        }
    }
    return [pscustomobject]$base
}

function Test-Ex520vFlashLayout {
    [CmdletBinding()]
    param([string[]]$MtdNames)
    $required = @('boot', 'u-boot-env', 'misc_ro', 'misc_rw', 'ubi0', 'ubi1', 'bflag', 'container')
    return (@($required | Where-Object { $_ -notin $MtdNames }).Count -eq 0)
}

function Test-Ex520vRootCompatibility {
    [CmdletBinding()]
    param([string]$Model, [string]$Firmware)
    return ($Model -eq $script:SupportedModel -and $Firmware -in $script:SupportedRootFirmware)
}

function Test-Ex520vRemoteCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('RamTrial', 'Flash', 'Confirm', 'ReturnStock')][string]$Action,
        [int]$ExitCode,
        [AllowEmptyString()][string]$Output
    )
    if ($ExitCode -ne 0) { return $false }
    $marker = switch ($Action) {
        'RamTrial'   { 'DONE: slot ubi0 holds OpenWrt' }
        'Flash'      { 'DONE: reboot to start OpenWrt from flash' }
        'Confirm'    { 'DONE: OpenWrt is now the default' }
        'ReturnStock'{ 'DONE: stock slot ubi1 selected' }
    }
    if ($Output -match '(?i)(ERROR:|read-back mismatch|could not set|still set|failed)') { return $false }
    return ($Output -like "*$marker*")
}

function Test-Ex520vOperationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Backup', 'RamTrial', 'Flash', 'Confirm', 'ReturnStock')][string]$Action,
        [Parameter(Mandatory = $true)]$LiveState,
        [bool]$BackupComplete = $false,
        [bool]$FirmwareValid = $false
    )

    $reasons = New-Object Collections.Generic.List[string]
    if (-not $LiveState.RootSsh) { [void]$reasons.Add('UID 0 SSH bağlantısı doğrulanmadı.') }
    if ($LiveState.Model -ne $script:SupportedModel) { [void]$reasons.Add('Cihaz modeli EX520v olarak doğrulanmadı.') }
    if ($LiveState.RootSsh -and -not (Test-Ex520vFlashLayout $LiveState.MtdNames)) { [void]$reasons.Add('Beklenen MTD bölüm düzeni doğrulanmadı.') }
    switch ($Action) {
        'Backup' {
            if ($LiveState.System -ne 'Stok') { [void]$reasons.Add('Yedek yalnız stok sistemde alınabilir.') }
            if ($LiveState.BootIndex -ne '1') { [void]$reasons.Add('Aktif stok slotu ubi1/tp_boot_idx=1 değil.') }
        }
        'RamTrial' {
            if ($LiveState.System -ne 'Stok') { [void]$reasons.Add('RAM denemesi yalnız stok sistemden başlatılabilir.') }
            if ($LiveState.BootIndex -ne '1' -or $LiveState.CommandLine -notmatch 'ubi\.mtd=ubi1') { [void]$reasons.Add('Stok sistem ubi1 slotundan çalışmıyor.') }
            if (-not $BackupComplete) { [void]$reasons.Add('Bu cihaza ait doğrulanmış tam yedek bulunamadı.') }
            if (-not $FirmwareValid) { [void]$reasons.Add('Firmware dosyaları doğrulanmadı.') }
        }
        'Flash' {
            if ($LiveState.System -ne 'RAM deneme') { [void]$reasons.Add('Flash kurulumu yalnız RAM deneme ortamında yapılabilir.') }
            if ($LiveState.Trial -ne '1' -or $LiveState.BootIndex -ne '1' -or $LiveState.TrialMarker -ne 'armed') { [void]$reasons.Add('Stok geri dönüş mekanizması aktif değil.') }
            if (-not $BackupComplete) { [void]$reasons.Add('Doğrulanmış stok yedeği bulunamadı.') }
            if (-not $FirmwareValid) { [void]$reasons.Add('Sysupgrade dosyası doğrulanmadı.') }
        }
        'Confirm' {
            if ($LiveState.System -ne 'Flash deneme') { [void]$reasons.Add('Kalıcılaştırma yalnız flash deneme sisteminde yapılabilir.') }
            if ($LiveState.Trial -ne '1') { [void]$reasons.Add('Deneme durumu aktif değil.') }
        }
        'ReturnStock' {
            if ($LiveState.System -notin @('RAM deneme', 'Flash deneme', 'Kalıcı OpenWrt')) { [void]$reasons.Add('Slot tabanlı dönüş yalnız çalışan OpenWrt üzerinden yapılabilir.') }
        }
    }
    [pscustomobject]@{ Allowed = ($reasons.Count -eq 0); Reasons = @($reasons) }
}

function Get-Ex520vDeviceId {
    param([Parameter(Mandatory = $true)]$LiveState)
    if ($LiveState.Profile -and $LiveState.Profile.Kind -eq 'Stock' -and $LiveState.Profile.Id -and $LiveState.Profile.Id -ne 'ex520-root') { return [string]$LiveState.Profile.Id }
    $mac = ''
    try {
        $neighbor = Get-NetNeighbor -IPAddress $LiveState.DeviceIp -ErrorAction Stop | Where-Object { $_.LinkLayerAddress -match '^(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$' } | Select-Object -First 1
        if ($neighbor) { $mac = $neighbor.LinkLayerAddress }
    }
    catch {}
    if (-not $mac) {
        try {
            $arp = Invoke-Ex520vNativeText -FilePath 'arp.exe' -Arguments @('-a', $LiveState.DeviceIp) -TimeoutSeconds 5
            $match = [regex]::Match($arp.StdOut, '(?i)(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}')
            if ($match.Success) { $mac = $match.Value }
        }
        catch {}
    }
    if ($mac) {
        $normalized = ($mac -replace '[:-]', '').ToLowerInvariant()
        $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16).ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    $paths = Get-Ex520vPaths
    $matchingIds = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $paths.Backups -Directory -ErrorAction SilentlyContinue)) {
        $metadataPath = Join-Path $directory.FullName 'backup.json'
        if (-not (Test-Path -LiteralPath $metadataPath)) { continue }
        try {
            $metadata = Get-Content -Raw -Encoding UTF8 $metadataPath | ConvertFrom-Json
            if ($metadata.complete -eq $true -and $metadata.device_ip -eq $LiveState.DeviceIp) { $matchingIds += [string]$metadata.device_id }
        }
        catch {}
    }
    $uniqueIds = @($matchingIds | Sort-Object -Unique)
    if ($uniqueIds.Count -eq 1) { return $uniqueIds[0] }
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$LiveState.DeviceIp)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-Ex520vBackupDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [string]$DeviceId)

    $metadataPath = Join-Path $Path 'backup.json'
    $manifestPath = Join-Path $Path 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    try { $metadata = Get-Content -Raw -Encoding UTF8 $metadataPath | ConvertFrom-Json } catch { return $false }
    if ($metadata.complete -ne $true) { return $false }
    if ($DeviceId -and $metadata.device_id -ne $DeviceId) { return $false }
    foreach ($line in (Get-Content -Encoding UTF8 $manifestPath)) {
        if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { return $false }
        $file = Join-Path $Path $Matches[2]
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $Matches[1]) { return $false }
    }
    return $true
}

function Find-Ex520vBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceId)
    $paths = Get-Ex520vPaths
    foreach ($directory in @(Get-ChildItem -LiteralPath $paths.Backups -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        if (Test-Ex520vBackupDirectory -Path $directory.FullName -DeviceId $DeviceId) { return $directory.FullName }
    }
    return $null
}

function Save-Ex520vStockBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState)

    $gate = Test-Ex520vOperationAllowed -Action Backup -LiveState $LiveState
    if (-not $gate.Allowed) { throw ($gate.Reasons -join ' ') }
    $paths = Get-Ex520vPaths
    $deviceId = Get-Ex520vDeviceId $LiveState
    $name = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $deviceId
    $partial = Join-Path $paths.Backups ($name + '.partial')
    $final = Join-Path $paths.Backups $name
    [void](New-Item -ItemType Directory -Path $partial -Force)
    Write-Ex520vLog -Level INFO -Message "Stok yedekleme başladı: cihaz=$deviceId"
    try {
        $mtdText = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'cat /proc/mtd'
        [IO.File]::WriteAllText((Join-Path $partial 'proc_mtd.txt'), $mtdText, $script:Utf8NoBom)
        $partitions = @()
        foreach ($line in ($mtdText -split '\r?\n')) {
            if ($line -match '^(mtd\d+):\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+"([^"]+)"') {
                if ($Matches[3] -notin @('spi0.0', 'whole')) {
                    $partitions += [pscustomobject]@{ Device = $Matches[1]; Size = [Convert]::ToInt64($Matches[2], 16); Name = $Matches[3] }
                }
            }
        }
        if ($partitions.Count -lt 8 -or -not (Test-Ex520vFlashLayout @($partitions.Name))) { throw 'Beklenen MTD düzeni yedekleme öncesinde doğrulanamadı.' }
        $needed = [int64](($partitions | Measure-Object Size -Sum).Sum + 64MB)
        $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($partial).TrimEnd('\').TrimEnd(':'))
        if ($drive.Free -lt $needed) { throw "Yedek için yetersiz disk alanı. En az $needed bayt boş alan gerekli." }

        $envText = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'fw_printenv'
        [IO.File]::WriteAllText((Join-Path $partial 'fw_printenv.txt'), $envText, $script:Utf8NoBom)
        Invoke-Ex520vSshToFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'cat /sys/firmware/fdt' -OutputPath (Join-Path $partial 'stock.dtb') -TimeoutSeconds 60
        if ((Get-Item -LiteralPath (Join-Path $partial 'stock.dtb')).Length -lt 1024) { throw 'Device tree yedeği eksik veya kesilmiş.' }

        foreach ($partition in $partitions) {
            $safeName = $partition.Name -replace '[^A-Za-z0-9._-]', '_'
            $destination = Join-Path $partial ('{0}-{1}.bin' -f $partition.Device, $safeName)
            Invoke-Ex520vSshToFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand ("cat /dev/{0}" -f $partition.Device) -OutputPath $destination -TimeoutSeconds 1200
            $actual = (Get-Item -LiteralPath $destination).Length
            if ($actual -ne $partition.Size) { throw "Eksik MTD yedeği: $($partition.Device), $actual != $($partition.Size)" }
        }

        $hashLines = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $partial -File | Where-Object { $_.Extension -in @('.bin', '.dtb', '.txt') } | Sort-Object Name)) {
            $hashLines += ('{0}  {1}' -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $file.Name)
        }
        [IO.File]::WriteAllText((Join-Path $partial 'SHA256SUMS'), (($hashLines -join "`n") + "`n"), $script:Utf8NoBom)
        $metadata = [ordered]@{ complete = $true; device_id = $deviceId; device_ip = $LiveState.DeviceIp; model = $LiveState.Model; system = $LiveState.System; created_at = (Get-Date).ToString('o'); partition_count = $partitions.Count }
        [IO.File]::WriteAllText((Join-Path $partial 'backup.json'), (($metadata | ConvertTo-Json -Depth 4) + "`n"), $script:Utf8NoBom)
        if (-not (Test-Ex520vBackupDirectory -Path $partial -DeviceId $deviceId)) { throw 'Yedek son doğrulamadan geçemedi.' }
        Move-Item -LiteralPath $partial -Destination $final
        Write-Ex520vLog -Level INFO -Message "Stok yedekleme tamamlandı: $final"
        return $final
    }
    catch {
        Write-Ex520vLog -Level ERROR -Message "Yedekleme yarım kaldı: $($_.Exception.Message)"
        throw "Yedekleme tamamlanamadı. Yarım dosyalar inceleme için korundu: $partial. $($_.Exception.Message)"
    }
}

function Get-UbiCrc32 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not ('Ex520vUbiCrc32' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class Ex520vUbiCrc32 {
    private static readonly uint[] Table = MakeTable();
    private static uint[] MakeTable() {
        uint[] table = new uint[256];
        for (uint n = 0; n < 256; n++) {
            uint c = n;
            for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xedb88320U ^ (c >> 1)) : (c >> 1);
            table[n] = c;
        }
        return table;
    }
    public static uint Compute(string path) {
        uint crc = 0xffffffffU;
        byte[] buffer = new byte[65536];
        using (FileStream stream = File.OpenRead(path)) {
            int count;
            while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                for (int i = 0; i < count; i++) crc = Table[(crc ^ buffer[i]) & 0xff] ^ (crc >> 8);
        }
        return crc;
    }
}
'@
    }
    return ('0x{0:x8}' -f [Ex520vUbiCrc32]::Compute((Resolve-Path -LiteralPath $Path).Path))
}

function Read-Sha256Manifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $entries = @{}
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $entries[$Matches[2].Trim()] = $Matches[1].ToUpperInvariant() }
    }
    return $entries
}

function Test-Ex520vFirmwareSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InitramfsPath,
        [Parameter(Mandatory = $true)][string]$SysupgradePath,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $errors = New-Object Collections.Generic.List[string]
    foreach ($path in @($InitramfsPath, $SysupgradePath, $ManifestPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { [void]$errors.Add("Dosya bulunamadı: $path") }
    }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ Valid = $false; Errors = @($errors) } }
    if ((Split-Path -Leaf $InitramfsPath) -notmatch 'tplink_ex520v-initramfs-kernel\.bin$') { [void]$errors.Add('Initramfs dosya adı EX520v hedefini göstermiyor.') }
    if ((Split-Path -Leaf $SysupgradePath) -notmatch 'tplink_ex520v-squashfs-sysupgrade\.bin$') { [void]$errors.Add('Sysupgrade dosya adı EX520v hedefini göstermiyor.') }
    $manifest = Read-Sha256Manifest $ManifestPath
    foreach ($path in @($InitramfsPath, $SysupgradePath)) {
        $name = Split-Path -Leaf $path
        if (-not $manifest.ContainsKey($name)) { [void]$errors.Add("SHA256 kaydı yok: $name"); continue }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne $manifest[$name]) { [void]$errors.Add("SHA256 uyuşmazlığı: $name") }
    }
    $first = [IO.File]::ReadAllBytes($InitramfsPath)
    if ($first.Length -lt 4 -or $first[0] -ne 0xd0 -or $first[1] -ne 0x0d -or $first[2] -ne 0xfe -or $first[3] -ne 0xed) { [void]$errors.Add('Initramfs geçerli bir FIT imajı gibi görünmüyor.') }
    $tar = Get-Ex520vCommand 'tar.exe'
    if (-not $tar) { [void]$errors.Add('Windows tar.exe bulunamadı; sysupgrade içeriği doğrulanamıyor.') }
    else {
        $listing = Invoke-Ex520vNativeText -FilePath $tar -Arguments @('-tf', $SysupgradePath) -TimeoutSeconds 60
        if ($listing.ExitCode -ne 0) { [void]$errors.Add('Sysupgrade tar arşivi açılamadı.') }
        else {
            $names = @($listing.StdOut -split '\r?\n' | Where-Object { $_ })
            foreach ($suffix in @('sysupgrade-tplink_ex520v/kernel', 'sysupgrade-tplink_ex520v/root', 'sysupgrade-tplink_ex520v/CONTROL')) {
                if (-not ($names | Where-Object { $_.TrimStart('./') -eq $suffix })) { [void]$errors.Add("Sysupgrade içeriği eksik: $suffix") }
            }
            $controlName = $names | Where-Object { $_.TrimStart('./') -eq 'sysupgrade-tplink_ex520v/CONTROL' } | Select-Object -First 1
            if ($controlName) {
                $control = Invoke-Ex520vNativeText -FilePath $tar -Arguments @('-xOf', $SysupgradePath, $controlName) -TimeoutSeconds 30
                if ($control.ExitCode -ne 0 -or $control.StdOut -notmatch '(?m)^(?:BOARD=tplink_ex520v|.*tplink,ex520v.*)$') { [void]$errors.Add('Sysupgrade metadata cihaz uyumluluğunu doğrulamıyor.') }
            }
        }
    }
    [pscustomobject]@{
        Valid = ($errors.Count -eq 0); Errors = @($errors)
        InitramfsPath = $InitramfsPath; SysupgradePath = $SysupgradePath; ManifestPath = $ManifestPath
        InitramfsSha256 = (Get-FileHash -LiteralPath $InitramfsPath -Algorithm SHA256).Hash
        SysupgradeSha256 = (Get-FileHash -LiteralPath $SysupgradePath -Algorithm SHA256).Hash
    }
}

function Get-Ex520vReleaseFirmware {
    [CmdletBinding()]
    param()

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'TP-Link-EX520v-OpenWrt-Tool' }
    $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$script:ReleaseRepository/releases/latest"
    if ($release.draft -or $release.prerelease) { throw 'Kararlı GitHub yayını bulunamadı.' }
    $requiredPatterns = @('tplink_ex520v-initramfs-kernel\.bin$', 'tplink_ex520v-squashfs-sysupgrade\.bin$', '^SHA256SUMS\.ex520v$')
    $selected = @{}
    foreach ($pattern in $requiredPatterns) {
        $asset = @($release.assets | Where-Object { $_.name -match $pattern })
        if ($asset.Count -ne 1) { throw "Yayında beklenen dosya tekil değil: $pattern" }
        $selected[$pattern] = $asset[0]
    }
    $paths = Get-Ex520vPaths
    $tag = ([string]$release.tag_name -replace '[^A-Za-z0-9._-]', '_')
    $destination = Join-Path $paths.Files $tag
    if (-not (Test-Path -LiteralPath $destination)) { [void](New-Item -ItemType Directory -Path $destination -Force) }
    foreach ($asset in $selected.Values) {
        $target = Join-Path $destination $asset.name
        $temporary = $target + '.download'
        Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $asset.browser_download_url -OutFile $temporary
        if ((Get-Item -LiteralPath $temporary).Length -ne [int64]$asset.size) { throw "Eksik indirme: $($asset.name)" }
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
    $initramfs = (Get-ChildItem -LiteralPath $destination -File | Where-Object Name -match 'tplink_ex520v-initramfs-kernel\.bin$').FullName
    $sysupgrade = (Get-ChildItem -LiteralPath $destination -File | Where-Object Name -match 'tplink_ex520v-squashfs-sysupgrade\.bin$').FullName
    $manifest = Join-Path $destination 'SHA256SUMS.ex520v'
    $validation = Test-Ex520vFirmwareSet -InitramfsPath $initramfs -SysupgradePath $sysupgrade -ManifestPath $manifest
    if (-not $validation.Valid) { throw ('İndirilen firmware doğrulanamadı: ' + ($validation.Errors -join ' ')) }
    $attestation = 'gh bulunamadı; uygulanmadı'
    $gh = Get-Ex520vCommand 'gh.exe'
    if ($gh) {
        foreach ($image in @($initramfs, $sysupgrade)) {
            $verify = Invoke-Ex520vNativeText -FilePath $gh -Arguments @('attestation', 'verify', $image, '-R', $script:ReleaseRepository) -TimeoutSeconds 120
            if ($verify.ExitCode -ne 0) { throw "GitHub build attestation doğrulanamadı: $(Split-Path -Leaf $image)" }
        }
        $attestation = 'gh attestation verify başarılı'
    }
    $metadata = [ordered]@{ repository = $script:ReleaseRepository; tag = $release.tag_name; release_id = $release.id; published_at = $release.published_at; downloaded_at = (Get-Date).ToString('o'); attestation = $attestation }
    [IO.File]::WriteAllText((Join-Path $destination 'release.json'), (($metadata | ConvertTo-Json) + "`n"), $script:Utf8NoBom)
    Write-Ex520vLog -Level INFO -Message "Firmware indirildi ve SHA256 doğrulandı: $($release.tag_name)"
    return $validation
}

function Get-Ex520vLocalFirmware {
    [CmdletBinding()]
    param()
    $paths = Get-Ex520vPaths
    foreach ($directory in @(Get-ChildItem -LiteralPath $paths.Files -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $init = Get-ChildItem -LiteralPath $directory.FullName -File | Where-Object Name -match 'tplink_ex520v-initramfs-kernel\.bin$' | Select-Object -First 1
        $sys = Get-ChildItem -LiteralPath $directory.FullName -File | Where-Object Name -match 'tplink_ex520v-squashfs-sysupgrade\.bin$' | Select-Object -First 1
        $manifest = @('SHA256SUMS.ex520v', 'sha256sums') | ForEach-Object { Join-Path $directory.FullName $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($init -and $sys -and $manifest) {
            $result = Test-Ex520vFirmwareSet -InitramfsPath $init.FullName -SysupgradePath $sys.FullName -ManifestPath $manifest
            if ($result.Valid) { return $result }
        }
    }
    return $null
}

function New-Ex520vTrialPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Firmware)

    if (-not $Firmware.Valid) { throw 'Doğrulanmamış firmware ile deneme paketi hazırlanamaz.' }
    $paths = Get-Ex520vPaths
    $work = Join-Path $paths.State 'trial-payload'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $work -Force)
    Copy-Item -LiteralPath $Firmware.InitramfsPath -Destination (Join-Path $work 'kernel.bin')
    $tar = Get-Ex520vCommand 'tar.exe'
    $listing = Invoke-Ex520vNativeText -FilePath $tar -Arguments @('-tf', $Firmware.SysupgradePath) -TimeoutSeconds 60
    $rootName = $listing.StdOut -split '\r?\n' | Where-Object { $_.TrimStart('./') -eq 'sysupgrade-tplink_ex520v/root' } | Select-Object -First 1
    if (-not $rootName) { throw 'Sysupgrade içindeki root dosyası bulunamadı.' }
    $rootPath = Join-Path $work 'rootfs.bin'
    $extract = Invoke-Ex520vNativeToFile -FilePath $tar -Arguments @('-xOf', $Firmware.SysupgradePath, $rootName) -OutputPath $rootPath -TimeoutSeconds 120
    if ($extract.ExitCode -ne 0 -or (Get-Item -LiteralPath $rootPath).Length -lt 1MB) { throw 'Sysupgrade rootfs çıkarılamadı veya beklenmedik ölçüde küçük.' }
    $lines = @()
    foreach ($name in @('kernel.bin', 'rootfs.bin')) {
        $file = Join-Path $work $name
        $lines += ('{0} {1} {2}' -f (Get-UbiCrc32 $file), (Get-Item -LiteralPath $file).Length, $name)
    }
    [IO.File]::WriteAllText((Join-Path $work 'crc.txt'), (($lines -join "`n") + "`n"), $script:Utf8NoBom)
    return $work
}

function Install-Ex520vRamTrial {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState, [Parameter(Mandatory = $true)]$Firmware, [Parameter(Mandatory = $true)][string]$BackupPath)

    $deviceId = Get-Ex520vDeviceId $LiveState
    $backupValid = Test-Ex520vBackupDirectory -Path $BackupPath -DeviceId $deviceId
    $gate = Test-Ex520vOperationAllowed -Action RamTrial -LiveState $LiveState -BackupComplete $backupValid -FirmwareValid ([bool]$Firmware.Valid)
    if (-not $gate.Allowed) { throw ($gate.Reasons -join ' ') }
    $payload = New-Ex520vTrialPayload -Firmware $Firmware
    [void](Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'rm -rf /tmp/ex520v && mkdir -p /tmp/ex520v')
    foreach ($name in @('kernel.bin', 'rootfs.bin', 'crc.txt')) { Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath (Join-Path $payload $name) -RemotePath "/tmp/ex520v/$name" -TimeoutSeconds 600 }
    $scriptPath = Join-Path (Get-Ex520vPaths).Install 'stock-install-trial.sh'
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath $scriptPath -RemotePath '/tmp/stock-install-trial.sh'
    $check = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand "chmod 700 /tmp/stock-install-trial.sh && /tmp/stock-install-trial.sh /tmp/ex520v --check" -TimeoutSeconds 180
    if ($check -notmatch 'CHECK OK') { throw 'Referans betiğinin yazmasız ön kontrolü başarılı olmadı.' }
    Write-Ex520vLog -Level INFO -Message 'RAM deneme yazma öncesi denetimler tamamlandı.'
    return [pscustomobject]@{ Ready = $true; CheckOutput = $check; Payload = $payload }
}

function Start-Ex520vRamTrialWrite {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState)
    $output = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand '/tmp/stock-install-trial.sh /tmp/ex520v' -TimeoutSeconds 900
    if (-not (Test-Ex520vRemoteCompletion -Action RamTrial -ExitCode 0 -Output $output)) { throw 'RAM deneme yazma işlemi doğrulanmış başarı işareti üretmedi.' }
    Reset-Ex520vOpenWrtKnownHost -Phase Ram
    Write-Ex520vOperationRecord -Action 'RamTrialWritten' -LiveState $LiveState -Result 'verified'
    return $output
}

function Install-Ex520vFlashTrial {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState, [Parameter(Mandatory = $true)]$Firmware, [Parameter(Mandatory = $true)][string]$BackupPath, [switch]$Execute)
    $backupValid = Test-Ex520vBackupDirectory -Path $BackupPath
    $gate = Test-Ex520vOperationAllowed -Action Flash -LiveState $LiveState -BackupComplete $backupValid -FirmwareValid ([bool]$Firmware.Valid)
    if (-not $gate.Allowed) { throw ($gate.Reasons -join ' ') }
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath $Firmware.SysupgradePath -RemotePath '/tmp/ex520v-sysupgrade.bin' -TimeoutSeconds 600
    $scriptPath = Join-Path (Get-Ex520vPaths).Install 'openwrt-trial-to-flash.sh'
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath $scriptPath -RemotePath '/tmp/openwrt-trial-to-flash.sh'
    $check = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand "chmod 700 /tmp/openwrt-trial-to-flash.sh && sysupgrade -T /tmp/ex520v-sysupgrade.bin" -TimeoutSeconds 120
    if (-not $Execute) { return [pscustomobject]@{ Ready = $true; CheckOutput = $check } }
    $output = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand '/tmp/openwrt-trial-to-flash.sh /tmp/ex520v-sysupgrade.bin' -TimeoutSeconds 900
    if (-not (Test-Ex520vRemoteCompletion -Action Flash -ExitCode 0 -Output $output)) { throw 'Flash yazma işlemi doğrulanmış başarı işareti üretmedi.' }
    Reset-Ex520vOpenWrtKnownHost -Phase Flash
    Write-Ex520vOperationRecord -Action 'FlashTrialWritten' -LiveState $LiveState -Result 'verified'
    return $output
}

function Confirm-Ex520vOpenWrt {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState)
    $gate = Test-Ex520vOperationAllowed -Action Confirm -LiveState $LiveState
    if (-not $gate.Allowed) { throw ($gate.Reasons -join ' ') }
    $scriptPath = Join-Path (Get-Ex520vPaths).Install 'openwrt-confirm.sh'
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath $scriptPath -RemotePath '/tmp/openwrt-confirm.sh'
    $output = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'chmod 700 /tmp/openwrt-confirm.sh && /tmp/openwrt-confirm.sh' -TimeoutSeconds 120
    if (-not (Test-Ex520vRemoteCompletion -Action Confirm -ExitCode 0 -Output $output)) { throw 'Kalıcılaştırma doğrulanamadı.' }
    Write-Ex520vOperationRecord -Action 'Confirmed' -LiveState $LiveState -Result 'verified'
    return $output
}

function Return-Ex520vToStock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState, [switch]$Execute)
    $gate = Test-Ex520vOperationAllowed -Action ReturnStock -LiveState $LiveState
    if (-not $gate.Allowed) { throw ($gate.Reasons -join ' ') }
    $scriptPath = Join-Path (Get-Ex520vPaths).Install 'openwrt-return-stock.sh'
    Send-Ex520vFile -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -LocalPath $scriptPath -RemotePath '/tmp/openwrt-return-stock.sh'
    $check = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'chmod 700 /tmp/openwrt-return-stock.sh && /tmp/openwrt-return-stock.sh --check' -TimeoutSeconds 120
    if ($check -notmatch 'CHECK OK') { throw 'Stok slotu doğrulanamadı.' }
    if (-not $Execute) { return [pscustomobject]@{ Ready = $true; CheckOutput = $check } }
    $output = Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand '/tmp/openwrt-return-stock.sh' -TimeoutSeconds 120
    if (-not (Test-Ex520vRemoteCompletion -Action ReturnStock -ExitCode 0 -Output $output)) { throw 'Stok dönüş boot ayarları doğrulanamadı.' }
    Write-Ex520vOperationRecord -Action 'ReturnStockArmed' -LiveState $LiveState -Result 'verified'
    return $output
}

function Restart-Ex520vDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$LiveState)
    try { [void](Invoke-Ex520vSsh -Profile $LiveState.Profile -DeviceIp $LiveState.DeviceIp -RemoteCommand 'sync; reboot' -TimeoutSeconds 12) }
    catch {
        if (Test-TcpPort -Address $LiveState.DeviceIp -Port $LiveState.Profile.Port -TimeoutMs 1000) { throw }
    }
    Write-Ex520vLog -Level INFO -Message 'Yeniden başlatma komutu gönderildi; bağlantı kesildi.'
}

function Wait-Ex520vDeviceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeviceIp,
        [Parameter(Mandatory = $true)][string[]]$ExpectedSystems,
        [int]$TimeoutSeconds = 300
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $last = Get-Ex520vLiveState -DeviceIp $DeviceIp
            if ($last.System -in $ExpectedSystems) { return $last }
        }
        catch {}
    }
    $lastText = if ($last) { $last.System } else { 'bağlantı kurulamadı' }
    throw "Cihaz beklenen sistemle açılmadı. Son durum: $lastText. İşlem başarılı varsayılmadı. UART incelemesi gerekebilir."
}

function Write-Ex520vOperationRecord {
    param([Parameter(Mandatory = $true)][string]$Action, [Parameter(Mandatory = $true)]$LiveState, [Parameter(Mandatory = $true)][string]$Result)
    $paths = Get-Ex520vPaths
    $record = [ordered]@{ action = $Action; result = $Result; device_id = (Get-Ex520vDeviceId $LiveState); device_ip = $LiveState.DeviceIp; recorded_at = (Get-Date).ToString('o'); note = 'Bu kayıt güvenlik önkoşulu değildir; her işlem canlı cihazdan yeniden doğrulanır.' }
    [IO.File]::WriteAllText((Join-Path $paths.State 'last-operation.json'), (($record | ConvertTo-Json) + "`n"), $script:Utf8NoBom)
}

function Test-Ex520vLocalRequirements {
    [CmdletBinding()]
    param()
    $paths = Get-Ex520vPaths
    $items = @()
    foreach ($name in @('ssh.exe', 'scp.exe', 'ssh-keyscan.exe', 'tar.exe')) {
        $found = Get-Ex520vCommand $name
        $items += [pscustomobject]@{ Name = $name; Ok = ($null -ne $found); Detail = if ($found) { $found } else { 'Bulunamadı' } }
    }
    foreach ($name in @('stock-install-trial.sh', 'openwrt-trial-to-flash.sh', 'openwrt-confirm.sh', 'openwrt-return-stock.sh')) {
        $file = Join-Path $paths.Install $name
        $items += [pscustomobject]@{ Name = $name; Ok = (Test-Path -LiteralPath $file -PathType Leaf); Detail = $file }
    }
    $rootBat = Join-Path $paths.RootTool 'ex520-root.bat'
    $items += [pscustomobject]@{ Name = 'Root aracı'; Ok = (Test-Path -LiteralPath $rootBat -PathType Leaf); Detail = $rootBat }
    return $items
}

function Start-Ex520vRootTool {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DeviceIp)
    $paths = Get-Ex520vPaths
    $batch = Join-Path $paths.RootTool 'ex520-root.bat'
    if (-not (Test-Path -LiteralPath $batch)) { throw 'Entegre root aracı bulunamadı.' }
    $oldHost = $env:EX520_HOST
    try {
        $env:EX520_HOST = $DeviceIp
        Write-Ex520vLog -Level INFO -Message 'Orijinal EX520v root aracı başlatıldı (çıktı gizlilik nedeniyle ana günlüğe alınmaz).'
        Push-Location $paths.RootTool
        try { & cmd.exe /d /c 'call ex520-root.bat'; $code = $LASTEXITCODE }
        finally { Pop-Location }
        if ($code -ne 0) { throw "Root aracı hata ile sonlandı (kod $code)." }
    }
    finally { $env:EX520_HOST = $oldHost }
}

Export-ModuleMember -Function @(
    'Get-Ex520vPaths', 'Initialize-Ex520vTool', 'Write-Ex520vLog', 'Test-Ex520vIPv4', 'Test-TcpPort',
    'Get-Ex520vRootProfiles', 'Get-Ex520vOpenWrtProfile', 'Test-Ex520vSshProfile', 'Invoke-Ex520vSsh',
    'Resolve-Ex520vSystemState', 'Get-Ex520vLiveState', 'Test-Ex520vFlashLayout', 'Test-Ex520vRootCompatibility',
    'Test-Ex520vRemoteCompletion', 'Test-Ex520vOperationAllowed',
    'Get-Ex520vDeviceId', 'Test-Ex520vBackupDirectory', 'Find-Ex520vBackup', 'Save-Ex520vStockBackup',
    'Get-UbiCrc32', 'Test-Ex520vFirmwareSet', 'Get-Ex520vReleaseFirmware', 'Get-Ex520vLocalFirmware',
    'New-Ex520vTrialPayload', 'Install-Ex520vRamTrial', 'Start-Ex520vRamTrialWrite', 'Install-Ex520vFlashTrial',
    'Confirm-Ex520vOpenWrt', 'Return-Ex520vToStock', 'Restart-Ex520vDevice', 'Wait-Ex520vDeviceState',
    'Test-Ex520vLocalRequirements', 'Start-Ex520vRootTool', 'Invoke-Ex520vNativeText', 'Invoke-Ex520vNativeToFile'
)
