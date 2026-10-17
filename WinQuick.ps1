<#
WinQuick - quick Windows 11 26H2 upgrade tool (Windows PowerShell 5.1 + WPF)

Downloads Microsoft's own update files straight from inside the app, checks them,
and installs them. Inspired by Tips2Fix-Windows11-Installer (MIT).

  -NoElevate   do not relaunch as administrator
  -Iso <path>  open the ISO page and check this ISO straight away
  -Preview     developer switch: render each page to a PNG in the given folder and exit
#>
param(
    [switch]$NoElevate,
    [string]$Iso,
    [string]$Preview
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$AppVersion = '1.0.0'

# ===================== Elevation =====================

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin) -and -not $NoElevate -and -not $Preview) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (@(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"')) + $(if ($Iso) { '-Iso', ('"' + $Iso + '"') }))
        exit
    } catch { }   # UAC declined: carry on, admin-only actions will explain themselves
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===================== Config and logging =====================

$RelPath = if ($env:WQ_RELEASES) { $env:WQ_RELEASES } else { Join-Path $Root 'releases.json' }   # WQ_RELEASES: developer testing
$Cfg = Get-Content -LiteralPath $RelPath -Raw | ConvertFrom-Json

$LogDir = Join-Path $Root 'Logs'
try { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; $t = Join-Path $LogDir '.w'; [IO.File]::WriteAllText($t, ''); Remove-Item $t }
catch { $LogDir = Join-Path $env:LOCALAPPDATA 'WinQuick\Logs'; New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogPath = Join-Path $LogDir ("WinQuick_{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))
Get-ChildItem -LiteralPath $LogDir -Filter 'WinQuick_*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -ErrorAction SilentlyContinue

function Write-Log([string]$m) {
    try { [IO.File]::AppendAllText($LogPath, ("[{0:HH:mm:ss}] {1}`r`n" -f (Get-Date), $m)) } catch { }
}
Write-Log "WinQuick $AppVersion started (admin: $(Test-Admin))"

# ===================== System facts =====================

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return '{0:N1} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return '{0:N0} B' -f $b
}

function Get-Sse42 {
    try {
        if (-not ('WQ.Native' -as [type])) {
            Add-Type -Namespace WQ -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetFirmwareType(ref uint t);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
        }
        return [WQ.Native]::IsProcessorFeaturePresent(38)
    } catch { return $null }
}

function Get-Firmware {
    try {
        Get-Sse42 | Out-Null
        [uint32]$t = 0
        if ([WQ.Native]::GetFirmwareType([ref]$t)) { if ($t -eq 2) { return 'UEFI' }; if ($t -eq 1) { return 'Legacy BIOS' } }
    } catch { }
    return 'Unknown'
}

$EditionMap = @{
    Core = 'Home'; CoreN = 'Home N'; CoreSingleLanguage = 'Home Single Language'; Professional = 'Pro'; ProfessionalN = 'Pro N'
    ProfessionalEducation = 'Pro Education'; ProfessionalWorkstation = 'Pro for Workstations'; Enterprise = 'Enterprise'
    EnterpriseN = 'Enterprise N'; Education = 'Education'; EducationN = 'Education N'
}

function Get-SystemInfo {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$k.CurrentBuildNumber
    $ubr = [int]$k.UBR
    if ($env:WQ_FAKE_BUILD) { $build = [int]$env:WQ_FAKE_BUILD; $ubr = [int]$env:WQ_FAKE_UBR }   # developer testing

    $friendly = switch ($build) {
        19044 { 'Windows 10 21H2' } 19045 { 'Windows 10 22H2' } 22000 { 'Windows 11 21H2' } 22621 { 'Windows 11 22H2' }
        22631 { 'Windows 11 23H2' } 26100 { 'Windows 11 24H2' } 26200 { 'Windows 11 25H2' } 26300 { 'Windows 11 26H2' }
        default { if ($build -ge 22000) { "Windows 11 (build $build)" } else { "Windows 10 (build $build)" } }
    }
    $edId = [string]$k.EditionID
    $edition = $EditionMap[$edId]; if (-not $edition) { $edition = $edId }

    $tag = 'en-US'; $langName = 'English (United States)'
    try { $ui = Get-UICulture; $tag = $ui.Name; $langName = $ui.EnglishName } catch { }

    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { 'x86' } }
    $free = -1
    try { $free = [long](Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free } catch { }

    [pscustomobject]@{
        Build = $build; Ubr = $ubr; Friendly = $friendly; EditionId = $edId; Edition = $edition
        LangTag = $tag; LangName = $langName; Arch = $arch; Free = $free
        Sse42 = (Get-Sse42); Firmware = (Get-Firmware)
        FastCapable = ($Cfg.enablement.eligibleBuilds -contains $build)
        OnTarget = ($build -ge $Cfg.target.build)
        PrereqOk = ($ubr -ge $Cfg.prerequisite.minUbr)
    }
}

$Os = Get-SystemInfo
Write-Log "System: $($Os.Friendly) $($Os.Build).$($Os.Ubr) | $($Os.Edition) | $($Os.LangTag) | $($Os.Arch) | SSE4.2=$($Os.Sse42) | $($Os.Firmware)"

# Download folder: avoid OneDrive-synced Downloads (big files + sync = corrupt downloads)
function Get-DownloadDir {
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) { $dl = [Environment]::ExpandEnvironmentVariables($v) }
    } catch { }
    $script:UserDownloads = $dl
    if ($dl -match 'OneDrive') { $dl = Join-Path $env:LOCALAPPDATA 'WinQuick' }
    $dir = Join-Path $dl 'WinQuick'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}
$DlDir = Get-DownloadDir

# ===================== Registry bypass and EFI fix =====================

$LabKey = 'HKLM:\SYSTEM\Setup\LabConfig'
$MoKey = 'HKLM:\SYSTEM\Setup\MoSetup'
$HwKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\HwReqChk'
$PchcKey = 'HKCU:\Software\Microsoft\PCHC'
$LabValues = 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck', 'BypassStorageCheck', 'BypassDiskCheck'
$StaleKeys = 'CompatMarkers', 'Shared', 'TargetVersionUpgradeExperienceIndicators' |
    ForEach-Object { "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\$_" }

function Set-Bypass {
    New-Item -Path $LabKey -Force | Out-Null
    foreach ($n in $LabValues) { Set-ItemProperty $LabKey -Name $n -Value 1 -Type DWord }
    New-Item -Path $MoKey -Force | Out-Null
    Set-ItemProperty $MoKey -Name AllowUpgradesWithUnsupportedTPMOrCPU -Value 1 -Type DWord
    # Makes the compatibility check report a pass; this is what keeps "Keep personal files and apps" available.
    New-Item -Path $HwKey -Force | Out-Null
    New-ItemProperty -Path $HwKey -Name HwReqChkVars -PropertyType MultiString -Force -Value @(
        'SQ_SecureBootCapable=TRUE', 'SQ_SecureBootEnabled=TRUE', 'SQ_TpmVersion=2', 'SQ_RamMB=8192') | Out-Null
    New-Item -Path $PchcKey -Force | Out-Null
    Set-ItemProperty $PchcKey -Name UpgradeEligibility -Value 1 -Type DWord
    foreach ($p in $StaleKeys) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }   # old failed verdicts get reused otherwise
    Write-Log 'Bypass registry values applied.'
}

