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
    param([string]$Override)
    if ($Override) { return $Override }
    if ($env:CLUSTERCTRL_REPO_ZIP) { return "$env:CLUSTERCTRL_REPO_ZIP" }
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

function Resolve-PwshExe {
    $c = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
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
        $url = Resolve-ZipUrl -Override $ZipUrl
        if (-not $url) {
            Write-Error "Not in a local repo and no -ZipUrl / `$env:CLUSTERCTRL_REPO_ZIP set. Either run install.ps1 from a checkout or supply -ZipUrl."
            exit 2
        }
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('cluster-controller-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.zip')
        Write-Host "Downloading $url -> $zip" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $StagingRoot)) { New-Item -Path $StagingRoot -ItemType Directory -Force | Out-Null }
        Expand-Archive -Path $zip -DestinationPath $StagingRoot -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
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
