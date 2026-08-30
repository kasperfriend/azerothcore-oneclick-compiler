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
function Write-Log([string]$Text) {
    $line = ('{0:u} {1}' -f (Get-Date), $Text)
    $line | Out-File -FilePath $InstallLog -Encoding utf8 -Append
    Write-Host $Text
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
function Get-VSInstall {
    $vswhere = Get-VSWhere
    if (-not $vswhere) { return $null }
    $result = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -eq 0 -and $result) { return ($result | Select-Object -First 1) }
    return $null
}
function Install-BuildTools {
    $vs = Get-VSInstall
    if ($vs) { return $vs }
    Write-Step 'Installing Visual Studio 2022 C++ Build Tools (large download)'
    $vsLocal = Join-Path $DepsDir 'VSBuildTools'
    $bootstrap = Join-Path $DownloadsDir 'vs_buildtools.exe'
    Download-Verified 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $bootstrap '' 1000000
    if ((Get-AuthenticodeSignature $bootstrap).Status -ne 'Valid') { throw 'Visual Studio bootstrapper signature is not valid.' }
    $p = Start-Process $bootstrap -ArgumentList '--passive','--wait','--norestart','--installPath',"`"$vsLocal`"",'--add','Microsoft.VisualStudio.Workload.VCTools','--includeRecommended' -Wait -PassThru
    if ($p.ExitCode -notin @(0,3010)) { throw "VS Build Tools failed: $($p.ExitCode)" }
    $vs = Get-VSInstall
    if (-not $vs) { throw 'VS 2022 with the x64 C++ toolset was not detected.' }
    return $vs
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