function Clear-Bypass {
    foreach ($n in $LabValues) { Remove-ItemProperty -Path $LabKey -Name $n -ErrorAction SilentlyContinue }
    Remove-ItemProperty -Path $MoKey -Name AllowUpgradesWithUnsupportedTPMOrCPU -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $HwKey -Name HwReqChkVars -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $PchcKey -Name UpgradeEligibility -ErrorAction SilentlyContinue
    foreach ($p in $LabKey, $HwKey) {   # only drop keys that are now empty, other settings stay
        $k = Get-Item -Path $p -ErrorAction SilentlyContinue
        if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -Path $p -Force -ErrorAction SilentlyContinue }
    }
    Write-Log 'Bypass registry values removed.'
}

function Get-BypassState {
    $n = 0
    foreach ($v in $LabValues) { if ((Get-ItemProperty $LabKey -Name $v -ErrorAction SilentlyContinue)) { $n++ } }
    $hw = [bool](Get-ItemProperty $HwKey -Name HwReqChkVars -ErrorAction SilentlyContinue)
    if ($n -eq 0 -and -not $hw) { return 'Currently: not set' }
    return "Currently: set ($n of $($LabValues.Count) LabConfig values$(if ($hw) { ', HwReqChk' }))"
}

function Invoke-EfiFix {
    $fontsRel = 'EFI\Microsoft\Boot\Fonts'
    if ((Get-Firmware) -eq 'Legacy BIOS') { return @{ State = 'warn'; Text = 'This PC uses Legacy BIOS, so it has no EFI partition. This error does not come from there.' } }
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
    $letter = 'Y', 'Z', 'X', 'W', 'V', 'U' | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $letter) { return @{ State = 'err'; Text = 'No spare drive letter is available to mount the EFI partition.' } }
    $mounted = $false
    try {
        & "$env:SystemRoot\System32\mountvol.exe" "${letter}:" /s | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "mountvol could not mount the EFI partition (code $LASTEXITCODE)." }
        $mounted = $true
        $dir = "${letter}:\$fontsRel"
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @{ State = 'ok'; Text = 'Nothing to clear: the boot fonts folder does not exist, so fonts are not what fills the partition.' } }
        $files = @(Get-ChildItem -LiteralPath $dir -File -Force)   # files directly inside this one folder, nothing else
        $bytes = ($files | Measure-Object Length -Sum).Sum
        $del = 0
        foreach ($f in $files) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $del++ } catch { Write-Log "EFI: could not delete $($f.Name): $($_.Exception.Message)" } }
        Write-Log "EFI fix: found $($files.Count), deleted $del, freed $bytes bytes."
        if ($del -eq $files.Count) { return @{ State = 'ok'; Text = "Removed $del file(s), freed $(Format-Size $bytes). Run Windows Setup again." } }
        return @{ State = 'warn'; Text = "Removed $del of $($files.Count) files. See the log for details." }
    } catch { return @{ State = 'err'; Text = $_.Exception.Message }
    } finally { if ($mounted) { & "$env:SystemRoot\System32\mountvol.exe" "${letter}:" /d | Out-Null } }
}

# ===================== Worker (runs in a background runspace) =====================

$WorkerLib = @'
$ErrorActionPreference = 'Stop'
function WLog([string]$m) { try { [IO.File]::AppendAllText($Sync.LogPath, ("[{0:HH:mm:ss}] {1}`r`n" -f (Get-Date), $m)) } catch { } }

function SetStep([int]$i, [string]$state, [string]$note) {
    $a = @($Sync.Step); $a[$i] = $state; $Sync.Step = $a
    $b = @($Sync.StepNote); $b[$i] = $note; $Sync.StepNote = $b
}

# One attempt, resumes from the .part file if there is one.
function Get-FileOnce([string]$Url, [string]$Dest) {
    $part = $Dest + '.part'
    $have = 0L
    if (Test-Path -LiteralPath $part) { $have = (Get-Item -LiteralPath $part).Length }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'WinQuick/1.0'
    $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
    if ($have -gt 0) { $req.AddRange([long]$have) }
    try { $resp = $req.GetResponse() }
    catch [Net.WebException] {
        $r = $_.Exception.Response
        if ($r -and [int]$r.StatusCode -eq 416 -and $have -gt 0) { Move-Item -LiteralPath $part -Destination $Dest -Force; return }   # was already complete
        throw
    }
    try {
        if ([int]$resp.StatusCode -eq 206) { $total = $have + $resp.ContentLength; $mode = [IO.FileMode]::Append }
        else { $have = 0L; $total = $resp.ContentLength; $mode = [IO.FileMode]::Create }
        $Sync.Total = $total; $Sync.Done = $have
        $in = $resp.GetResponseStream()
        $out = New-Object IO.FileStream($part, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $buf = New-Object byte[] (256KB)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $lastMs = 0.0; $lastB = $have; $done = $have
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                if ($Sync.Cancel) { throw 'cancelled' }
                $out.Write($buf, 0, $n); $done += $n; $Sync.Done = $done
                $ms = $sw.Elapsed.TotalMilliseconds
                if ($ms - $lastMs -ge 500) {
                    $inst = ($done - $lastB) / (($ms - $lastMs) / 1000)
                    $Sync.Speed = if ($Sync.Speed -gt 0) { 0.7 * $Sync.Speed + 0.3 * $inst } else { $inst }
                    $lastMs = $ms; $lastB = $done
                }
            }
        } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Close() }
    if ($total -gt 0 -and (Get-Item -LiteralPath $part).Length -ne $total) { throw 'The connection closed before the download finished.' }
    Move-Item -LiteralPath $part -Destination $Dest -Force
}

function Get-FileRetry([string]$Url, [string]$Dest, [string]$Label) {
    if (Test-Path -LiteralPath $Dest) { WLog "Already downloaded: $Dest"; return }
    $Sync.Mode = 'bytes'; $Sync.Speed = 0.0
    for ($try = 1; $try -le 4; $try++) {
        $Sync.Action = if ($try -eq 1) { "Downloading $Label" } else { "Reconnecting ($try/4): $Label" }
        WLog "Download attempt $try : $Url"
        try { Get-FileOnce $Url $Dest; WLog "Downloaded $Dest"; return }
        catch {
            if ($_.Exception.Message -eq 'cancelled') { throw }
            WLog "Attempt $try failed: $($_.Exception.Message)"
            if ($try -eq 4) { throw "Download failed: $($_.Exception.Message)" }
            Start-Sleep -Seconds 2
        }
    }
}

# Microsoft puts the SHA-1 in the file name (..._<40 hex>.msu). $true / $false / $null (no fingerprint in name).
function Test-Fingerprint([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    $m = [regex]::Match($item.Name, '_([0-9a-fA-F]{40})(?:\s*\(\d+\))?\.msu$')
    if (-not $m.Success) { return $null }
    $Sync.Mode = 'bytes'; $Sync.Speed = 0.0; $Sync.Total = $item.Length; $Sync.Done = 0L
    $sha = [Security.Cryptography.SHA1]::Create()
    $fs = [IO.File]::Open($item.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        $buf = New-Object byte[] (4MB); $done = 0L
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($Sync.Cancel) { throw 'cancelled' }
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0); $done += $n; $Sync.Done = $done
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
        return (([BitConverter]::ToString($sha.Hash) -replace '-', '') -eq $m.Groups[1].Value.ToUpperInvariant())
    } finally { $fs.Dispose(); $sha.Dispose() }
}

