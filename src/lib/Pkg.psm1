<#
.SYNOPSIS
    Package install primitives for the controller setup: SHA256-verified
    download, silent MSI/EXE install, winget wrapper, install-presence
    probe. Every external surface is behind a mockable invoker seam.

.DESCRIPTION
    Why a custom abstraction (vs just calling msiexec / winget directly)?
    The controller has multiple installs (PowerShell 7, OpenSSH, Node.js,
    optionally MongoDB) that share the same idempotency + integrity-check
    + retry concerns. Encoding those once here keeps each stage thin.

    Idempotency: every public function returns @{ Ok; AlreadyPresent;
    Source; Detail } so the caller can log "already installed -- skipping"
    without inspecting registry by hand.

    Integrity: downloads are checked against a caller-supplied SHA256 hash.
    A mismatch is a hard fail (the partial file is deleted). This is the
    REVIEW_PROMPT critical-blocker for network downloads.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- invoker seam ----------

function Get-DefaultPkgInvoker {
    @{
        # Download a URL to a path. Throws on HTTP error. No hash check here.
        Download = {
            param([string]$Url, [string]$Dest, [int]$TimeoutSec = 600)
            $dir = Split-Path -Parent $Dest
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        }
        # Compute the SHA256 hex digest of a file.
        FileHashSha256 = {
            param([string]$Path)
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
        # msiexec /i <path> /qn /norestart /L*v <log>. Returns @{ExitCode; Log}.
        RunMsi = {
            param([string]$MsiPath, [string]$ExtraArgs = '')
            $log = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'pkg-msi-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
            $argv = @('/i', "`"$MsiPath`"", '/qn', '/norestart', '/L*v', "`"$log`"")
            if ($ExtraArgs) { $argv += $ExtraArgs }
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Log = $log }
        }
        # winget install -e --id <id> --silent --accept-source-agreements --accept-package-agreements
        RunWinget = {
            param([string]$Id, [string]$Version = '')
            $argv = @('install','-e','--id', $Id, '--silent','--accept-source-agreements','--accept-package-agreements')
            if ($Version) { $argv += @('--version', $Version) }
            $p = Start-Process -FilePath 'winget.exe' -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        # Probe for an installed product by registry DisplayName regex. Returns first match's
        # @{DisplayName; DisplayVersion; UninstallString} or $null.
        GetInstalledByName = {
            param([string]$NameRegex)
            $keys = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            foreach ($k in $keys) {
                if (-not (Test-Path -LiteralPath $k)) { continue }
                $sub = Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue
                foreach ($s in $sub) {
                    $p = Get-ItemProperty -LiteralPath $s.PSPath -ErrorAction SilentlyContinue
                    if (-not $p) { continue }
                    if ($p.PSObject.Properties['DisplayName'] -and "$($p.DisplayName)" -match $NameRegex) {
                        return [pscustomobject]@{
                            DisplayName     = "$($p.DisplayName)"
                            DisplayVersion  = if ($p.PSObject.Properties['DisplayVersion'])  { "$($p.DisplayVersion)" }  else { $null }
                            UninstallString = if ($p.PSObject.Properties['UninstallString']) { "$($p.UninstallString)" } else { $null }
                        }
                    }
                }
            }
            return $null
        }
    }
}

$script:PkgInvokers = Get-DefaultPkgInvoker

function Confirm-PkgTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-PkgInvoker / Reset-PkgInvoker."
    }
}

function Set-PkgInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Download','FileHashSha256','RunMsi','RunWinget','GetInstalledByName')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-PkgTestSeamAllowed
    $script:PkgInvokers[$Name] = $ScriptBlock
}

function Reset-PkgInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-PkgTestSeamAllowed
    $script:PkgInvokers = Get-DefaultPkgInvoker
}

# ---------- public ----------

