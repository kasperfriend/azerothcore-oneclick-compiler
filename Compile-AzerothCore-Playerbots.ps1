#requires -Version 5.1
<#
.SYNOPSIS
  Builds and configures a clean AzerothCore Playerbots server on Windows 10/11 x64.
.DESCRIPTION
  - Checks/installs Git, CMake, VS 2022 C++ Build Tools, OpenSSL and Boost.
  - Clones CI-tested Playerbot/core revisions and compiles all extraction tools.
  - Installs a private, portable MySQL 8.4 database (no Windows service).
  - Creates all four databases, configs and guarded launchers, then stops MySQL safely.
  - Never launches worldserver during setup; database schemas update on first data-ready start.
  Client data is intentionally not downloaded; extraction instructions are printed at completion.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [ValidateRange(1024,65535)][int]$DatabasePort = 3307,
    [switch]$ForceRebuild
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Revisions below had successful Windows CI runs on 2026-08-28/24 respectively.
$CoreRepo = 'https://github.com/mod-playerbots/azerothcore-wotlk.git'
$CoreBranch = 'Playerbot'
$CoreCommit = '47960183bb03b83e8943eb2f0f39c16df9710c9d'
$ModuleRepo = 'https://github.com/mod-playerbots/mod-playerbots.git'
$ModuleBranch = 'master'
$ModuleCommit = '2f7d9f774987d0157c6a0d0cc08c40bec3db3945'
$BoostVersion = '1.87.0'
$BoostDirName = 'boost_1_87_0'
$BoostUrl = 'https://archives.boost.io/release/1.87.0/binaries/boost_1_87_0-msvc-14.3-64.exe'
$BoostSha256 = '7b204c1cfa1a41f771361d23a99d3b4d5d677d7b52064eb73f37ba47b2d238bb'
$MySqlVersion = '8.4.9'
$MySqlUrl = 'https://cdn.mysql.com/archives/mysql-8.4/mysql-8.4.9-winx64.zip'
$MySqlSha256 = '5795ba250e89290f7507ed3bcc6a655be373616abb58b877acdea71e1b8f4e8c'

$InstallRoot = if ($InstallRoot) { [IO.Path]::GetFullPath($InstallRoot) } else { $PSScriptRoot }
$DepsDir = Join-Path $InstallRoot 'Dependencies'
$SourceDir = Join-Path $DepsDir 'Source'
$ModuleDir = Join-Path $SourceDir 'modules\mod-playerbots'
$BuildDir = Join-Path $DepsDir 'Build'
$DownloadsDir = Join-Path $DepsDir 'Downloads'
$ServerDir = Join-Path $InstallRoot 'Server'
$DatabaseDir = Join-Path $InstallRoot 'DB'
$MySqlDir = Join-Path $DatabaseDir 'mysql'
$DataDir = Join-Path $ServerDir 'Data'
$LogDir = Join-Path $InstallRoot 'logs'
$InstallLog = Join-Path $LogDir 'install.log'