function Install-Msu([string]$Path) {
    $Sync.Mode = 'percent'; $Sync.Total = 100; $Sync.Done = 0
    if ($env:WQ_DRYRUN -eq '1') { for ($i = 0; $i -le 100; $i += 5) { $Sync.Done = $i; Start-Sleep -Milliseconds 120 }; return 3010 }
    $psi = New-Object Diagnostics.ProcessStartInfo("$env:SystemRoot\System32\dism.exe", "/Online /Add-Package /PackagePath:`"$Path`" /NoRestart")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $sb = New-Object Text.StringBuilder
    # DISM redraws its progress bar with carriage returns, so read character by character
    while (($c = $p.StandardOutput.Read()) -ge 0) {
        [void]$sb.Append([char]$c)
        if ($c -eq 13 -or $c -eq 10) {
            $line = $sb.ToString(); [void]$sb.Clear()
            $m = [regex]::Match($line, '(\d{1,3}(?:\.\d)?)%')
            if ($m.Success) { $Sync.Done = [double]$m.Groups[1].Value } elseif ($line.Trim()) { WLog "dism: $($line.Trim())" }
        }
    }
    $p.WaitForExit()
    WLog "DISM exit code $($p.ExitCode)"
    return $p.ExitCode
}

function Get-InstallKind([int]$code) {
    switch ($code) {
        0 { 'ok' } 3010 { 'ok' } 2359302 { 'already' }
        -2145124329 { 'notapplicable' } -2146498530 { 'notapplicable' }
        default { 'failed' }
    }
}

# Download -> verify -> install one .msu. Returns 'ok' or 'already'; throws on failure.
function Invoke-MsuStep([string]$Url, [string]$Path, [string]$Kb, [int]$DlStep, [int]$InstStep, [bool]$Download = $true) {
    if ($Download) {
        SetStep $DlStep 'active' 'Downloading'
        Get-FileRetry $Url $Path $Kb
        SetStep $DlStep 'done' 'Downloaded'
    }
    SetStep $InstStep 'active' 'Verifying'; $Sync.Action = "Checking the fingerprint of $Kb"
    $ok = Test-Fingerprint $Path
    if ($ok -eq $false) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "The $Kb download is damaged (fingerprint mismatch). It was deleted, so run again to fetch a clean copy."
    }
    WLog "Fingerprint for $Kb : $ok"
    SetStep $InstStep 'active' 'Installing'; $Sync.Action = "Installing $Kb"
    $code = Install-Msu $Path
    switch (Get-InstallKind $code) {
        'ok' { return 'ok' }
        'already' { return 'already' }
        'notapplicable' { throw "Windows says $Kb does not apply to this PC (code 0x{0:X8}). Check that the prerequisite update is installed and restart." -f $code }
        default { throw ("The installer stopped with code 0x{0:X8}. Details are in the log." -f $code) }
    }
}

function Get-IsoLink($Plan) {
    $ua = 'WinQuick/1.0'
    $sid = [guid]::NewGuid().ToString()
    try { Invoke-WebRequest -UseBasicParsing -UserAgent $ua "https://vlscppe.microsoft.com/tags?org_id=$($Plan.OrgId)&session_id=$sid" | Out-Null } catch { }
    $api = 'https://www.microsoft.com/software-download-connector/api'
    $skus = Invoke-RestMethod -UserAgent $ua "$api/getskuinformationbyproductedition?profile=$($Plan.Profile)&ProductEditionId=$($Plan.EditionId)&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$sid"
    if ($skus.Errors) { throw "Microsoft refused the language list: $($skus.Errors[0].Value)" }
    $sku = $null
    foreach ($c in $Plan.Candidates) { $sku = @($skus.Skus) | Where-Object { $_.Language -eq $c -or $_.LocalizedLanguage -eq $c } | Select-Object -First 1; if ($sku) { break } }
    if (-not $sku) { throw "No ISO language matches $($Plan.LangName)." }
    $r = Invoke-RestMethod -UserAgent $ua "$api/GetProductDownloadLinksBySku?profile=$($Plan.Profile)&ProductEditionId=undefined&SKU=$($sku.Id)&friendlyFileName=undefined&Locale=en-US&sessionID=$sid"
    if ($r.Errors) { throw "Microsoft refused the download link: $($r.Errors[0].Value)" }
    $opts = @($r.ProductDownloadOptions)
    $opt = $opts | Where-Object { $_.Uri -match $Plan.Arch } | Select-Object -First 1
    if (-not $opt) { $opt = $opts | Select-Object -First 1 }
    if (-not $opt) { throw 'Microsoft returned no download link.' }
    $name = [IO.Path]::GetFileName(([Uri]$opt.Uri).AbsolutePath)
    if ($name -notmatch '\.iso$') { $name = 'Windows11_26H2.iso' }
    return @{ Uri = $opt.Uri; FileName = $name; Language = $sku.Language }
}
'@

$FastBody = @'
try {
    $P = $Plan
    if ($P.PrereqNeeded) {
        SetStep 0 'active' 'Starting'
        $kind = Invoke-MsuStep $P.PrereqUrl $P.PrereqPath $P.PrereqKb 0 0
        SetStep 0 'done' 'Installed'
        $Sync.Result = 'restart-prereq'; return
    }
    $kind = Invoke-MsuStep $P.EkbUrl $P.EkbPath $P.EkbKb 1 2
    SetStep 2 'done' 'Installed'
    $Sync.Result = if ($kind -eq 'already') { 'already' } else { 'ok' }
} catch {
    $a = @($Sync.Step); for ($i = 0; $i -lt 3; $i++) { if ($a[$i] -eq 'active') { SetStep $i 'error' 'Failed' } }
    if ($_.Exception.Message -eq 'cancelled') { $Sync.Result = 'cancelled' } else { $Sync.Result = 'error'; $Sync.Message = $_.Exception.Message; WLog "FAILED: $($_.Exception.Message)" }
} finally { $Sync.Finished = $true }
'@

$IsoBody = @'
try {
    $P = $Plan
    $Sync.Action = 'Asking Microsoft for a download link...'; $Sync.Mode = 'bytes'
    try { $link = Get-IsoLink $P }
    catch { WLog "ISO link failed: $($_.Exception.Message)"; $Sync.Result = 'fallback'; $Sync.Message = $_.Exception.Message; return }
    $dest = Join-Path $P.Dir $link.FileName
    Get-FileRetry $link.Uri $dest "Windows 11 26H2 ISO ($($link.Language))"
    $Sync.Data = $dest; $Sync.Result = 'ok'
} catch {
    if ($_.Exception.Message -eq 'cancelled') { $Sync.Result = 'cancelled' } else { $Sync.Result = 'error'; $Sync.Message = $_.Exception.Message; WLog "FAILED: $($_.Exception.Message)" }
} finally { $Sync.Finished = $true }
'@

# ===================== Window =====================

$xaml = [IO.File]::ReadAllText((Join-Path $Root 'ui\MainWindow.xaml'))
$win = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) { $ui[$m.Groups[1].Value] = $win.FindName($m.Groups[1].Value) }

$bc = New-Object Windows.Media.BrushConverter
function Brush([string]$hex) { $bc.ConvertFromString($hex) }
$Mdl2 = New-Object Windows.Media.FontFamily('Segoe MDL2 Assets')
$SegUi = New-Object Windows.Media.FontFamily('Segoe UI')
$Col = @{ ok = '#34D399'; warn = '#FBBF24'; err = '#F87171'; info = '#9696AC'; accent = '#A78BFA' }

$ui.verText.Text = "v$AppVersion"
$ui.brandSub.Text = "Windows 11 $($Cfg.target.name)"
if (-not (Test-Admin)) {
    $ui.adminIcon.Text = [string][char]0xE7BA; $ui.adminIcon.Foreground = Brush $Col.warn
    $ui.adminText.Text = 'Not running as admin'
}

$ConfirmFrame = $null; $ConfirmResult = $false
function Show-Confirm([string]$Title, [string]$Message, [string]$Yes = 'Continue', [string]$No = 'Cancel') {
    $ui.dlgTitle.Text = $Title; $ui.dlgMsg.Text = $Message
    $ui.btnDlgYes.Content = $Yes
    if ($No) { $ui.btnDlgNo.Content = $No; $ui.btnDlgNo.Visibility = 'Visible' } else { $ui.btnDlgNo.Visibility = 'Collapsed' }
    $script:ConfirmResult = $false
    $ui.overlay.Visibility = 'Visible'
    $script:ConfirmFrame = New-Object Windows.Threading.DispatcherFrame
    [Windows.Threading.Dispatcher]::PushFrame($script:ConfirmFrame)
    $ui.overlay.Visibility = 'Collapsed'
    return $script:ConfirmResult
}
$ui.btnDlgYes.Add_Click({ $script:ConfirmResult = $true; $script:ConfirmFrame.Continue = $false })
$ui.btnDlgNo.Add_Click({ $script:ConfirmResult = $false; $script:ConfirmFrame.Continue = $false })

$Pages = @{ Home = $ui.pageHome; Fast = $ui.pageFast; Iso = $ui.pageIso; Tools = $ui.pageTools; About = $ui.pageAbout }
function Show-Page([string]$name) {
    foreach ($k in $Pages.Keys) { $Pages[$k].Visibility = if ($k -eq $name) { 'Visible' } else { 'Collapsed' } }
    $ui["nav$name"].IsChecked = $true
}
foreach ($n in 'Home', 'Fast', 'Iso', 'Tools', 'About') { $ui["nav$n"].Add_Checked({ Show-Page ($this.Name.Substring(3)) }) }

# ---------- Dashboard ----------

function Set-Tile($el, [string]$text, [string]$state) {
    $el.Text = $text
    $el.Foreground = if ($state) { Brush $Col[$state] } else { Brush '#EDEDF5' }
}

function Initialize-Dashboard {
    Set-Tile $ui.stWin $Os.Friendly ''
    Set-Tile $ui.stBuild "$($Os.Build).$($Os.Ubr)" ''
    Set-Tile $ui.stEdition $Os.Edition ''
    Set-Tile $ui.stLang $Os.LangName ''
    Set-Tile $ui.stArch $Os.Arch ''
    switch ($Os.Sse42) {
        $true { Set-Tile $ui.stSse 'Supported' 'ok' }
        $false { Set-Tile $ui.stSse 'Missing' 'err' }
        default { Set-Tile $ui.stSse 'Unknown' 'warn' }
    }
    if ($Os.Free -ge 0) { Set-Tile $ui.stSpace (Format-Size $Os.Free) $(if ($Os.Free -ge 25GB) { 'ok' } else { 'warn' }) } else { Set-Tile $ui.stSpace 'Unknown' 'warn' }
    Set-Tile $ui.stBoot $Os.Firmware ''
    if ($Os.FastCapable) { Set-Tile $ui.stPrereq $(if ($Os.PrereqOk) { "$($Cfg.prerequisite.kb) installed" } else { "$($Cfg.prerequisite.kb) missing" }) $(if ($Os.PrereqOk) { 'ok' } else { 'warn' }) }
    else { Set-Tile $ui.stPrereq 'Not needed' '' }

    if ($Os.Sse42 -eq $false) {
        $ui.bannerSse.Visibility = 'Visible'
        $ui.bannerSseText.Text = "This processor lacks SSE4.2. Windows 11 24H2 and newer will not boot on it, and no tool can change that. Windows 11 23H2 is the newest version this PC can run."
    }

    $t = $Cfg.target.name
    if ($Os.OnTarget) {
        $ui.homeTag.Text = 'ALL DONE'; $ui.homeHead.Text = "You're already on $t"
        $ui.homeBody.Text = 'Nothing to update. The tools page still has the registry and EFI helpers if you need them.'
        $ui.btnHomePrimary.Visibility = 'Collapsed'; $ui.btnHomeSecondary.Visibility = 'Collapsed'
    } elseif ($Os.FastCapable) {
        $ui.homeHead.Text = "Fast update to $t"
        $ui.homeBody.Text = "Your PC runs $($Os.Friendly), so $t is a tiny enablement package ($($Cfg.enablement.kb), under 200 KB). WinQuick downloads it from Microsoft right here, checks it and installs it. No 8 GB ISO."
        $ui.btnHomePrimary.Content = "Update to $t now"
    } else {
        $ui.homeHead.Text = "Upgrade to $t with the ISO"
        $ui.homeBody.Text = "$($Os.Friendly) needs a full in-place upgrade. WinQuick fetches the ISO that matches your edition and language, checks it, skips the hardware checks and starts Setup, keeping your files and apps."
        $ui.btnHomePrimary.Content = 'Get the ISO'
        $ui.btnHomeSecondary.Visibility = 'Collapsed'
    }
}

$ui.btnHomePrimary.Add_Click({
    if ($Os.FastCapable) { Show-Page 'Fast'; if (-not $script:Job) { Start-FastUpdate } } else { Show-Page 'Iso' }
})
$ui.btnHomeSecondary.Add_Click({ Show-Page 'Iso' })

# ---------- Background jobs ----------

$script:Job = $null

function Start-Worker([string]$Body, [hashtable]$Plan, [string]$Panel, [scriptblock]$OnDone) {
    $sync = [hashtable]::Synchronized(@{
        Cancel = $false; Action = ''; Done = 0L; Total = 0L; Speed = 0.0; Mode = 'bytes'; Result = ''; Message = ''; Data = ''
        Step = @('pending', 'pending', 'pending'); StepNote = @('', '', ''); Finished = $false; LogPath = $LogPath
    })
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $sync)
    $rs.SessionStateProxy.SetVariable('Plan', $Plan)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($WorkerLib + "`n" + $Body)
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Sync = $sync; Panel = $Panel; OnDone = $OnDone }
    $ui["${Panel}ProgCard"].Visibility = 'Visible'
    $ui["${Panel}Bar"].Value = 0
    $ui["${Panel}Detail"].Text = ''; $ui["${Panel}Speed"].Text = ''
    $Timer.Start()
}

