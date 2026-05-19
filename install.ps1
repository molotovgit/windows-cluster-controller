<#
.SYNOPSIS
    windows-cluster-controller bootstrap. Run as Administrator on the
    controller PC. Stages the repo into a known location, optionally
    writes a starter cluster-controller.json, then invokes the
    orchestrator.

.DESCRIPTION
    Two ways to use this script:

    1. One-liner from a checkout-by-URL:
         iwr -useb https://<some-host>/install.ps1 | iex
       Reads $env:CLUSTERCTRL_REPO_ZIP (or its default GitHub release ZIP)
       to fetch the rest of the repo, extracts it into the staging dir,
       and runs the orchestrator under pwsh 7 (or the current shell when
       pwsh 7 is not present).

    2. Local checkout (preferred):
         git clone https://github.com/molotovgit/windows-cluster-controller
         cd windows-cluster-controller
         .\install.ps1 -ControllerHostname controller.lan -WriteConfig

       Skips the download; runs the orchestrator from the working tree.

.PARAMETER ControllerHostname
    Hostname the controller will identify as in its self-signed cert
    SAN list and Announcer payload. Default 'controller.lan'.

.PARAMETER WriteConfig
    Write a starter config/cluster-controller.json under the staging
    root with -ControllerHostname populated. Operator can edit further
    before re-running.

.PARAMETER DryRun
    Pass -DryRun through to the orchestrator (no mutations).

.PARAMETER NoRestart
    Pass -NoRestart through to the orchestrator.

.PARAMETER StagingRoot
    Where to extract / run from. Default
    %ProgramData%\ClusterController\staging.

.PARAMETER ZipUrl
    Override the default repo ZIP URL.
#>

[CmdletBinding()]
param(
    [string]$ControllerHostname = 'controller.lan',
    [switch]$WriteConfig,
    [switch]$DryRun,
    [switch]$NoRestart,
    [string]$StagingRoot,
    [string]$ZipUrl,
    [switch]$FromGitHub,
    [string]$GitHubOrg = 'molotovgit',
    [string]$GitHubRepo = 'windows-cluster-controller',
    [string]$GitHubBranch = 'main',
    [string]$NodeMsiUrl, [string]$NodeMsiSha256,
    [string]$Pwsh7MsiUrl, [string]$Pwsh7MsiSha256,
    [string]$MongoMsiUrl, [string]$MongoMsiSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch { $null = $_; return $false }
}

function Resolve-ZipUrl {
    param(
        [string]$Override,
        [switch]$FromGitHub,
        [string]$GitHubOrg,
        [string]$GitHubRepo,
        [string]$GitHubBranch
    )
    if ($Override) { return $Override }
    if ($env:CLUSTERCTRL_REPO_ZIP) { return "$env:CLUSTERCTRL_REPO_ZIP" }
    if ($FromGitHub) {
        return "https://github.com/$GitHubOrg/$GitHubRepo/archive/refs/heads/$GitHubBranch.zip"
    }
    return $null
}

function Confirm-StagingRootSafe {
    param([Parameter(Mandatory)][string]$Path)
    # Refuse to overwrite a non-empty dir unless it's marked .clustercontroller-staging.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $kids = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($kids.Count -eq 0) { return }
    $marker = Join-Path $Path '.clustercontroller-staging'
    if (Test-Path -LiteralPath $marker) { return }
    throw "Staging root '$Path' exists and is non-empty but lacks a '.clustercontroller-staging' marker. Refusing to overwrite. Pass -StagingRoot to a fresh path, or move the existing contents."
}

function Copy-RepoTree {
    param([Parameter(Mandatory)][string]$ScriptRoot, [Parameter(Mandatory)][string]$Destination)
    # Looks like a repo? src/ + config/ + REVIEW_PROMPT.md present?
    foreach ($needle in 'src','config','REVIEW_PROMPT.md') {
        if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot $needle))) { return $null }
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $ScriptRoot '*') -Destination $Destination -Recurse -Force
    # Drop a staging marker so re-runs find it.
    Set-Content -LiteralPath (Join-Path $Destination '.clustercontroller-staging') -Value 'staged' -Encoding utf8
    return $Destination
}