function Write-Step([string]$Text) {
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}
function Write-Log {
    param([string]$Text,[string]$Color = '')
    $line = ('{0:u} {1}' -f (Get-Date), $Text)
    $line | Out-File -FilePath $InstallLog -Encoding utf8 -Append
    # $Color is optional so every existing call keeps its previous appearance.
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run Compile-AzerothCore-Playerbots.bat; it automatically requests Administrator rights.'
    }
}
function Invoke-Native {
    param([Parameter(Mandatory=$true)][string]$FilePath,
          [string[]]$ArgumentList = @(),
          [string]$WorkingDirectory = '',
          [switch]$AllowFailure)
    Write-Log ("> {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    $old = Get-Location
    $oldErrorAction = $ErrorActionPreference
    $code = -1
    try {
        if ($WorkingDirectory) { Set-Location $WorkingDirectory }
        # Git, CMake and MSVC write normal progress to stderr. Under Windows
        # PowerShell 5.1 with ErrorActionPreference=Stop, redirecting that
        # progress through a pipeline incorrectly becomes a terminating error.
        # Continue only for the native process, then use its real exit code.
        $ErrorActionPreference = 'Continue'
        & $FilePath @ArgumentList 2>&1 | Tee-Object -FilePath $InstallLog -Append | Write-Host
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorAction
        Set-Location $old
    }
    if (($code -ne 0) -and (-not $AllowFailure)) { throw "Command failed ($code): $FilePath" }
    return $code
}
function Invoke-HttpDownloadWithProgress {
    param([string]$Uri,[string]$Destination)
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 10
    $request.UserAgent = 'Mozilla/5.0 AzerothCore-Compiler/7.0'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $response = $null
    $input = $null
    $output = $null
    try {
        $response = $request.GetResponse()
        $total = [long]$response.ContentLength
        $input = $response.GetResponseStream()
        $output = New-Object IO.FileStream($Destination,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer = New-Object byte[] (1MB)
        $received = [long]0
        $lastPercent = -5
        $lastUnknownBytes = [long]0
        while (($read = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
            $output.Write($buffer,0,$read)
            $received += $read
            if ($total -gt 0) {
                $pct = [int][Math]::Floor(($received * 100.0) / $total)
                if ($pct -ge ($lastPercent + 5)) {
                    $lastPercent = $pct
                    Write-Log ("Download progress (HTTP): {0}% ({1:N1}/{2:N1} MB)" -f $lastPercent,($received / 1048576.0),($total / 1048576.0))
                }
            } elseif (($received - $lastUnknownBytes) -ge 26214400) {
                $lastUnknownBytes = $received
                Write-Log ("Download progress (HTTP): {0:N1} MB (total size unknown)" -f ($received / 1048576.0))
            }
        }
        $output.Flush()
        if ($total -gt 0 -and $received -ne $total) { throw "Incomplete HTTP download: $received of $total bytes" }
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
    }
}
function Download-Verified {
    param([string]$Uri,[string]$Destination,[string]$Sha256 = '',[long]$MinimumBytes = 1024)
    if (Test-Path $Destination) {
        $okSize = (Get-Item $Destination).Length -ge $MinimumBytes
        $okHash = (-not $Sha256) -or ((Get-FileHash $Destination -Algorithm SHA256).Hash -eq $Sha256)
        if ($okSize -and $okHash) { Write-Log "Using cached $Destination"; return }
        Remove-Item $Destination -Force
    }

    $tmp = "$Destination.partial"
    $errors = New-Object Collections.Generic.List[string]
    foreach ($method in @('HTTP','BITS','CURL')) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Log "Downloading ($method) $Uri"
        try {
            if ($method -eq 'HTTP') {
                Invoke-HttpDownloadWithProgress $Uri $tmp
            } elseif ($method -eq 'BITS') {
                $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
                if (-not $bits) { throw 'BITS is unavailable' }
                $job = Start-BitsTransfer -Source $Uri -Destination $tmp -TransferType Download -Asynchronous -ErrorAction Stop
                $lastPercent = -5
                try {
                    while ($true) {
                        $job = Get-BitsTransfer -Id $job.Id -ErrorAction Stop
                        if ($job.BytesTotal -gt 0) {
                            $pct = [int][Math]::Floor(($job.BytesTransferred * 100.0) / $job.BytesTotal)
                            if ($pct -ge ($lastPercent + 5)) {
                                $lastPercent = $pct
                                Write-Log ("Download progress (BITS): {0}% ({1:N1}/{2:N1} MB)" -f $lastPercent,($job.BytesTransferred / 1048576.0),($job.BytesTotal / 1048576.0))
                            }
                        }
                        if ($job.JobState -eq 'Transferred') { Complete-BitsTransfer -BitsJob $job; break }
                        if ($job.JobState -in @('Error','TransientError','Cancelled')) { throw "BITS state: $($job.JobState) - $($job.ErrorDescription)" }
                        Start-Sleep -Milliseconds 500
                    }
                } catch {
                    if ($job) { Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue }
                    throw
                }
            } else {
                $curl = Get-Exe 'curl.exe' @("$env:SystemRoot\System32\curl.exe")
                if (-not $curl) { throw 'curl.exe is unavailable' }
                & $curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 30 --output $tmp $Uri
                if ($LASTEXITCODE -ne 0) { throw "curl.exe returned $LASTEXITCODE" }
            }
            if (-not (Test-Path $tmp)) { throw 'No file was created' }
            $bytes = (Get-Item $tmp).Length
            if ($bytes -lt $MinimumBytes) { throw "Downloaded only $bytes bytes (minimum $MinimumBytes)" }
            if ($Sha256) {
                $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash
                if ($actual -ne $Sha256) { throw "SHA-256 mismatch ($actual)" }
            }
            Move-Item $tmp $Destination -Force
            Write-Log "Verified download: $Destination ($bytes bytes)"
            return
        } catch {
            $errors.Add("$method`: $($_.Exception.Message)")
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    throw "All download methods failed for $Uri -- $($errors -join ' | ')"
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
function Get-Exe([string]$Name,[string[]]$Candidates = @()) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($p in $Candidates) { if (Test-Path $p) { return $p } }
    return $null
}
function Install-WingetPackage {
    param([string]$Id,[string]$Override = '')
    $winget = Get-Exe 'winget.exe'
    if (-not $winget) { return $false }
    $args = @('install','--id',$Id,'--exact','--source','winget','--silent','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
    if ($Override) { $args += @('--override',$Override) }
    $code = Invoke-Native $winget $args -AllowFailure
    Refresh-Path
    return ($code -eq 0)
}
function Install-Git {
    $git = Get-Exe 'git.exe' @("$env:ProgramFiles\Git\cmd\git.exe")
    if ($git) { return $git }
    Write-Step 'Downloading portable Git into Dependencies\Git'
    $root = Join-Path $DepsDir 'Git'
    $local = Join-Path $root 'cmd\git.exe'
    if (Test-Path $local) { return $local }
    $release = Invoke-RestMethod -UseBasicParsing -Headers @{'User-Agent'='AzerothCore-OneClick'} -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -match '^MinGit-.*-64-bit\.zip$' -and $_.name -notmatch 'busybox' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not locate the official portable MinGit x64 ZIP.' }
    $zip = Join-Path $DownloadsDir 'MinGit-64-bit.zip'
    Download-Verified $asset.browser_download_url $zip '' 20000000
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Expand-Archive $zip $root -Force
    if (-not (Test-Path $local)) { throw 'Portable Git extraction completed, but git.exe was not found.' }
    return $local
}
function Install-CMake {
    $cmake = Get-Exe 'cmake.exe' @("$env:ProgramFiles\CMake\bin\cmake.exe")
    if ($cmake) {
        $v = (& $cmake --version | Select-Object -First 1) -replace '.*?([0-9]+\.[0-9]+\.[0-9]+).*','$1'
        if ([version]$v -ge [version]'3.27.0') { return $cmake }
    }
    Write-Step 'Downloading portable CMake into Dependencies\CMake'
    $root = Join-Path $DepsDir 'CMake'
    $local = Join-Path $root 'bin\cmake.exe'
    if (Test-Path $local) { return $local }
    $release = Invoke-RestMethod -UseBasicParsing -Headers @{'User-Agent'='AzerothCore-OneClick'} -Uri 'https://api.github.com/repos/Kitware/CMake/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -match 'windows-x86_64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not locate the official portable CMake x64 ZIP.' }
    $zip = Join-Path $DownloadsDir 'cmake-windows-x86_64.zip'
    Download-Verified $asset.browser_download_url $zip '' 20000000
    $tmp = Join-Path $DepsDir '_cmake_extract'
    Remove-Item $tmp,$root -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Expand-Archive $zip $tmp -Force
    $expanded = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not $expanded) { throw 'Unexpected CMake ZIP layout.' }
    Move-Item $expanded.FullName $root
    Remove-Item $tmp -Recurse -Force
    if (-not (Test-Path $local)) { throw 'Portable CMake extraction completed, but cmake.exe was not found.' }
    return $local
}
function Get-VSWhere {
    $p = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $p) { return $p }
    return $null
}
function Invoke-VSWhere {
    param([string[]]$Arguments = @())
    $vswhere = Get-VSWhere
    if (-not $vswhere) { return @() }
    $oldErrorAction = $ErrorActionPreference
    $out = $null
    try {
        # vswhere writes informational text to stderr; keep ErrorActionPreference
        # relaxed so Stop does not turn that into a terminating error.
        $ErrorActionPreference = 'Continue'
        $out = & $vswhere @Arguments
        if ($LASTEXITCODE -ne 0) { return @() }
    } finally { $ErrorActionPreference = $oldErrorAction }
    if (-not $out) { return @() }
    return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
}
function Get-VSInstall {
    $result = @(Invoke-VSWhere @('-latest','-products','*','-version','[17.0,18.0)','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'))
    if ($result.Count -gt 0) { return $result[0] }
    return $null
}
function Get-VSInstancePaths {
    # Every registered VS 2022 instance, including instances that lack the C++
    # toolset and incomplete instances left behind by an earlier failed setup.
    return @(Invoke-VSWhere @('-all','-prerelease','-products','*','-version','[17.0,18.0)','-property','installationPath'))
}
function Format-FreeGB {
    param($Value)
    if ($null -eq $Value) { return 'unknown' }
    return ('{0} GB' -f $Value)
}
function Get-FreeSpaceGB {
    param([string]$Path)
    $disk = Get-LogicalDisk $Path
    if ($disk -and $disk.FreeSpace -gt 0) { return [math]::Round([double]$disk.FreeSpace / 1GB,1) }
    return $null
}
function Get-LogicalDisk {
    param([string]$Path)
    try {
        if (-not $Path) { return $null }
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        if (-not $root) { return $null }
        $deviceId = $root.TrimEnd('\').Replace("'","''")
        return Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $deviceId) -ErrorAction SilentlyContinue | Select-Object -First 1
    } catch { }
    return $null
}
function Test-InstallPathUsable {
    param([Parameter(Mandatory=$true)][string]$Path)
    # Visual Studio rejects some target directories with error 8004 ("target
    # directory failure") before it downloads anything. Detecting the cause here
    # avoids a long, opaque installation failure.
    $blockers = @()
    $warnings = @()
    $full = $Path
    try { $full = [IO.Path]::GetFullPath($Path) } catch { $blockers += ('The path could not be resolved: {0}' -f $_.Exception.Message) }

    if ($full.StartsWith('\\')) { $blockers += 'A UNC/network path cannot host a Visual Studio installation; use a local fixed drive.' }

    $disk = Get-LogicalDisk $full
    if ($disk) {
        # DriveType: 2 = removable, 3 = fixed, 4 = network, 5 = CD, 6 = RAM disk.
        if ($disk.DriveType -eq 4) { $blockers += ('Drive {0} is a network drive; Visual Studio must be installed on a local fixed drive.' -f $disk.DeviceID) }
        elseif ($disk.DriveType -eq 2) { $blockers += ('Drive {0} is removable (USB/SD); Visual Studio installation onto removable media is unreliable and often rejected.' -f $disk.DeviceID) }
        elseif ($disk.DriveType -ne 3) { $blockers += ('Drive {0} is not a fixed local disk (DriveType {1}).' -f $disk.DeviceID,$disk.DriveType) }
        if ($disk.FileSystem -and $disk.FileSystem -notin @('NTFS','ReFS')) { $blockers += ('Drive {0} uses {1}; Visual Studio requires NTFS.' -f $disk.DeviceID,$disk.FileSystem) }
        Write-Log ('Install target drive {0}: type {1}, file system {2}' -f $disk.DeviceID,$disk.DriveType,$disk.FileSystem)
    } elseif (-not $full.StartsWith('\\')) {
        $blockers += ('The drive for {0} could not be queried; it may be a substituted (subst) or otherwise unsupported volume.' -f $full)
    }

    $parent = [IO.Path]::GetDirectoryName($full)
    if ($parent -and (Test-Path $parent)) {
        try {
            $probe = Join-Path $parent ('acore-path-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::WriteAllText($probe,'ok')
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
        } catch { $blockers += ('The parent folder {0} is not writable: {1}' -f $parent,$_.Exception.Message) }
    }

    # MSVC and the Windows SDK nest deeply below the install root; the default
    # location itself is 61 characters long.
    $length = $full.Length
    if ($length -gt 120) { $blockers += ('The installation path is {0} characters long ({1}). Visual Studio fails with error 8004 on paths this deep; use a short location such as E:\ACore.' -f $length,$full) }
    elseif ($length -gt 80) { $warnings += ('The installation path is {0} characters long ({1}). Long paths can break the Visual Studio installer and the MSVC toolchain; a shorter location such as E:\ACore is safer.' -f $length,$full) }

    if ($full -match '[^\x20-\x7E]') { $warnings += ('The installation path contains non-ASCII characters ({0}), which the Visual Studio installer and MSVC do not always handle.' -f $full) }

    # Substituted drives look like fixed local disks to WMI, but the Visual
    # Studio installer rejects them with error 8004.
    $driveLetter = ''
    try { $driveLetter = [IO.Path]::GetPathRoot($full).TrimEnd('\') } catch { }
    if ($driveLetter.Length -ge 2) {
        $substLines = @()
        $oldErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $substExe = Join-Path $env:SystemRoot 'System32\subst.exe'
            if (Test-Path $substExe) { $substLines = @(& $substExe 2>$null) }
        } catch { } finally { $ErrorActionPreference = $oldErrorAction }
        foreach ($line in $substLines) {
            $text = "$line"
            if ($text -match '^\s*([A-Za-z]):\\?\s*=>') {
                if ($Matches[1].ToUpperInvariant() -eq $driveLetter.Substring(0,1).ToUpperInvariant()) {
                    $blockers += ('Drive {0} is a substituted (subst) drive: {1}. Visual Studio rejects substituted drives with error 8004; use the real path instead.' -f $driveLetter,$text.Trim())
                }
            }
        }
    }

    if (Test-Path $full) {
        $existing = @(Get-ChildItem $full -Force -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) { $warnings += ('{0} already exists and contains {1} item(s) from an earlier attempt; it is cleaned up automatically when no Visual Studio instance is registered there.' -f $full,$existing.Count) }
    }

    foreach ($w in $warnings) { Write-Log ('WARNING: ' + $w) -Color Yellow }
    foreach ($b in $blockers) { Write-Log ('BLOCKER: ' + $b) -Color Red }
    return [pscustomobject]@{
        Path = $full
        Usable = ($blockers.Count -eq 0)
        Blockers = $blockers
        Warnings = $warnings
    }
}
function Get-PendingRebootReasons {
    $reasons = @()
    try { if (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue) { $reasons += 'a Windows component is waiting for a restart' } } catch { }
    try { if (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue) { $reasons += 'Windows Update is waiting for a restart' } } catch { }
    try {
        $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($sessionManager -and $sessionManager.PendingFileRenameOperations) { $reasons += 'files are waiting to be renamed on restart' }
    } catch { }
    return $reasons
}
function Get-RunningVSInstallerProcesses {
    $names = @('vs_installer','vs_installershell','vs_setup_bootstrapper','vs_buildtools','vs_setup','vs_bootstrapper')
    $found = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    $installerRoot = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
    if (Test-Path $installerRoot) {
        $oldErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            # The real setup engine is setup.exe inside the installer folder and it
            # is what blocks a second installation (exit codes 1001/1618/8006).
            $found += @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($installerRoot,[StringComparison]::OrdinalIgnoreCase) })
        } finally { $ErrorActionPreference = $oldErrorAction }
    }
    return @($found | Where-Object { $_ })
}
function Wait-VSInstallerIdle {
    param([int]$TimeoutSeconds = 900,[switch]$Quiet)
    $running = @(Get-RunningVSInstallerProcesses)
    if ($running.Count -eq 0) { return $true }
    $label = (($running | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ')
    Write-Log ('Another Visual Studio installer process is running: ' + $label) -Color Yellow
    if (-not $Quiet) { Write-Log 'The Visual Studio installer cannot run twice at once; waiting for it to finish...' -Color Yellow }
    for ($i=0; $i -lt [int]($TimeoutSeconds / 3); $i++) {
        Start-Sleep -Seconds 3
        if (@(Get-RunningVSInstallerProcesses).Count -eq 0) { Write-Log 'The other Visual Studio installer finished.'; return $true }
    }
    Write-Log ('Still waiting for the other Visual Studio installer after {0} seconds: {1}' -f $TimeoutSeconds,$label) -Color Red
    return $false
}
function Test-BuildToolsReadiness {
    param([Parameter(Mandatory=$true)][string]$TargetPath)
    Write-Log 'Checking the environment before the Visual Studio installation'
    $problems = @()
    $warnings = @()

    $freeInstall = Get-FreeSpaceGB $TargetPath
    $freeCache = Get-FreeSpaceGB $env:ProgramData
    $freeTemp = Get-FreeSpaceGB $env:TEMP
    Write-Log ('Free disk space: install target {0}, installer cache drive {1}, TEMP drive {2}' -f (Format-FreeGB $freeInstall),(Format-FreeGB $freeCache),(Format-FreeGB $freeTemp))
    foreach ($check in @(
        @{ Label='the installation drive'; Free=$freeInstall },
        @{ Label='the drive holding the Visual Studio package cache'; Free=$freeCache },
        @{ Label='the drive holding %TEMP%'; Free=$freeTemp })) {
        if ($null -ne $check.Free) {
            if ($check.Free -lt 12) { $problems += ('Only {0} GB free on {1}; Build Tools 2022 with the C++ workload needs roughly 15 GB. Free up space and run the compiler again.' -f $check.Free,$check.Label) }
            elseif ($check.Free -lt 20) { $warnings += ('Only {0} GB free on {1}; the installer may run out of space. 20 GB or more is recommended.' -f $check.Free,$check.Label) }
        }
    }

    $rebootReasons = @(Get-PendingRebootReasons)
    if ($rebootReasons.Count -gt 0) { $warnings += ('Windows is waiting for a restart ({0}). The Visual Studio installer often fails with a generic exit code 1 until that restart is done.' -f ($rebootReasons -join '; ')) }

    try {
        $probeFile = Join-Path $env:TEMP ('acore-vs-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($probeFile,'ok')
        Remove-Item $probeFile -Force -ErrorAction SilentlyContinue
    } catch { $problems += ('%TEMP% ({0}) is not writable: {1}' -f $env:TEMP,$_.Exception.Message) }

    $installerService = Get-Service msiserver -ErrorAction SilentlyContinue
    if ($installerService -and $installerService.Status -ne 'Running') {
        Write-Log 'Starting the Windows Installer service (msiserver), which the Visual Studio installer requires.'
        try { Start-Service msiserver -ErrorAction Stop } catch { $warnings += ('The Windows Installer service could not be started: {0}' -f $_.Exception.Message) }
    }

    try {
        $request = [Net.HttpWebRequest]::Create('https://aka.ms/vs/17/release/vs_BuildTools.exe')
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $true
        $request.Timeout = 20000
        $request.UserAgent = 'Mozilla/5.0 AzerothCore-Compiler/7.0'
        $response = $request.GetResponse()
        $response.Close()
        Write-Log 'Connectivity to the Microsoft download endpoint is working.'
    } catch {
        # A 4xx/5xx answer still proves that outbound HTTPS works; only a transport
        # failure means the endpoint is blocked. The type test keeps StrictMode
        # from failing on exceptions that have no Response property.
        if (($_.Exception -is [Net.WebException]) -and $_.Exception.Response) {
            Write-Log 'The Microsoft download endpoint answered, so outbound HTTPS is working.'
        } else {
            $warnings += ('Microsoft download endpoints could not be reached ({0}). A proxy, firewall, DNS filter or antivirus may block the Visual Studio installer, which then fails with exit code 5003 or a connectivity error.' -f $_.Exception.Message)
        }
    }

    foreach ($w in $warnings) { Write-Log ('WARNING: ' + $w) -Color Yellow }
    foreach ($p in $problems) { Write-Log ('BLOCKER: ' + $p) -Color Red }
    if ($problems.Count -gt 0) { throw ('Visual Studio Build Tools cannot be installed on this system: ' + ($problems -join ' ')) }
}
function Get-VSExitCodeMeaning {
    param([int]$Code)
    switch ($Code) {
        0             { return 'The installer reported success, but the x64 C++ toolset is still not registered; a Windows restart or a Visual Studio repair is usually required.' }
        1             { return 'Generic failure. Microsoft documents exit code 1 as "a failure condition occurred"; the dd_*.log files copied into logs\vsinstaller name the real cause.' }
        740           { return 'Elevation required; the installer did not run with Administrator rights.' }
        1001          { return 'The Visual Studio Installer process is already running; close it or wait for it and try again.' }
        1003          { return 'Visual Studio is in use; close every Visual Studio window and try again.' }
        1602          { return 'The operation was canceled; the installer window was closed or dismissed.' }
        1603          { return 'Fatal error during installation; the collected logs name the package that failed.' }
        1618          { return 'Another Windows installation is already running; wait for it to finish and try again.' }
        1641          { return 'Completed successfully and Windows began to reboot.' }
        3010          { return 'Completed successfully, but Windows must be restarted before the toolset can be used.' }
        5003          { return 'The bootstrapper could not download the Visual Studio Installer (proxy, firewall, DNS filter or antivirus).' }
        5004          { return 'The operation was canceled.' }
        5005          { return 'Bootstrapper command-line parse error.' }
        5007          { return 'Blocked; this computer does not meet the Visual Studio requirements.' }
        8001          { return 'Arm machine check failure.' }
        8002          { return 'Background download precheck failure.' }
        8003          { return 'Out of support selectable failure.' }
        8004          { return 'Target directory failure; the installation folder is unusable (permissions, path length, network drive or leftovers from a previous attempt).' }
        8005          { return 'Verifying source payloads failure; a cached package is corrupt. Delete Dependencies\Downloads and retry.' }
        8006          { return 'Visual Studio processes are still running; close them and retry.' }
        8010          { return 'The operating system is not supported by Visual Studio 2022.' }
        -1073720687   { return 'Connectivity failure while contacting the Microsoft download servers.' }
        -1073741510   { return 'The Visual Studio Installer was terminated by the user or another process (antivirus, or the console window was closed).' }
        default       { return 'Undocumented failure code returned by the Visual Studio installer; check the collected logs.' }
    }
}
function Get-VSStopReason {
    param([int]$Code)
    # Failures that another installation strategy cannot fix. Stopping early keeps
    # the user from waiting through several long, identical failures.
    if ($Code -in @(3010,1641)) { return ('Visual Studio Build Tools installed, but Windows must be restarted before the C++ toolset can be used (exit code {0}). Restart Windows, then run Compile-AzerothCore-Playerbots.bat again; the setup continues where it stopped.' -f $Code) }
    if ($Code -in @(1602,5004)) { return ('The Visual Studio installer was canceled (exit code {0}). Complete or deliberately close any Visual Studio window that appeared, then run Compile-AzerothCore-Playerbots.bat again.' -f $Code) }
    if ($Code -eq 740) { return 'The Visual Studio installer reported that elevation is required (exit code 740). Run Compile-AzerothCore-Playerbots.bat again and approve the Administrator prompt.' }
    if ($Code -eq 5007) { return 'The Visual Studio installer blocked this installation because the computer does not meet its requirements (exit code 5007). Retrying cannot help; see the collected logs in logs\vsinstaller.' }
    if ($Code -in @(8001,8010)) { return ('The Visual Studio installer rejected this machine (exit code {0}). Retrying cannot help; Windows 10/11 x64 with current updates is required.' -f $Code) }
    if ($Code -in @(5003,-1073720687)) { return ('The Visual Studio bootstrapper could not reach the Microsoft download servers (exit code {0}). Allow aka.ms, download.visualstudio.microsoft.com and *.vsassets.io through the proxy, firewall, DNS filter and antivirus, then run Compile-AzerothCore-Playerbots.bat again.' -f $Code) }
    if ($Code -in @(1003,8006)) { return ('Visual Studio is still running (exit code {0}). Close every Visual Studio window and run Compile-AzerothCore-Playerbots.bat again.' -f $Code) }
    return $null
}
function Collect-VSInstallerLogs {
    param([datetime]$Since)
    $dest = Join-Path $LogDir 'vsinstaller'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $copied = @()
    try {
        if ($env:TEMP) {
            # dd_bootstrapper_*, dd_client_* and dd_setup_* are the logs Microsoft
            # documents for diagnosing a failed Visual Studio installation.
            $files = @(Get-ChildItem (Join-Path $env:TEMP 'dd_*.log') -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.LastWriteTime -ge $Since.AddMinutes(-5) })
            foreach ($f in $files) {
                $target = Join-Path $dest $f.Name
                try { Copy-Item $f.FullName $target -Force -ErrorAction Stop; $copied += $target } catch { }
            }
        }
    } catch { }
    return @($copied)
}
function Write-VSLogSummary {
    param([string[]]$Files = @())
    if (-not $Files -or $Files.Count -eq 0) {
        Write-Log ('No Visual Studio installer logs (dd_*.log) were found in %TEMP% ({0}) for this attempt, so the bootstrapper failed before it could write any.' -f $env:TEMP) -Color Yellow
        Write-Log 'That usually means the bootstrapper was blocked by antivirus/group policy, or it could not reach the Microsoft download servers.' -Color Yellow
        return
    }
    Write-Log ('Copied {0} Visual Studio installer log(s) into {1}: {2}' -f $Files.Count,(Join-Path $LogDir 'vsinstaller'),(($Files | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
    $pattern = '(?i)(:\s*error\s*:|\berror\b|\bfatal\b|failed to|\bfailure\b|HRESULT\s*[:=]|0x8[0-9a-fA-F]{7}|access is denied|insufficient|not enough space|unable to|could not)'
    $hits = @()
    try { $hits = @(Select-String -Path $Files -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 30) } catch { }
    if ($hits.Count -eq 0) {
        Write-Log 'The collected logs contain no explicit error line; open them in logs\vsinstaller for the full trace.'
        return
    }
    Write-Log 'Most recent error lines reported by the Visual Studio installer:' -Color Yellow
    foreach ($h in $hits) {
        $text = "$($h.Line)".Trim()
        if ($text.Length -gt 400) { $text = $text.Substring(0,400) + '...' }
        Write-Log ('  [{0}] {1}' -f (Split-Path $h.Path -Leaf),$text) -Color Yellow
    }
}
function Quote-InstallerArgument {
    param([string]$Value)
    if ($Value -match '^[A-Za-z0-9_\-\.,/:=\[\]]+$') { return $Value }
    # A trailing backslash would escape the closing quote, so it is doubled.
    $escaped = $Value.Replace('"','\"')
    if ($escaped.EndsWith('\')) { $escaped += '\' }
    return '"' + $escaped + '"'
}
function Get-VSInstallerSetupExe {
    $p = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
    if (Test-Path $p) { return $p }
    return $null
}
function Start-VSInstaller {
    param([Parameter(Mandatory=$true)][string]$FilePath,[string[]]$InstallerArguments = @())
    # Start-Process joins an argument array with spaces without re-quoting, so a
    # path containing spaces has to be quoted here. Building one pre-quoted
    # command line is the reliable form on Windows PowerShell 5.1.
    $commandLine = (($InstallerArguments | ForEach-Object { Quote-InstallerArgument $_ }) -join ' ')
    Write-Log ('> {0} {1}' -f $FilePath,$commandLine)
    $code = -1
    try {
        # Microsoft requires setup.exe to be started from a directory other than
        # the one the installer lives in, so a fixed neutral directory is used.
        $proc = Start-Process -FilePath $FilePath -ArgumentList $commandLine -WorkingDirectory $env:SystemRoot -PassThru -Wait
        try {
            if ($proc -and -not $proc.HasExited) { $proc.WaitForExit() }
            if ($proc -and $null -ne $proc.ExitCode) { $code = [int]$proc.ExitCode }
            else { Write-Log 'The installer exited but its exit code could not be read.' -Color Yellow }
        } catch { Write-Log ('Exit code could not be read: {0}' -f $_.Exception.Message) -Color Yellow }
    } catch {
        Write-Log ('Could not start {0}: {1}' -f $FilePath,$_.Exception.Message) -Color Red
        return -1
    }
    Write-Log ('Visual Studio installer exit code: {0}' -f $code)
    return $code
}
function Reset-StaleBuildToolsPath {
    param([string]$Path,[string[]]$Instances = @())
    if (-not (Test-Path $Path)) { return }
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($i in $Instances) {
        if ($i -and ([IO.Path]::GetFullPath($i).TrimEnd('\') -eq $normalized)) {
            Write-Log ('A Visual Studio instance is registered at {0}; it is modified instead of reinstalled.' -f $Path)
            return
        }
    }
    # A half-created folder with no registered instance makes the installer fail
    # with a target directory error (8004) or a generic exit code 1.
    Write-Log ('Removing the leftover folder {0} from an earlier failed attempt; no Visual Studio instance is registered there.' -f $Path)
    try { Remove-Item $Path -Recurse -Force -ErrorAction Stop }
    catch { Write-Log ('Could not remove {0}: {1}' -f $Path,$_.Exception.Message) -Color Yellow }
}
function Install-BuildTools {
    $vs = Get-VSInstall
    if ($vs) { Write-Log ('Using the existing Visual Studio C++ toolset: ' + $vs); return $vs }

    Write-Step 'Installing Visual Studio 2022 C++ Build Tools (large download)'
    $vsLocal = Join-Path $DepsDir 'VSBuildTools'
    $pathCheck = Test-InstallPathUsable $vsLocal
    if ($pathCheck.Usable) {
        Test-BuildToolsReadiness $vsLocal
    } else {
        Write-Log ('The portable location {0} cannot host Build Tools, so it will be installed into the default system location instead.' -f $vsLocal) -Color Yellow
        Test-BuildToolsReadiness "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
    }

    $bootstrap = Join-Path $DownloadsDir 'vs_buildtools.exe'
    Download-Verified 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $bootstrap '' 1000000
    if ((Get-AuthenticodeSignature $bootstrap).Status -ne 'Valid') { throw 'Visual Studio bootstrapper signature is not valid.' }

    $payload = @('--add','Microsoft.VisualStudio.Workload.VCTools','--includeRecommended')
    $common = @('--wait','--norestart')
    $instances = @(Get-VSInstancePaths)
    if ($instances.Count -gt 0) {
        Write-Log ('Visual Studio 2022 instance(s) found without the required x64 C++ toolset: ' + ($instances -join '; ')) -Color Yellow
    }

    # Ordered recovery strategies. Every attempt is verified with vswhere, so a
    # run that reports success without providing the toolset is retried.
    $attempts = New-Object Collections.Generic.List[object]
    $report = New-Object Collections.Generic.List[string]
    if ($instances.Count -gt 0) {
        $modifyTarget = @($instances | Where-Object { $_ -and ([IO.Path]::GetFullPath($_).TrimEnd('\') -eq [IO.Path]::GetFullPath($vsLocal).TrimEnd('\')) })
        if ($modifyTarget.Count -eq 0) { $modifyTarget = @($instances[0]) }
        # Modifying an existing instance must be done by the installer that owns
        # it, because the Build Tools bootstrapper cannot modify a different
        # edition. The machine-wide setup.exe handles every edition.
        $installerSetup = Get-VSInstallerSetupExe
        $modifyExe = if ($installerSetup) { $installerSetup } else { $bootstrap }
        $attempts.Add([pscustomobject]@{
            Name = ('add the C++ toolset to the existing Visual Studio installation in {0}' -f $modifyTarget[0])
            FilePath = $modifyExe
            Arguments = (@('modify','--installPath',$modifyTarget[0]) + $common + $payload)
            ResetPath = $false
            IsVSBootstrapper = $true
            UsesInstallPath = $false
        })
    }
    if ($pathCheck.Usable) {
        $attempts.Add([pscustomobject]@{
            Name = ('install Build Tools into {0} with a progress window' -f $vsLocal)
            FilePath = $bootstrap
            Arguments = (@('--passive','--installPath',$vsLocal) + $common + $payload)
            ResetPath = $true
            IsVSBootstrapper = $true
            UsesInstallPath = $true
        })
        $attempts.Add([pscustomobject]@{
            Name = ('install Build Tools into {0} without any user interface' -f $vsLocal)
            FilePath = $bootstrap
            Arguments = (@('--quiet','--installPath',$vsLocal) + $common + $payload)
            ResetPath = $true
            IsVSBootstrapper = $true
            UsesInstallPath = $true
        })
    } else {
        $report.Add(('install into {0} -> skipped, the target directory was rejected before the installer ran: {1}' -f $vsLocal,($pathCheck.Blockers -join ' ')))
    }
    $attempts.Add([pscustomobject]@{
        Name = 'install Build Tools into the default system location without the download cache'
        FilePath = $bootstrap
        Arguments = (@('--passive','--nocache') + $common + $payload)
        ResetPath = $false
        IsVSBootstrapper = $true
        UsesInstallPath = $false
    })
    $winget = Get-Exe 'winget.exe'
    if ($winget) {
        $attempts.Add([pscustomobject]@{
            Name = 'install Build Tools through winget'
            FilePath = $winget
            Arguments = @('install','--id','Microsoft.VisualStudio.2022.BuildTools','--exact','--source','winget','--silent','--accept-source-agreements','--accept-package-agreements','--override',('--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'))
            ResetPath = $false
            IsVSBootstrapper = $false
            UsesInstallPath = $false
        })
    }

    $customPathRejected = (-not $pathCheck.Usable)
    foreach ($attempt in $attempts) {
        if ($attempt.UsesInstallPath -and $customPathRejected) {
            $report.Add(('{0} -> skipped, the target directory {1} was rejected.' -f $attempt.Name,$vsLocal))
            continue
        }
        Write-Host ''
        Write-Log ('Attempt: ' + $attempt.Name) -Color Cyan
        if ($attempt.ResetPath) { Reset-StaleBuildToolsPath $vsLocal @(Get-VSInstancePaths) }
        if (-not (Wait-VSInstallerIdle 900)) {
            $report.Add(('{0} -> skipped, another Visual Studio installer was still running.' -f $attempt.Name))
            continue
        }
        $started = Get-Date
        $code = Start-VSInstaller $attempt.FilePath $attempt.Arguments
        [void](Wait-VSInstallerIdle 300 -Quiet)

        $vs = Get-VSInstall
        if ($vs) {
            Write-Log ('Visual Studio x64 C++ toolset is ready: ' + $vs)
            return $vs
        }

        $logs = @(Collect-VSInstallerLogs $started)
        if ($attempt.IsVSBootstrapper) {
            $meaning = Get-VSExitCodeMeaning $code
            Write-Log ('Attempt failed with exit code {0}: {1}' -f $code,$meaning) -Color Red
            Write-VSLogSummary $logs
            $stopReason = Get-VSStopReason $code
            if ($stopReason) { throw $stopReason }
            if ($code -eq 8004) {
                # The installer rejected the target directory itself, so every
                # remaining attempt that reuses it would fail the same way.
                $customPathRejected = $true
                Write-Log ('Target directory {0} was rejected (8004); remaining attempts that use it are skipped.' -f $vsLocal) -Color Yellow
            }
            $report.Add(('{0} -> exit code {1}: {2}' -f $attempt.Name,$code,$meaning))
        } else {
            Write-Log ('Attempt failed with exit code {0}.' -f $code) -Color Red
            $report.Add(('{0} -> exit code {1}' -f $attempt.Name,$code))
        }
    }

    Write-Log 'Every Visual Studio Build Tools installation method failed:' -Color Red
    foreach ($r in $report) { Write-Log ('  ' + $r) -Color Red }
    Write-Log 'Manual fallback: install "Build Tools for Visual Studio 2022" yourself, tick the "Desktop development with C++" workload (MSVC v143 x64/x86 plus a Windows 10/11 SDK), then run this script again; it detects the toolset and skips the installation.' -Color Yellow
    throw (@(
        ('VS Build Tools could not be installed after {0} attempt(s).' -f $attempts.Count),
        'The Microsoft installer logs were copied into logs\vsinstaller; the failing lines are printed above and stored in logs\install.log.',
        'Usual causes of exit code 1: too little free disk space, antivirus/group policy/proxy blocking download.visualstudio.com, a pending Windows restart, or a damaged existing Visual Studio installation.',
        'Usual causes of exit code 8004: a network, removable or substituted drive, a non-NTFS volume, an unwritable or non-empty target folder, or an installation path that is too long or contains non-ASCII characters.',
        'Fix the reported cause, or install the "Desktop development with C++" workload manually with Build Tools for Visual Studio 2022, then run Compile-AzerothCore-Playerbots.bat again.',
        'See README.md > Troubleshooting > "Visual Studio Build Tools installation fails" for the exit-code table.',
        'When reporting this failure, attach logs\install.log together with the logs\vsinstaller folder.'
    ) -join [Environment]::NewLine)
}
function Find-OpenSSLRoot {
    $candidates = @($env:OPENSSL_ROOT_DIR,"$env:ProgramFiles\OpenSSL-Win64","$env:ProgramFiles\OpenSSL","C:\OpenSSL-Win64") | Where-Object { $_ }
    foreach ($p in $candidates) {
        $header = Join-Path $p 'include\openssl\opensslv.h'
        if ((Test-Path $header) -and (Test-Path (Join-Path $p 'lib'))) {
            $versionText = Get-Content $header -Raw
            if ($versionText -match '(?m)^\s*#\s*define\s+OPENSSL_VERSION_MAJOR\s+3\s*$') { return $p }
        }
    }
    return $null
}
function Install-OpenSSL {
    $root = Find-OpenSSLRoot
    if ($root) { return $root }
    Write-Step 'Installing portable OpenSSL 3.5.7 LTS development files'
    # FireDaemon is listed by OpenSSL as a Windows binary distributor. The
    # archive/hash are pinned to the vendor's 2026-06 OpenSSL 3.5.7 LTS build.
    $zip = Join-Path $DownloadsDir 'openssl-3.5.7.zip'
    Download-Verified 'https://download.firedaemon.com/FireDaemon-OpenSSL/openssl-3.5.7.zip' $zip '2591459A06A6DF2D2E2B23B02A28D7C180B95C02FB4965099A708B7365A74014' 40000000
    $all = Join-Path $DepsDir 'openssl-3.5.7-all'
    $root = Join-Path $DepsDir 'openssl-3.5.7-x64'
    Remove-Item $all,$root -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $all,$root | Out-Null
    Expand-Archive $zip $all -Force
    $x64 = Get-ChildItem $all -Directory -Recurse | Where-Object { $_.Name -eq 'x64' -and (Test-Path (Join-Path $_.FullName 'include\openssl\ssl.h')) } | Select-Object -First 1
    if (-not $x64) { throw 'Unexpected FireDaemon OpenSSL ZIP layout (x64 tree not found).' }
    Copy-Item (Join-Path $x64.FullName '*') $root -Recurse -Force
    $ssl = Get-ChildItem $all -Directory -Recurse | Where-Object { $_.Name -eq 'ssl' } | Select-Object -First 1
    if ($ssl) { Copy-Item $ssl.FullName (Join-Path $root 'ssl') -Recurse -Force }
    if (-not (Test-Path (Join-Path $root 'include\openssl\ssl.h'))) { throw 'OpenSSL headers missing after extraction.' }
    return $root
}
function Install-Boost {
    $root = Join-Path $DepsDir $BoostDirName
    if ((Test-Path (Join-Path $root 'boost\version.hpp')) -and (Test-Path (Join-Path $root 'lib64-msvc-14.3'))) { return $root }
    if ($env:BOOST_ROOT -and (Test-Path (Join-Path $env:BOOST_ROOT 'boost\version.hpp')) -and (Test-Path (Join-Path $env:BOOST_ROOT 'lib64-msvc-14.3'))) { return $env:BOOST_ROOT }
    Write-Step "Installing Boost $BoostVersion"
    $installer = Join-Path $DownloadsDir 'boost.exe'
    # Use Boost's own archive host. SourceForge is intentionally not used.
    # Download-Verified automatically tries IWR, BITS, and curl.exe.
    Download-Verified $BoostUrl $installer $BoostSha256 200000000
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $p = Start-Process $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',("/DIR={0}" -f $root) -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Boost installer failed: $($p.ExitCode)" }
    if (-not (Test-Path (Join-Path $root 'boost\version.hpp'))) { throw 'Boost headers missing after install.' }
    return $root
}
function Install-PortableMySQL {
    if ((Test-Path (Join-Path $MySqlDir 'bin\mysqld.exe')) -and (Test-Path (Join-Path $MySqlDir 'lib\mysqlclient.lib'))) { return }
    Write-Step "Installing portable MySQL $MySqlVersion"
    $zip = Join-Path $DownloadsDir "mysql-$MySqlVersion-winx64.zip"
    Download-Verified $MySqlUrl $zip $MySqlSha256 200000000
    $extract = Join-Path $DatabaseDir '_extract'
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Expand-Archive $zip $extract -Force
    $expanded = Get-ChildItem $extract -Directory | Select-Object -First 1
    if (-not $expanded) { throw 'Unexpected MySQL ZIP layout.' }
    Remove-Item $MySqlDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item $expanded.FullName $MySqlDir
    Remove-Item $extract -Recurse -Force
    foreach ($f in @('bin\mysqld.exe','bin\mysql.exe','include\mysql.h','lib\mysqlclient.lib','lib\libmysql.dll')) {
        if (-not (Test-Path (Join-Path $MySqlDir $f))) { throw "MySQL package is missing $f" }
    }
}
function Clone-Or-Reset {
    param([string]$Git,[string]$Repo,[string]$Branch,[string]$Commit,[string]$Directory)
    if (-not (Test-Path (Join-Path $Directory '.git'))) {
        if (Test-Path $Directory) { Remove-Item $Directory -Recurse -Force }
        Invoke-Native $Git @('clone','--branch',$Branch,'--no-tags',$Repo,$Directory)
    }
    Invoke-Native $Git @('-C',$Directory,'remote','set-url','origin',$Repo)
    Invoke-Native $Git @('-C',$Directory,'fetch','origin',$Branch,'--no-tags')
    Invoke-Native $Git @('-C',$Directory,'checkout','--force',$Commit)
    Invoke-Native $Git @('-C',$Directory,'reset','--hard',$Commit)
    if ([IO.Path]::GetFullPath($Directory).TrimEnd('\') -eq [IO.Path]::GetFullPath($SourceDir).TrimEnd('\')) {
        # Preserve manually added module repositories across recompiles.
        Invoke-Native $Git @('-C',$Directory,'clean','-ffd','-e','modules/')
    } else {
        Invoke-Native $Git @('-C',$Directory,'clean','-ffd')
    }
    $actual = (& $Git -C $Directory rev-parse HEAD).Trim()
    if ($actual -ne $Commit) { throw "Revision verification failed in $Directory" }
}
function Set-ConfigValue {
    param([string]$Path,[string]$Name,[string]$Value)
    $text = [IO.File]::ReadAllText($Path)
    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=.*$'
    $line = "$Name = $Value"
    if ([regex]::IsMatch($text,$pattern)) { $text = [regex]::Replace($text,$pattern,$line,1) }
    else { $text += "`r`n$line`r`n" }
    [IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($false)))
}
function ConvertFrom-Secure([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function Read-DbPassword {
    while ($true) {
        $a = ConvertFrom-Secure (Read-Host 'Enter the private DB password (use the existing password when recompiling)' -AsSecureString)
        $b = ConvertFrom-Secure (Read-Host 'Repeat the DB password' -AsSecureString)
        if ($a -ne $b) { Write-Warning 'Passwords do not match.'; continue }
        if ($a.Length -lt 10) { Write-Warning 'Use at least 10 characters.'; continue }
        if ($a.Contains(';') -or $a.Contains('"') -or $a.Contains('\') -or $a.Contains("`r") -or $a.Contains("`n")) { Write-Warning 'For AzerothCore config compatibility, do not use semicolon, quote, backslash or line breaks.'; continue }
        return $a
    }
}
function Escape-Sql([string]$Text) { return $Text.Replace("'","''") }
function Start-PortableDatabase {
    $mysqld = Join-Path $MySqlDir 'bin\mysqld.exe'
    $mysql = Join-Path $MySqlDir 'bin\mysql.exe'
    $ini = Join-Path $DatabaseDir 'my.ini'
    $data = Join-Path $DatabaseDir 'data'
    $baseUnix = $MySqlDir.Replace('\','/')
    $dataUnix = $data.Replace('\','/')
    @"
[mysqld]
basedir=$baseUnix
datadir=$dataUnix
port=$DatabasePort
bind-address=127.0.0.1
mysqlx=0
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
max_allowed_packet=128M
log-error=$($LogDir.Replace('\','/'))/mysql-error.log

[client]
port=$DatabasePort
host=127.0.0.1
protocol=tcp
"@ | Set-Content $ini -Encoding ASCII
    if (-not (Test-Path (Join-Path $data 'mysql'))) {
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        Invoke-Native $mysqld @("--defaults-file=$ini",'--initialize-insecure','--console')
    }
    $existing = Get-CimInstance Win32_Process -Filter "Name='mysqld.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$ini*" }
    if (-not $existing) {
        $probe = New-Object Net.Sockets.TcpClient
        try {
            $asyncProbe = $probe.BeginConnect('127.0.0.1',$DatabasePort,$null,$null)
            if ($asyncProbe.AsyncWaitHandle.WaitOne(500) -and $probe.Connected) {
                $probe.EndConnect($asyncProbe)
                throw "Port $DatabasePort is already occupied by another program. Choose another -DatabasePort."
            }
        } finally { $probe.Close() }
        Start-Process $mysqld -ArgumentList "--defaults-file=`"$ini`"",'--console' -WorkingDirectory $DatabaseDir -WindowStyle Hidden | Out-Null
    }
    for ($i=0; $i -lt 60; $i++) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect('127.0.0.1',$DatabasePort,$null,$null)
            if ($async.AsyncWaitHandle.WaitOne(1000) -and $client.Connected) { $client.EndConnect($async); return }
        } catch { } finally { $client.Close() }
        Start-Sleep -Seconds 1
    }
    throw "Portable MySQL did not become ready. See $LogDir\mysql-error.log"
}
function Configure-Database([string]$Password) {
    $mysql = Join-Path $MySqlDir 'bin\mysql.exe'
    $ini = Join-Path $DatabaseDir 'my.ini'
    $escaped = Escape-Sql $Password
    $sql = @"
CREATE DATABASE IF NOT EXISTS acore_auth CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_world CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_characters CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_playerbots CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED BY '$escaped';
CREATE USER IF NOT EXISTS 'acore'@'127.0.0.1' IDENTIFIED BY '$escaped';
ALTER USER 'acore'@'localhost' IDENTIFIED BY '$escaped';
ALTER USER 'acore'@'127.0.0.1' IDENTIFIED BY '$escaped';
GRANT ALL PRIVILEGES ON acore_auth.* TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_world.* TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_characters.* TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_playerbots.* TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_auth.* TO 'acore'@'127.0.0.1';
GRANT ALL PRIVILEGES ON acore_world.* TO 'acore'@'127.0.0.1';
GRANT ALL PRIVILEGES ON acore_characters.* TO 'acore'@'127.0.0.1';
GRANT ALL PRIVILEGES ON acore_playerbots.* TO 'acore'@'127.0.0.1';
ALTER USER 'root'@'localhost' IDENTIFIED BY '$escaped';
FLUSH PRIVILEGES;
"@
    $sqlFile = Join-Path $DatabaseDir 'initialize.sql'
    [IO.File]::WriteAllText($sqlFile,$sql,(New-Object Text.UTF8Encoding($false)))
    try {
        $rootArgs = @("--defaults-file=$ini",'-u','root')
        Get-Content $sqlFile -Raw | & $mysql @rootArgs 2>$null
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $rootArgs += "--password=$Password"
            Get-Content $sqlFile -Raw | & $mysql @rootArgs
            $code = $LASTEXITCODE
        }
    } finally { Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue }
    if ($code -ne 0) { throw 'Failed to create AzerothCore databases/user. On a reinstall, enter the existing DB password.' }
}
function Stop-PortableDatabase([string]$Password) {
    Write-Step 'Stopping portable database safely'
    $admin = Join-Path $MySqlDir 'bin\mysqladmin.exe'
    $ini = Join-Path $DatabaseDir 'my.ini'
    $args = @("--defaults-file=$ini",'-u','root',"--password=$Password",'shutdown')
    $oldErrorAction = $ErrorActionPreference
    $code = -1
    try {
        $ErrorActionPreference = 'Continue'
        & $admin @args 2>$null | Out-Null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldErrorAction }
    if ($code -ne 0) { throw 'Database setup succeeded, but safe shutdown failed. Close the database process manually and inspect logs\mysql-error.log.' }
    Write-Log 'Portable database stopped cleanly.'
}
function Configure-Server([string]$Password) {
    $configs = Join-Path $ServerDir 'configs'
    foreach ($name in @('authserver.conf','worldserver.conf')) {
        $dist = Join-Path $configs "$name.dist"
        $dest = Join-Path $configs $name
        if (-not (Test-Path $dist)) { throw "Missing installed config template: $dist" }
        if (-not (Test-Path $dest)) { Copy-Item $dist $dest }
        else { Write-Log "Preserving existing config: $dest" }
    }
    # Activate config files for every detected module. Existing configs are preserved.
    Get-ChildItem $configs -Recurse -Filter '*.conf.dist' | ForEach-Object {
        $activeConfig = $_.FullName.Substring(0,$_.FullName.Length - 5)
        if (-not (Test-Path $activeConfig)) {
            Copy-Item $_.FullName $activeConfig
            Write-Log "Activated new config: $activeConfig"
        }
    }
    $moduleDist = Get-ChildItem $configs -Recurse -Filter 'playerbots.conf.dist' | Select-Object -First 1
    if (-not $moduleDist) { throw 'playerbots.conf.dist was not installed; module integration failed.' }
    $moduleConf = $moduleDist.FullName.Substring(0,$moduleDist.FullName.Length - 5)
    if (-not (Test-Path $moduleConf)) { Copy-Item $moduleDist.FullName $moduleConf }
    else { Write-Log "Preserving existing config: $moduleConf" }
    $connAuth = '"127.0.0.1;{0};acore;{1};acore_auth"' -f $DatabasePort,$Password
    $connWorld = '"127.0.0.1;{0};acore;{1};acore_world"' -f $DatabasePort,$Password
    $connChars = '"127.0.0.1;{0};acore;{1};acore_characters"' -f $DatabasePort,$Password
    $connBots = '"127.0.0.1;{0};acore;{1};acore_playerbots"' -f $DatabasePort,$Password
    $mysqlExe = '"' + (Join-Path $MySqlDir 'bin\mysql.exe').Replace('\','/') + '"'
    $dataValue = '"' + $DataDir.Replace('\','/') + '"'
    $auth = Join-Path $configs 'authserver.conf'
    $world = Join-Path $configs 'worldserver.conf'
    Set-ConfigValue $auth 'LoginDatabaseInfo' $connAuth
    Set-ConfigValue $auth 'MySQLExecutable' $mysqlExe
    Set-ConfigValue $world 'LoginDatabaseInfo' $connAuth
    Set-ConfigValue $world 'WorldDatabaseInfo' $connWorld
    Set-ConfigValue $world 'CharacterDatabaseInfo' $connChars
    Set-ConfigValue $world 'PlayerbotsDatabaseInfo' $connBots
    Set-ConfigValue $world 'MySQLExecutable' $mysqlExe
    Set-ConfigValue $world 'DataDir' $dataValue
    Set-ConfigValue $moduleConf 'PlayerbotsDatabaseInfo' $connBots
}
function Copy-RuntimeFiles([string]$OpenSSLRoot) {
    Copy-Item (Join-Path $MySqlDir 'lib\libmysql.dll') $ServerDir -Force
    $dlls = Get-ChildItem (Join-Path $OpenSSLRoot 'bin') -Filter '*.dll' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(libssl|libcrypto|legacy)' }
    foreach ($dll in $dlls) { Copy-Item $dll.FullName $ServerDir -Force }
    $legacy = Join-Path $OpenSSLRoot 'lib\ossl-modules\legacy.dll'
    if (Test-Path $legacy) { Copy-Item $legacy $ServerDir -Force }
    if (-not (Get-ChildItem $ServerDir -Filter 'libssl*.dll' -ErrorAction SilentlyContinue)) { throw 'OpenSSL runtime DLL was not found/copied.' }
    if (-not (Get-ChildItem $ServerDir -Filter 'libcrypto*.dll' -ErrorAction SilentlyContinue)) { throw 'OpenSSL crypto runtime DLL was not found/copied.' }
}
function Write-Launchers {
    $dbIni = Join-Path $DatabaseDir 'my.ini'
    $root = $InstallRoot
    @"
@echo off
setlocal
title AzerothCore Portable Database
cd /d "$DatabaseDir"
echo AzerothCore portable MySQL is starting on 127.0.0.1:$DatabasePort...
echo Keep this window open while the server is running.
echo.
"$MySqlDir\bin\mysqld.exe" --defaults-file="$dbIni" --console
echo.
echo The portable database process has stopped.
pause
"@ | Set-Content (Join-Path $root 'START-DATABASE.cmd') -Encoding ASCII
    @"
@echo off
setlocal
if not exist "$DataDir\dbc\*.dbc" (
  echo ERROR: Client DBC data is missing from Server\Data\dbc.
  echo Extract/copy WoW 3.3.5a data before starting the server.
  pause
  exit /b 1
)
if not exist "$DataDir\maps\*.map" (
  echo ERROR: Client map data is missing from Server\Data\maps.
  echo Extract/copy WoW 3.3.5a data before starting the server.
  pause
  exit /b 1
)
if not exist "$DataDir\vmaps\*.vmtree" echo WARNING: vmaps are missing; they are strongly recommended.
if not exist "$DataDir\mmaps\*.mmap" echo WARNING: mmaps are missing; Playerbots movement will be degraded.
powershell.exe -NoProfile -Command "`$c=New-Object Net.Sockets.TcpClient; try { `$c.Connect('127.0.0.1',$DatabasePort); exit 0 } catch { exit 1 } finally { `$c.Close() }" >nul 2>&1
if errorlevel 1 (
  start "AzerothCore Database" /D "$DatabaseDir" cmd.exe /D /C call ""$root\START-DATABASE.cmd""
  echo Waiting for the portable database console...
  powershell.exe -NoProfile -Command "`$ok=`$false; for(`$i=0;`$i -lt 60;`$i++){ `$c=New-Object Net.Sockets.TcpClient; try { `$c.Connect('127.0.0.1',$DatabasePort); `$ok=`$true; break } catch { Start-Sleep -Seconds 1 } finally { `$c.Close() } }; if(`$ok){exit 0}else{exit 1}" >nul 2>&1
  if errorlevel 1 (
    echo ERROR: Database was not ready after 60 seconds. Check its console and logs\mysql-error.log.
    pause
    exit /b 1
  )
)
start "AzerothCore Auth" /D "$ServerDir" "$ServerDir\authserver.exe" --config "$ServerDir\configs\authserver.conf"
echo Waiting for authserver to finish its first database update...
powershell.exe -NoProfile -Command "`$ok=`$false; for(`$i=0;`$i -lt 300;`$i++){ `$c=New-Object Net.Sockets.TcpClient; try { `$c.Connect('127.0.0.1',3724); `$ok=`$true; break } catch { Start-Sleep -Seconds 2 } finally { `$c.Close() } }; if(`$ok){exit 0}else{exit 1}" >nul 2>&1
if errorlevel 1 (
  echo ERROR: authserver was not ready after 10 minutes. Check its window and logs.
  pause
  exit /b 1
)
start "AzerothCore World" /D "$ServerDir" "$ServerDir\worldserver.exe" --config "$ServerDir\configs\worldserver.conf"
"@ | Set-Content (Join-Path $root 'START-SERVER.cmd') -Encoding ASCII
}
function Verify-Installation {
    Write-Step 'Final verification'
    $required = @(
        'Server\authserver.exe','Server\worldserver.exe','Server\mapextractor.exe',
        'Server\vmap4extractor.exe','Server\vmap4assembler.exe','Server\mmaps_generator.exe',
        'Server\configs\authserver.conf','Server\configs\worldserver.conf',
        'Server\libmysql.dll','DB\mysql\bin\mysqld.exe','START-DATABASE.cmd','START-SERVER.cmd'
    )
    foreach ($r in $required) { if (-not (Test-Path (Join-Path $InstallRoot $r))) { throw "Verification failed; missing $r" } }
    if (-not (Get-ChildItem (Join-Path $ServerDir 'configs') -Recurse -Filter 'playerbots.conf' -ErrorAction SilentlyContinue)) { throw 'Verification failed; playerbots.conf missing.' }
    $coreHash = (& $script:Git -C $SourceDir rev-parse HEAD).Trim()
    $moduleHash = (& $script:Git -C $ModuleDir rev-parse HEAD).Trim()
    if ($coreHash -ne $CoreCommit -or $moduleHash -ne $ModuleCommit) { throw 'Source revision mismatch.' }
    Write-Log "Verified core $coreHash and Playerbots $moduleHash."
    Write-Log 'Binary, config, module, runtime, database and revision checks passed.'
}

try {
    if ([Environment]::Is64BitOperatingSystem -ne $true) { throw '64-bit Windows 10/11 is required.' }
    if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Windows 10 or Windows 11 is required.' }
    Assert-Administrator

    $existingServer = (Test-Path (Join-Path $ServerDir 'worldserver.exe')) -or (Test-Path (Join-Path $ServerDir 'authserver.exe'))
    if ($existingServer) {
        Write-Host ''
        Write-Host "An existing compiled AzerothCore server was detected in: $ServerDir" -ForegroundColor Yellow
        Write-Host 'Nothing will be recompiled or changed unless you explicitly confirm.' -ForegroundColor Yellow
        $answer = Read-Host 'Recompile the existing server now? Type YES to continue [default: NO]'
        if ($answer -notmatch '(?i)^yes$') {
            Write-Host 'Recompile cancelled. The existing server and database were not changed.' -ForegroundColor Green
            exit 0
        }
        $ForceRebuild = $true
        Write-Host 'Recompile confirmed. A clean build will be performed; Server\Data and DB are preserved.' -ForegroundColor Cyan
    }

    foreach ($d in @($InstallRoot,$DepsDir,$DownloadsDir,$DatabaseDir,$DataDir,$LogDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Start-Transcript -Path (Join-Path $LogDir 'transcript.log') -Append | Out-Null
    Write-Log "Installation root: $InstallRoot"
    $script:Git = Install-Git
    $cmake = Install-CMake
    $vs = Install-BuildTools
    $openssl = Install-OpenSSL
    $boost = Install-Boost
    Install-PortableMySQL

    Write-Step 'Downloading CI-tested source revisions'
    Clone-Or-Reset $script:Git $CoreRepo $CoreBranch $CoreCommit $SourceDir
    New-Item -ItemType Directory -Force -Path (Join-Path $SourceDir 'modules') | Out-Null
    Clone-Or-Reset $script:Git $ModuleRepo $ModuleBranch $ModuleCommit $ModuleDir

    Write-Step 'Requirements and source are ready - compilation is paused'
    $modulesPath = Join-Path $SourceDir 'modules'
    Write-Host 'You can add additional AzerothCore modules now.' -ForegroundColor Yellow
    Write-Host 'Clone or place each module in its own folder under:' -ForegroundColor Yellow
    Write-Host "  $modulesPath" -ForegroundColor Green
    Write-Host 'Example: git clone https://github.com/OWNER/MODULE.git "<path-above>\mod-name"' -ForegroundColor DarkGray
    Write-Host 'Only use modules compatible with AzerothCore WotLK and the Playerbots core fork.' -ForegroundColor Yellow
    Write-Host 'Custom module folders are preserved on future recompiles.' -ForegroundColor Green
    [void](Read-Host 'When all desired modules are in that folder, press ENTER to begin compilation')

    Write-Step 'Configuring CMake'
    if ($ForceRebuild -and (Test-Path $BuildDir)) { Remove-Item $BuildDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $BuildDir,$ServerDir | Out-Null
    $cmakeArgs = @(
        '-S',$SourceDir,'-B',$BuildDir,'-G','Visual Studio 17 2022','-A','x64',
        "-DCMAKE_INSTALL_PREFIX=$($ServerDir.Replace('\','/'))",
        '-DTOOLS_BUILD=all','-DSCRIPTS=static','-DMODULES=static',
        "-DBOOST_ROOT=$($boost.Replace('\','/'))",
        "-DOPENSSL_ROOT_DIR=$($openssl.Replace('\','/'))",'-DOPENSSL_USE_STATIC_LIBS=FALSE',
        "-DMYSQL_INCLUDE_DIR=$((Join-Path $MySqlDir 'include').Replace('\','/'))",
        "-DMYSQL_LIBRARY=$((Join-Path $MySqlDir 'lib\mysqlclient.lib').Replace('\','/'))",
        "-DMYSQL_EXECUTABLE=$((Join-Path $MySqlDir 'bin\mysql.exe').Replace('\','/'))"
    )
    Invoke-Native $cmake $cmakeArgs
    Write-Step 'Compiling AzerothCore + Playerbots (this can take 5-45 minutes)'
    Invoke-Native $cmake @('--build',$BuildDir,'--config','RelWithDebInfo','--target','INSTALL','--parallel',[Environment]::ProcessorCount)
    Copy-RuntimeFiles $openssl

    Write-Step 'Configuring portable database and server'
    $script:DbPassword = Read-DbPassword
    Start-PortableDatabase
    Configure-Database $script:DbPassword
    Configure-Server $script:DbPassword
    Write-Launchers
    Verify-Installation
    Stop-PortableDatabase $script:DbPassword
    Write-Host "`nSETUP COMPLETE. The database was configured and stopped safely." -ForegroundColor Green
    Write-Host 'Do not run worldserver until client data is ready.' -ForegroundColor Yellow
    Write-Host 'Use the extractor executables in Server together with Dependencies\Source\apps\extractor\extractor.bat in your WoW 3.3.5a folder.' -ForegroundColor Yellow
    Write-Host 'Move dbc, maps, vmaps, mmaps and cameras into Server\Data, then run START-SERVER.cmd.' -ForegroundColor Yellow
    Write-Host "Full log: $InstallLog"
} catch {
    try { Write-Log ("FATAL: " + $_.Exception.Message) } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    Write-Host "Installation failed. Review $InstallLog and $LogDir\transcript.log" -ForegroundColor Red
    exit 1
} finally {
    $script:DbPassword = $null
    try { Stop-Transcript | Out-Null } catch { }
}