function Format-Eta([double]$sec) {
    if ($sec -lt 0 -or $sec -gt 86400) { return '' }
    $ts = [TimeSpan]::FromSeconds([math]::Round($sec))
    if ($ts.TotalHours -ge 1) { return '{0}:{1:00}:{2:00} left' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds }
    return '{0:00}:{1:00} left' -f $ts.Minutes, $ts.Seconds
}

function Set-StepIcon([int]$i, [string]$state) {
    $ic = $ui["s${i}Icon"]
    switch ($state) {
        'pending' { $ic.FontFamily = $SegUi; $ic.Text = [string]($i + 1); $ic.Foreground = Brush $Col.info }
        'active' { $ic.FontFamily = $Mdl2; $ic.Text = [string][char]0xE895; $ic.Foreground = Brush $Col.accent }
        'done' { $ic.FontFamily = $Mdl2; $ic.Text = [string][char]0xE73E; $ic.Foreground = Brush $Col.ok }
        'skip' { $ic.FontFamily = $SegUi; $ic.Text = [string][char]0x2013; $ic.Foreground = Brush $Col.info }
        'error' { $ic.FontFamily = $Mdl2; $ic.Text = [string][char]0xE711; $ic.Foreground = Brush $Col.err }
    }
}

function Update-Job {
    $job = $script:Job
    if (-not $job) { return }
    $s = $job.Sync; $p = $job.Panel
    $ui["${p}Action"].Text = $s.Action
    if ($s.Mode -eq 'percent') {
        $ui["${p}Bar"].Value = [double]$s.Done
        $ui["${p}Detail"].Text = '{0:N0}%' -f $s.Done
        $ui["${p}Speed"].Text = ''
    } else {
        $pct = if ($s.Total -gt 0) { $s.Done * 100.0 / $s.Total } else { 0 }
        $ui["${p}Bar"].Value = $pct
        $ui["${p}Detail"].Text = if ($s.Total -gt 0) { "$(Format-Size $s.Done) of $(Format-Size $s.Total)  ($([int]$pct)%)" } else { '' }
        $ui["${p}Speed"].Text = if ($s.Speed -gt 0 -and $s.Total -gt $s.Done) { "$(Format-Size $s.Speed)/s  -  $(Format-Eta (($s.Total - $s.Done) / $s.Speed))" } else { '' }
    }
    if ($p -eq 'fast') {
        $st = @($s.Step); $nt = @($s.StepNote)
        for ($i = 0; $i -lt 3; $i++) {
            if ($st[$i] -ne 'pending') { Set-StepIcon $i $st[$i]; $ui["s${i}Right"].Text = $nt[$i] }
        }
    }
    if ($job.Handle.IsCompleted) {
        try { $job.PS.EndInvoke($job.Handle) | Out-Null } catch { $s.Result = 'error'; $s.Message = $_.Exception.Message }
        $job.PS.Dispose(); $job.RS.Dispose()
        $script:Job = $null
        $Timer.Stop()
        Write-Log "Job '$p' finished: $($s.Result) $($s.Message)"
        & $job.OnDone $s
    }
}

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(100)
$Timer.Add_Tick({ try { Update-Job } catch { Write-Log "Tick error: $($_.Exception.Message)" } })