function Write-StarterConfig {
    param([Parameter(Mandatory)][string]$Path, [string]$Controller)
    $cfg = [ordered]@{
        controller = [ordered]@{
            hostname        = if ($Controller) { $Controller } else { $null }
            lan_ip          = $null
            https_port      = 443
            agent_port      = 4433
            announcer_port  = 8765
        }
        db = [ordered]@{
            mode = 'nedb'
        }
        tls = [ordered]@{
            mode = 'self-signed'
            self_signed = [ordered]@{
                cn              = if ($Controller) { $Controller } else { 'controller.lan' }
                additional_sans = @('controller','localhost')
                valid_for_days  = 825
            }
        }
        meshcentral = [ordered]@{
            lan_only                  = $true
            agents_port_same_as_https = $true
        }
        share = [ordered]@{
            name           = 'ClusterShare'
            root           = '%ProgramData%\ClusterController\share'
            vhdx_subdir    = 'vhdx'
            agents_subdir  = 'agents'
        }
        admin = [ordered]@{
            username        = 'clusteradmin'
            password_envvar = 'CLUSTERCTRL_ADMIN_PASS'
            bootstrap_file  = '%ProgramData%\ClusterController\admin-bootstrap.txt'
        }
        firewall = [ordered]@{
            profiles = @('Domain','Private')
        }
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    ($cfg | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding utf8
}

function Test-IsStorePwsh {
    # Microsoft Store version of PowerShell 7 (installed via `winget install
    # Microsoft.PowerShell` on Win11 24H2+ by default) runs inside an app
    # container that BLOCKS writes to HKLM:\Software regardless of token
    # elevation. The controller's State module needs HKLM. Detect by path:
    # the Store install lives under C:\Program Files\WindowsApps\.
    param([string]$ExePath)
    if (-not $ExePath) { return $false }
    return ($ExePath -like '*\WindowsApps\*')
}

function Resolve-PwshExe {
    # Prefer the MSI-installed pwsh under C:\Program Files\PowerShell\7\
    # because it can write to HKLM. Fall back to Get-Command (which often
    # resolves to the App Execution Alias -> Microsoft Store pwsh).
    $msiPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $msiPath) { return $msiPath }
    $c = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Install-PwshMsi {
    # Download and install the MSI version of PowerShell 7 from GitHub
    # releases. Used by install.ps1 to remediate Bug 7 (Store pwsh's app
    # container blocks HKLM writes) automatically rather than refusing.
    [CmdletBinding()]
    param([string]$Version = '7.6.1')
    $url = "https://github.com/PowerShell/PowerShell/releases/download/v$Version/PowerShell-$Version-win-x64.msi"
    $msi = Join-Path $env:TEMP ("pwsh-$Version-x64-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.msi')
    Write-Host "Downloading PowerShell $Version MSI from $url ..." -ForegroundColor Yellow
    try {
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Error "Could not download MSI: $($_.Exception.Message)"
        return $false
    }
    Write-Host "Installing $msi silently (msiexec /qn /norestart ADD_PATH=1) ..." -ForegroundColor Yellow
    $log = Join-Path $env:TEMP ("pwsh-msi-install-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
    $proc = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', '/L*v', "`"$log`"", 'ADD_PATH=1') -PassThru -Wait
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-Error "msiexec exit $($proc.ExitCode); log $log"
        return $false
    }
    return (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))
}

# ---------- main ----------

if ($env:CLUSTERCTRL_NOAUTORUN -ne '1') {

    Write-Host "===== windows-cluster-controller bootstrap =====" -ForegroundColor Cyan

    if (-not (Test-IsAdministrator)) {
        Write-Error 'install.ps1 must be run as Administrator. Right-click PowerShell and Run as Administrator, then re-run.'
        exit 2
    }

    # PowerShell version: only refuse when below 5.1.
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        Write-Error "PowerShell $($PSVersionTable.PSVersion) is too old. Install PowerShell 5.1+ (any modern Win11 has it) and retry."
        exit 2
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "Note: running under Windows PowerShell $($PSVersionTable.PSVersion); Stage 2 will install PowerShell 7." -ForegroundColor Yellow
    }

    # Staging root.
    if (-not $StagingRoot) {
        $StagingRoot = Join-Path $env:ProgramData 'ClusterController\staging'
    }
    Confirm-StagingRootSafe -Path $StagingRoot

    # Strategy:
    # - If we're already inside what looks like a repo (the script is in <repo>\install.ps1),
    #   copy that tree into the staging dir and run from there.
    # - Otherwise: download $ZipUrl, extract.
    $localRepo = Split-Path -Parent $PSCommandPath
    $copied    = Copy-RepoTree -ScriptRoot $localRepo -Destination $StagingRoot
    if (-not $copied) {
        $url = Resolve-ZipUrl -Override $ZipUrl `
                              -FromGitHub:$FromGitHub `
                              -GitHubOrg $GitHubOrg -GitHubRepo $GitHubRepo -GitHubBranch $GitHubBranch
        if (-not $url) {
            Write-Error "Not in a local repo and no -ZipUrl / `$env:CLUSTERCTRL_REPO_ZIP / -FromGitHub set. Either run install.ps1 from a checkout or supply one of those."
            exit 2
        }
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('cluster-controller-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.zip')
        Write-Host "Downloading $url -> $zip" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $StagingRoot)) { New-Item -Path $StagingRoot -ItemType Directory -Force | Out-Null }
        Expand-Archive -Path $zip -DestinationPath $StagingRoot -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        # GitHub archives extract to a single top-level dir "<repo>-<branch>/...";
        # flatten so Invoke-ClusterControllerSetup.ps1 is at <StagingRoot>\src\.
        $kids = @(Get-ChildItem -LiteralPath $StagingRoot -Directory)
        if ($kids.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $StagingRoot 'src'))) {
            Get-ChildItem -LiteralPath $kids[0].FullName -Force | Move-Item -Destination $StagingRoot -Force
            Remove-Item -LiteralPath $kids[0].FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Set-Content -LiteralPath (Join-Path $StagingRoot '.clustercontroller-staging') -Value 'staged' -Encoding utf8
        $copied = $StagingRoot
    }
    Write-Host "Staging dir: $copied" -ForegroundColor Cyan

    if ($WriteConfig) {
        $cfgPath = Join-Path $copied 'config\cluster-controller.json'
        Write-StarterConfig -Path $cfgPath -Controller $ControllerHostname
        Write-Host "Wrote starter config at $cfgPath" -ForegroundColor Cyan
    }

    $orchPath = Join-Path $copied 'src\Invoke-ClusterControllerSetup.ps1'
    if (-not (Test-Path -LiteralPath $orchPath)) {
        Write-Error "Orchestrator not found at $orchPath after staging. Re-check the repo / ZIP."
        exit 2
    }

    # Decide which interpreter to run the orchestrator under. Prefer pwsh 7.
    $pwsh = Resolve-PwshExe
    if ($pwsh -and (Test-IsStorePwsh -ExePath $pwsh)) {
        Write-Host ""
        Write-Host "WARNING: Only the Microsoft Store version of PowerShell 7 is installed." -ForegroundColor Yellow
        Write-Host "         The Store version runs inside an app container that BLOCKS writes" -ForegroundColor Yellow
        Write-Host "         to HKLM:\Software, which the State module requires." -ForegroundColor Yellow
        Write-Host "         Installing the MSI version automatically ..." -ForegroundColor Yellow
        if (Install-PwshMsi) {
            $pwsh = Resolve-PwshExe
            Write-Host "MSI install complete. Re-resolved pwsh: $pwsh" -ForegroundColor Green
        } else {
            Write-Error "Could not install MSI pwsh. Remediation: download manually from https://aka.ms/PowerShell-Release and re-run install.ps1."
            exit 5
        }
    }
    $cfgPath = Join-Path $copied 'config\cluster-controller.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { $cfgPath = Join-Path $copied 'config\cluster-controller.example.json' }

    $orchArgv = @('-File', $orchPath, '-ConfigPath', $cfgPath)
    if ($DryRun)   { $orchArgv += '-DryRun' }
    if ($NoRestart){ $orchArgv += '-NoRestart' }
    foreach ($pair in @(
        @{ Flag='-NodeMsiUrl';     Value=$NodeMsiUrl     },
        @{ Flag='-NodeMsiSha256';  Value=$NodeMsiSha256  },
        @{ Flag='-Pwsh7MsiUrl';    Value=$Pwsh7MsiUrl    },
        @{ Flag='-Pwsh7MsiSha256'; Value=$Pwsh7MsiSha256 },
        @{ Flag='-MongoMsiUrl';    Value=$MongoMsiUrl    },
        @{ Flag='-MongoMsiSha256'; Value=$MongoMsiSha256 }
    )) {
        if ($pair.Value) { $orchArgv += $pair.Flag; $orchArgv += $pair.Value }
    }

    $interpreter = if ($pwsh) { $pwsh } else { 'powershell.exe' }
    Write-Host "Launching orchestrator under $interpreter ..." -ForegroundColor Cyan
    & $interpreter -NoProfile -ExecutionPolicy Bypass @orchArgv
    exit $LASTEXITCODE
}