function Get-PkgDownload {
    <#
    .SYNOPSIS
        Download a file with SHA256 integrity verification. Returns
        @{Ok; Path; ActualHash; Detail}. On hash mismatch the partial file
        is deleted and Ok=$false.

    .PARAMETER Url      HTTPS URL of the artifact.
    .PARAMETER Dest     Destination file path.
    .PARAMETER Sha256   Expected SHA256 hex digest (case-insensitive).
                       Pass $null/'' to skip verification (Warn).
    .PARAMETER Force    Re-download even if Dest already exists with the
                       expected hash.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent download; ShouldProcess prompt would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [string]$Sha256,
        [switch]$Force
    )

    if (-not $Force -and (Test-Path -LiteralPath $Dest)) {
        if (-not $Sha256) {
            return [pscustomobject]@{ Ok = $true; Path = $Dest; ActualHash = $null; AlreadyPresent = $true; Detail = 'destination exists, no hash check requested' }
        }
        $h = & $script:PkgInvokers.FileHashSha256 $Dest
        if ("$h".Trim().ToUpper() -eq $Sha256.Trim().ToUpper()) {
            return [pscustomobject]@{ Ok = $true; Path = $Dest; ActualHash = $h; AlreadyPresent = $true; Detail = 'destination exists and matches hash' }
        }
    }

    try {
        & $script:PkgInvokers.Download $Url $Dest
    } catch {
        return [pscustomobject]@{ Ok = $false; Path = $Dest; ActualHash = $null; AlreadyPresent = $false; Detail = "download failed: $($_.Exception.Message)" }
    }
    if (-not (Test-Path -LiteralPath $Dest)) {
        return [pscustomobject]@{ Ok = $false; Path = $Dest; ActualHash = $null; AlreadyPresent = $false; Detail = 'download claimed success but file is absent' }
    }

    if ($Sha256) {
        $h = & $script:PkgInvokers.FileHashSha256 $Dest
        if ("$h".Trim().ToUpper() -ne $Sha256.Trim().ToUpper()) {
            Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Ok = $false; Path = $Dest; ActualHash = $h; AlreadyPresent = $false; Detail = "SHA256 mismatch: expected $Sha256, got $h. Partial file deleted." }
        }
        return [pscustomobject]@{ Ok = $true; Path = $Dest; ActualHash = $h; AlreadyPresent = $false; Detail = 'downloaded and verified' }
    }
    return [pscustomobject]@{ Ok = $true; Path = $Dest; ActualHash = $null; AlreadyPresent = $false; Detail = 'downloaded (no hash check requested)' }
}

function Install-PkgMsi {
    <#
    .SYNOPSIS Install an MSI silently with logging. Returns @{Ok; ExitCode; Log; Detail}.
    .DESCRIPTION Exit code 0 OR 3010 (reboot required) both count as Ok=$true.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='msiexec is invoked silently; ShouldProcess prompt would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MsiPath,
        [string]$ExtraArgs
    )
    if (-not (Test-Path -LiteralPath $MsiPath)) {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; Log = $null; Detail = "MSI not found at $MsiPath" }
    }
    try {
        $r = & $script:PkgInvokers.RunMsi $MsiPath $ExtraArgs
    } catch {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; Log = $null; Detail = "msiexec invocation threw: $($_.Exception.Message)" }
    }
    $okExit = ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010)
    [pscustomobject]@{
        Ok       = $okExit
        ExitCode = [int]$r.ExitCode
        Log      = "$($r.Log)"
        Detail   = if ($okExit) { 'installed' } else { "msiexec exited $($r.ExitCode); see log $($r.Log)" }
    }
}

function Install-PkgViaWinget {
    <#
    .SYNOPSIS Install a package by winget id. Returns @{Ok; ExitCode; Detail}.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='winget is invoked silently with --accept; ShouldProcess prompt would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Version
    )
    try {
        $r = & $script:PkgInvokers.RunWinget $Id $Version
    } catch {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; Detail = "winget invocation threw: $($_.Exception.Message)" }
    }
    [pscustomobject]@{
        Ok       = ($r.ExitCode -eq 0)
        ExitCode = [int]$r.ExitCode
        Detail   = if ($r.ExitCode -eq 0) { "installed via winget ($Id)" } else { "winget exited $($r.ExitCode)" }
    }
}

function Test-PkgInstalled {
    <#
    .SYNOPSIS
        Look up an installed product by DisplayName regex (via the Windows
        Uninstall registry hives). Returns @{Found; DisplayName;
        DisplayVersion; UninstallString} or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NameRegex)
    $r = & $script:PkgInvokers.GetInstalledByName $NameRegex
    if (-not $r) { return [pscustomobject]@{ Found = $false; DisplayName = $null; DisplayVersion = $null; UninstallString = $null } }
    [pscustomobject]@{
        Found           = $true
        DisplayName     = "$($r.DisplayName)"
        DisplayVersion  = if ($r.PSObject.Properties['DisplayVersion'])  { "$($r.DisplayVersion)" }  else { $null }
        UninstallString = if ($r.PSObject.Properties['UninstallString']) { "$($r.UninstallString)" } else { $null }
    }
}

Export-ModuleMember -Function `
    Get-PkgDownload, Install-PkgMsi, Install-PkgViaWinget, Test-PkgInstalled