function Show-Result($el, [string]$state, [string]$text) {
    $el.Text = $text; $el.Foreground = Brush $Col[$state]; $el.Visibility = 'Visible'
}

# ---------- Fast update page ----------

function Initialize-FastPage {
    $kb = $Cfg.enablement.kb; $pk = $Cfg.prerequisite.kb; $t = $Cfg.target.name
    $pkg = $Cfg.enablement.packages.($Os.Arch)
    $ui.s0Title.Text = "Prerequisite update ($pk)"
    $ui.s1Title.Text = "Download $kb ($t)"
    for ($i = 0; $i -lt 3; $i++) { Set-StepIcon $i 'pending'; $ui["s${i}Right"].Text = '' }
    if ($Os.OnTarget) { $ui.fastSub.Text = "You're already on $t."; $ui.btnFastStart.IsEnabled = $false }
    elseif (-not $Os.FastCapable) { $ui.fastSub.Text = "$($Os.Friendly) can't use the enablement package. Use the ISO upgrade instead."; $ui.btnFastStart.IsEnabled = $false }
    elseif (-not $pkg) { $ui.fastSub.Text = "No direct package is published for $($Os.Arch)."; $ui.btnFastStart.IsEnabled = $false }
    else { $ui.fastSub.Text = "$($Os.Friendly) to $t in three steps. WinQuick downloads straight from Microsoft's servers." }

    if ($Os.PrereqOk) {
        $ui.s0Detail.Text = "Already installed (build $($Os.Build).$($Os.Ubr)). Nothing to do."; Set-StepIcon 0 'skip'; $ui.s0Right.Text = 'Installed'
    } else {
        $pp = $Cfg.prerequisite.packages.($Os.Arch)
        if ($pp) { $ui.s0Detail.Text = "$pk is missing and has to go in first. It is a full cumulative update, so expect a big download and a restart."; $ui.s0Right.Text = Format-Size $pp.size }
        else { $ui.s0Detail.Text = "$pk is missing and has no direct $($Os.Arch) link. Start opens the Update Catalog instead." }
    }
    if ($pkg) { $ui.s1Detail.Text = "$($Os.Arch) package, direct from Microsoft."; $ui.s1Right.Text = Format-Size $pkg.size }
}

function Start-FastUpdate {
    if ($script:Job -or -not $ui.btnFastStart.IsEnabled) { return }
    if (-not (Test-Admin) -and $env:WQ_DRYRUN -ne '1') { Show-Confirm 'Administrator needed' 'Installing updates needs administrator rights. Close WinQuick and start it with Run.bat.' 'OK' '' | Out-Null; return }
    $kb = $Cfg.enablement.kb; $pk = $Cfg.prerequisite.kb
    $pkg = $Cfg.enablement.packages.($Os.Arch)
    $plan = @{ PrereqNeeded = (-not $Os.PrereqOk); EkbKb = $kb; PrereqKb = $pk; EkbUrl = $pkg.url; EkbPath = Join-Path $DlDir ([IO.Path]::GetFileName(([Uri]$pkg.url).AbsolutePath)) }
    if (-not $Os.PrereqOk) {
        $pp = $Cfg.prerequisite.packages.($Os.Arch)
        if (-not $pp) {
            if (Show-Confirm 'Prerequisite needed' "$pk is required first and Microsoft publishes no direct $($Os.Arch) link. Open the Update Catalog to download it?" 'Open catalog' 'Cancel') { Start-Process $Cfg.prerequisite.catalog }
            return
        }
        if (-not (Show-Confirm "Install $pk first?" "$kb needs $pk, which isn't on this PC yet. It is about $(Format-Size $pp.size). WinQuick downloads and installs it, then asks you to restart. After the restart, run the fast update again for the final step." 'Download and install' 'Cancel')) { return }
        $plan.PrereqUrl = $pp.url; $plan.PrereqPath = Join-Path $DlDir ([IO.Path]::GetFileName(([Uri]$pp.url).AbsolutePath))
    }
    Write-Log "Fast update started (prereq needed: $($plan.PrereqNeeded))"
    $ui.fastResult.Visibility = 'Collapsed'; $ui.btnFastRestart.Visibility = 'Collapsed'
    $ui.btnFastStart.Visibility = 'Collapsed'; $ui.btnFastCancel.Visibility = 'Visible'; $ui.btnFastCancel.IsEnabled = $true
    for ($i = 0; $i -lt 3; $i++) { if (-not ($i -eq 0 -and $Os.PrereqOk)) { Set-StepIcon $i 'pending'; $ui["s${i}Right"].Text = '' } }
    Start-Worker $FastBody $plan 'fast' {
        param($s)
        $ui.btnFastCancel.Visibility = 'Collapsed'; $ui.btnFastStart.Visibility = 'Visible'
        $ui.fastProgCard.Visibility = 'Collapsed'
        switch ($s.Result) {
            'ok' { Show-Result $ui.fastResult 'ok' "$($Cfg.enablement.kb) is installed. Restart your PC to finish the upgrade to $($Cfg.target.name)."; $ui.btnFastRestart.Visibility = 'Visible'; $ui.btnFastStart.IsEnabled = $false }
            'already' { Show-Result $ui.fastResult 'ok' "$($Cfg.enablement.kb) was already installed. If you haven't restarted since, do that now."; $ui.btnFastRestart.Visibility = 'Visible' }
            'restart-prereq' { Show-Result $ui.fastResult 'warn' "$($Cfg.prerequisite.kb) is installed. Restart, then come back and run the fast update again for the final step."; $ui.btnFastRestart.Visibility = 'Visible' }
            'cancelled' { Show-Result $ui.fastResult 'info' 'Cancelled. Partial downloads are kept, so starting again resumes where it stopped.' }
            default { Show-Result $ui.fastResult 'err' $s.Message }
        }
    }
}

$ui.btnFastStart.Add_Click({ Start-FastUpdate })
$ui.btnFastCancel.Add_Click({ if ($script:Job) { $script:Job.Sync.Cancel = $true; $this.IsEnabled = $false } })
$ui.btnFastFolder.Add_Click({ Start-Process explorer.exe $DlDir })
$ui.btnFastRestart.Add_Click({
    if (Show-Confirm 'Restart now?' 'Save your work first. Windows restarts in 15 seconds and finishes the update during the restart.' 'Restart' 'Not yet') {
        Write-Log 'Restart requested.'
        Start-Process shutdown.exe -ArgumentList '/r', '/t', '15', '/c', '"WinQuick: restarting to finish the Windows update"' -WindowStyle Hidden
    }
})

# ---------- ISO page ----------

$script:MountedIso = $null
$script:SetupStarted = $false
$script:IsoRoot = $null

function Get-LangCandidates([string]$tag) {
    $c = New-Object Collections.Generic.List[string]
    switch -Regex ($tag) {
        '^pt-BR' { $c.Add('Brazilian Portuguese') }
        '^fr-CA' { $c.Add('French Canadian') }
        '^es-MX' { $c.Add('Spanish (Mexico)') }
        '^zh-(CN|SG|Hans)' { $c.Add('Chinese (Simplified)') }
        '^zh-(TW|HK|MO|Hant)' { $c.Add('Chinese (Traditional)') }
        '^sr-Latn' { $c.Add('Serbian Latin') }
        '^n[bn]-' { $c.Add('Norwegian') }
    }
    try { $ci = [Globalization.CultureInfo]::GetCultureInfo($tag); $c.Add($ci.EnglishName); if ($ci.Parent -and $ci.Parent.EnglishName) { $c.Add($ci.Parent.EnglishName) } } catch { }
    return , @($c)
}

function Initialize-IsoPage {
    $ui.isoNeed.Text = "Edition:  $($Os.Edition)`nLanguage:  $($Os.LangName)`nArchitecture:  $($Os.Arch)`n`nThe official multi-edition ISO contains Home and Pro. It has to match your Windows language, or Setup won't offer to keep your files."
}

function Add-Check([string]$state, [string]$text) {
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = '0,0,0,7'
    $g = New-Object Windows.Controls.TextBlock; $g.FontFamily = $Mdl2; $g.Width = 24; $g.VerticalAlignment = 'Top'; $g.Margin = '0,2,0,0'
    $g.Text = [string][char]$(switch ($state) { 'ok' { 0xE73E } 'err' { 0xE711 } 'warn' { 0xE7BA } default { 0xE946 } })
    $g.Foreground = Brush $Col[$state]
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.MaxWidth = 640; $t.TextWrapping = 'Wrap'; $t.Foreground = Brush '#EDEDF5'
    [void]$sp.Children.Add($g); [void]$sp.Children.Add($t); [void]$ui.isoChecks.Children.Add($sp)
}

function Dismount-Iso {
    if ($script:MountedIso -and -not $script:SetupStarted) { try { Dismount-DiskImage -ImagePath $script:MountedIso | Out-Null } catch { } }
    $script:MountedIso = $null
}

function Open-IsoForCheck([string]$path) {
    Write-Log "Checking ISO: $path"
    $ui.isoCheckCard.Visibility = 'Visible'; $ui.isoChecks.Children.Clear(); $ui.btnIsoStart.IsEnabled = $false
    $ui.isoPath.Text = $path; $ui.isoSetupState.Text = ''
    Add-Check 'info' 'Mounting the ISO...'
    $win.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Render)
    $ui.isoChecks.Children.Clear()
    try {
        Dismount-Iso
        $img = Mount-DiskImage -ImagePath $path -StorageType ISO -PassThru
        $script:MountedIso = $path
        $letter = $null
        for ($i = 0; $i -lt 40 -and -not $letter; $i++) {
            $letter = ($img | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
            if (-not $letter) { Start-Sleep -Milliseconds 250 }
        }
        if (-not $letter) { throw 'The ISO mounted but got no drive letter. Wait a few seconds and try again.' }
        $root = "${letter}:\"; $script:IsoRoot = $root
        $setup = @('sources\setupprep.exe', 'setup.exe') | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $setup) { Add-Check 'err' 'This does not look like a Windows ISO: no setup program inside.'; return }
        $script:SetupExe = $setup
        Add-Check 'ok' "Mounted on ${letter}: with Windows Setup inside."

        $b = 0; $lab = ''
        $idw = Join-Path $root 'sources\idwbinfo.txt'
        if (Test-Path -LiteralPath $idw) { foreach ($l in Get-Content -LiteralPath $idw) { if ($l -match 'BuildNumber\s*=\s*(\d+)') { $b = [int]$Matches[1] }; if ($l -match 'BuildLab\s*=\s*(.+)') { $lab = $Matches[1].Trim() } } }
        if ($b -ge $Cfg.target.build) { Add-Check 'ok' "Build $b ($($Cfg.target.name) or newer)." }
        elseif ($b -gt 0) { Add-Check 'warn' "Build $b is older than $($Cfg.target.name) ($($Cfg.target.build))." }
        else { Add-Check 'info' 'Build number could not be read.' }

        $langs = @(); $ini = Join-Path $root 'sources\lang.ini'
        if (Test-Path -LiteralPath $ini) {
            $inSec = $false
            foreach ($l in Get-Content -LiteralPath $ini) {
                $t = $l.Trim()
                if ($t.StartsWith('[')) { $inSec = ($t -match 'Available UI Languages'); continue }
                if ($inSec -and $t -match '^([A-Za-z]{2,3}-[A-Za-z0-9-]+)\s*=') { $langs += $Matches[1] }
            }
        }
        if ($langs.Count -eq 0) { Add-Check 'info' 'ISO language could not be read.' }
        elseif ($langs -contains $Os.LangTag) { Add-Check 'ok' "Language matches your Windows ($($Os.LangTag))." }
        else { Add-Check 'warn' "ISO language ($($langs -join ', ')) differs from your Windows ($($Os.LangTag)). Setup will probably not offer to keep files and apps." }

        $wim = @('sources\install.wim', 'sources\install.esd') | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($wim) {
            try {
                $names = @(Get-WindowsImage -ImagePath $wim -ErrorAction Stop | ForEach-Object { [string]$_.ImageName })
                if ($names -contains "Windows 11 $($Os.Edition)") { Add-Check 'ok' "Contains your edition (Windows 11 $($Os.Edition))." }
                else { Add-Check 'warn' "Your edition (Windows 11 $($Os.Edition)) is not in this ISO. Found: $($names -join ', ')." }
            } catch { Add-Check 'info' 'Editions could not be read.' }
        }
        if ($Os.Free -ge 0) {
            if ($Os.Free -ge 25GB) { Add-Check 'ok' "$(Format-Size $Os.Free) free on the system drive." } else { Add-Check 'warn' "Only $(Format-Size $Os.Free) free on the system drive. Setup wants about 25 GB." }
        }
        $ui.btnIsoStart.IsEnabled = $true
    } catch {
        Write-Log "ISO check failed: $($_.Exception.Message)"
        $ui.isoChecks.Children.Clear(); Add-Check 'err' $_.Exception.Message
    }
}

# Fallback: Microsoft refused a direct link, so the download page is opened and
# the user's Downloads folder is watched for the finished ISO.
$script:IsoWatch = $null
function Start-IsoWatch {
    $started = Get-Date
    if ($script:IsoWatch) { $script:IsoWatch.Stop() }
    $seen = @{}
    $script:IsoWatch = New-Object Windows.Threading.DispatcherTimer
    $script:IsoWatch.Interval = [TimeSpan]::FromSeconds(2)
    $script:IsoWatch.Add_Tick({
        try {
            foreach ($f in Get-ChildItem -LiteralPath $script:UserDownloads -Filter '*.iso' -ErrorAction SilentlyContinue) {
                if ($f.LastWriteTime -lt $started) { continue }
                $key = "$($f.FullName)|$($f.Length)"
                if ($seen[$f.FullName] -eq $key) {   # same size on two ticks in a row: finished
                    $script:IsoWatch.Stop()
                    Show-Result $ui.isoResult 'ok' "Found $($f.Name) in your Downloads folder."
                    Open-IsoForCheck $f.FullName
                    return
                }
                $seen[$f.FullName] = $key
            }
        } catch { }
    }.GetNewClosure())
    $script:IsoWatch.Start()
}

$ui.btnIsoDownload.Add_Click({
    if ($script:Job) { return }
    $isoCfg = $Cfg.iso.($Os.Arch)
    if (-not $isoCfg) { Show-Result $ui.isoResult 'err' "No ISO is published for $($Os.Arch)."; return }
    $size = if ($Os.Arch -eq 'x64') { 'about 8 GB' } else { 'several GB' }
    if (-not (Show-Confirm 'Download the ISO?' "WinQuick asks Microsoft for the $($Os.LangName) Windows 11 $($Cfg.target.name) ISO ($size) and saves it to:`n$DlDir" 'Download' 'Cancel')) { return }
    $ui.isoResult.Visibility = 'Collapsed'
    $ui.btnIsoDownload.IsEnabled = $false; $ui.btnIsoBrowse.IsEnabled = $false
    $ui.btnIsoCancel.Visibility = 'Visible'; $ui.btnIsoCancel.IsEnabled = $true
    $plan = @{ Dir = $DlDir; EditionId = $isoCfg.editionId; Profile = $Cfg.iso.profile; OrgId = $Cfg.iso.orgId; Arch = $Os.Arch
               Candidates = (Get-LangCandidates $Os.LangTag); LangName = $Os.LangName }
    Start-Worker $IsoBody $plan 'iso' {
        param($s)
        $ui.btnIsoCancel.Visibility = 'Collapsed'; $ui.btnIsoDownload.IsEnabled = $true; $ui.btnIsoBrowse.IsEnabled = $true
        $ui.isoProgCard.Visibility = 'Collapsed'
        switch ($s.Result) {
            'ok' { Show-Result $ui.isoResult 'ok' "Downloaded to $($s.Data)"; Open-IsoForCheck $s.Data }
            'fallback' {
                $page = $Cfg.iso.($Os.Arch).page
                Show-Result $ui.isoResult 'warn' "Microsoft didn't hand out a direct link ($($s.Message)). The download page is open instead: pick $($Os.LangName), download, and WinQuick will pick the ISO up from your Downloads folder by itself."
                Start-Process $page; Start-IsoWatch
            }
            'cancelled' { Show-Result $ui.isoResult 'info' 'Cancelled. The partial file is kept, so downloading again resumes it.' }
            default { Show-Result $ui.isoResult 'err' $s.Message }
        }
    }
})
$ui.btnIsoCancel.Add_Click({ if ($script:Job) { $script:Job.Sync.Cancel = $true; $this.IsEnabled = $false } })
$ui.btnIsoBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Windows ISO (*.iso)|*.iso'; $dlg.Title = 'Select a Windows 11 ISO'
    if ($dlg.ShowDialog($win)) { $ui.isoResult.Visibility = 'Collapsed'; Open-IsoForCheck $dlg.FileName }
})

$ui.btnIsoStart.Add_Click({
    if (-not (Test-Admin)) { Show-Confirm 'Administrator needed' 'Setup needs administrator rights. Close WinQuick and start it with Run.bat.' 'OK' '' | Out-Null; return }
    $msg = "WinQuick will set the registry values that skip the Windows 11 hardware checks, then start Windows Setup from the mounted ISO with:`n/compat ignorewarning /dynamicupdate disable /migratedrivers all`n`nBack up your files first. You can undo the registry values on the Tools page."
    if (-not (Show-Confirm 'Start the upgrade?' $msg 'Start Setup' 'Cancel')) { return }
    try {
        Set-Bypass
        $exe = $script:SetupExe
        Write-Log "Starting Setup: $exe"
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ArgumentList '/compat', 'ignorewarning', '/dynamicupdate', 'disable', '/migratedrivers', 'all'
        $script:SetupStarted = $true
        $ui.btnIsoStart.IsEnabled = $false
        $ui.isoSetupState.Text = 'Windows Setup has started. Follow its window; WinQuick can stay open or be closed.'
    } catch { Show-Result $ui.isoResult 'err' "Could not start Setup: $($_.Exception.Message)" }
})

# ---------- Tools ----------

function Update-ToolState { $ui.bypassState.Text = Get-BypassState }

$ui.btnBypassApply.Add_Click({
    if (-not (Test-Admin)) { Show-Confirm 'Administrator needed' 'Writing to HKLM needs administrator rights. Start WinQuick with Run.bat.' 'OK' '' | Out-Null; return }
    if (Show-Confirm 'Apply the bypass?' "This writes the LabConfig, MoSetup, HwReqChk and PCHC registry values listed in the README, and clears cached 'incompatible' verdicts. It does not start Setup." 'Apply' 'Cancel') {
        try { Set-Bypass } catch { Write-Log "Bypass failed: $($_.Exception.Message)" }
        Update-ToolState
    }
})
$ui.btnBypassUndo.Add_Click({
    if (-not (Test-Admin)) { Show-Confirm 'Administrator needed' 'Writing to HKLM needs administrator rights. Start WinQuick with Run.bat.' 'OK' '' | Out-Null; return }
    if (Show-Confirm 'Remove the bypass?' 'Removes the values WinQuick wrote and restores the Windows defaults. Keys that still hold other settings are left alone.' 'Remove' 'Cancel') {
        try { Clear-Bypass } catch { Write-Log "Undo failed: $($_.Exception.Message)" }
        Update-ToolState
    }
})
$ui.btnEfiFix.Add_Click({
    if (-not (Test-Admin)) { Show-Confirm 'Administrator needed' 'Mounting the EFI partition needs administrator rights. Start WinQuick with Run.bat.' 'OK' '' | Out-Null; return }
    if (Show-Confirm 'Clear the EFI boot fonts?' 'Close Windows Setup first. WinQuick mounts the EFI System Partition on a spare drive letter, deletes the files in EFI\Microsoft\Boot\Fonts and nothing else, then unmounts it. Windows recreates what it needs.' 'Clear the fonts' 'Cancel') {
        $r = Invoke-EfiFix
        $ui.efiState.Text = $r.Text; $ui.efiState.Foreground = Brush $Col[$r.State]
    }
})

# ---------- About ----------

$ui.aboutDoes.Text = "- Reads your Windows build, edition, language, CPU features, firmware type and free disk space.`n" +
    "- Downloads Microsoft's update files from Microsoft's own servers after you click, and checks their SHA-1 fingerprint.`n" +
    "- Installs the update with DISM, or starts Windows Setup from the ISO, only after you confirm.`n" +
    "- Writes a log of everything to the Logs folder next to the tool."
$ui.aboutNever.Text = "- No telemetry, no accounts, nothing is sent anywhere except requests to Microsoft's download servers.`n" +
    "- No background services, startup entries or hidden commands.`n" +
    "- It does not get around Microsoft's anti-bot checks. If Microsoft refuses a direct ISO link, WinQuick opens the official download page instead."
$ui.btnOpenLog.Add_Click({ Start-Process notepad.exe $LogPath })
$ui.btnOpenOriginal.Add_Click({ Start-Process 'https://github.com/tips2fix/Tips2Fix-Windows11-Installer' })

# ---------- Window plumbing ----------

$win.Add_SourceInitialized({
    try {   # dark title bar (Windows 10 1903+ and 11)
        Get-Sse42 | Out-Null
        $h = (New-Object Windows.Interop.WindowInteropHelper($win)).Handle
        $v = 1;        [WQ.Native]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) | Out-Null
        $v = 0x00130E0E; [WQ.Native]::DwmSetWindowAttribute($h, 35, [ref]$v, 4) | Out-Null   # caption colour (Windows 11)
        $v = 0x00F5EDED; [WQ.Native]::DwmSetWindowAttribute($h, 36, [ref]$v, 4) | Out-Null   # caption text
    } catch { }
})

$win.Add_Closing({
    if ($script:Job) {
        if (Show-Confirm 'Stop and exit?' 'A download or install is still running. Stopping now keeps partial downloads, so you can resume later.' 'Stop and exit' 'Keep going') { $script:Job.Sync.Cancel = $true }
        else { $_.Cancel = $true; return }
    }
    Dismount-Iso
    Write-Log 'WinQuick closed.'
})

$win.Dispatcher.Add_UnhandledException({
    Write-Log "UI error: $($_.Exception.Message)`n$($_.Exception.StackTrace)"
    $_.Handled = $true
})

Initialize-Dashboard
Initialize-FastPage
Initialize-IsoPage
Update-ToolState

# ===================== Preview mode (developer) =====================

if ($Preview) {
    New-Item -ItemType Directory -Force -Path $Preview | Out-Null
    $win.Add_ContentRendered({
        $flush = { $win.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ContextIdle) }
        $shot = {
            param($name)
            & $flush; $win.UpdateLayout()
            $w = [int]$win.Content.ActualWidth; $h = [int]$win.Content.ActualHeight
            $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($win.Content)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [IO.File]::Create((Join-Path $Preview "$name.png")); $enc.Save($fs); $fs.Dispose()
        }
        $win.Content.Background = Brush '#0E0E13'
        Show-Page 'Home'; & $shot '1-dashboard'
        Show-Page 'Fast'
        $ui.fastProgCard.Visibility = 'Visible'; $ui.fastAction.Text = "Downloading $($Cfg.enablement.kb)"; $ui.fastBar.Value = 62
        $ui.fastDetail.Text = '107 KB of 173 KB  (62%)'; $ui.fastSpeed.Text = '8.4 MB/s  -  00:01 left'
        Set-StepIcon 1 'active'; $ui.s1Right.Text = 'Downloading'; Set-StepIcon 0 'skip'
        & $shot '2-fast-update'
        Show-Page 'Iso'
        $ui.isoCheckCard.Visibility = 'Visible'; $ui.isoPath.Text = 'C:\Users\you\Downloads\WinQuick\Win11_26H2_German_x64.iso'
        Add-Check 'ok' 'Mounted on E: with Windows Setup inside.'; Add-Check 'ok' 'Build 26300 (26H2 or newer).'
        Add-Check 'ok' 'Language matches your Windows (de-DE).'; Add-Check 'warn' 'Only 18.2 GB free on the system drive. Setup wants about 25 GB.'
        & $shot '3-iso-upgrade'
        Show-Page 'Tools'; & $shot '4-tools'
        $ui.dlgTitle.Text = 'Install KB5120998 first?'; $ui.dlgMsg.Text = 'KB5121794 needs KB5120998, which is not on this PC yet. It is about 4.3 GB. WinQuick downloads and installs it, then asks you to restart.'
        $ui.btnDlgYes.Content = 'Download and install'; $ui.overlay.Visibility = 'Visible'
        Show-Page 'Home'; & $shot '5-dialog'
        $win.Close()
    })
}

if ($Iso) {
    $win.Add_ContentRendered({ Show-Page 'Iso'; Open-IsoForCheck (Resolve-Path -LiteralPath $Iso).Path })
}

try { [void]$win.ShowDialog() }
catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    [Windows.MessageBox]::Show("WinQuick hit an error:`n$($_.Exception.Message)`n`nLog: $LogPath", 'WinQuick') | Out-Null
}
