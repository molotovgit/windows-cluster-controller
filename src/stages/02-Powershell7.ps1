<#
.SYNOPSIS
    Stage 2 -- Install PowerShell 7 LTS via winget (primary) or direct MSI
    download (fallback). Idempotent: skips entirely when pwsh.exe is
    already on the box at the required version.

.DESCRIPTION
    Why this matters: the rest of the orchestrator runs under pwsh 7 for
    its better cmdlet behaviour (cross-platform path handling, modern
    Pester, etc.). When the operator launches install.ps1 under Windows-
    PowerShell 5.1, this stage installs pwsh and the orchestrator's
    auto-resume after the install relaunches under pwsh.

    Strategy:
      1. Check existing: if `pwsh -v` reports >= MinVersion, skip.
      2. Try `winget install -e --id Microsoft.PowerShell`.
      3. If winget unavailable or exits non-zero, fall back to direct MSI
         download from github.com/PowerShell/PowerShell/releases. SHA256
         verified via Get-PkgDownload.
      4. Verify the post-install pwsh -v.

    Idempotency: re-running on an already-installed system returns
    Overall='Pass' with a "skipped" step. Stage NEVER reboots; pwsh MSI
    is non-reboot-required.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Pkg','Retry') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultPwsh7Invoker {
    @{
        # Probe the on-disk pwsh and return its version string ($null when missing).
        GetPwshVersion = {
            $cmd = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
            if (-not $cmd) { return $null }
            try {
                # `pwsh -v` prints something like "PowerShell 7.4.1"
                $raw = & $cmd.Source -NoProfile -Command 'Write-Output $PSVersionTable.PSVersion.ToString()'
                if ($raw) { return ($raw -as [string]).Trim() }
            } catch { $null = $_ }
            return $null
        }
        # Whether winget is available (used to gate the winget vs MSI fallback path).
        TestWingetAvailable = {
            [bool](Get-Command -Name 'winget' -ErrorAction SilentlyContinue)
        }
    }
}

$script:Pwsh7Invokers = Get-DefaultPwsh7Invoker

function Confirm-Pwsh7TestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-Pwsh7Invoker."
    }
}

function Set-Pwsh7Invoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GetPwshVersion','TestWingetAvailable')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-Pwsh7TestSeamAllowed
    $script:Pwsh7Invokers[$Name] = $ScriptBlock
}

function Reset-Pwsh7Invoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-Pwsh7TestSeamAllowed
    $script:Pwsh7Invokers = Get-DefaultPwsh7Invoker
}

# ---------- helpers ----------

function Test-Pwsh7Already {
    param([version]$MinVersion = '7.0')
    $raw = & $script:Pwsh7Invokers.GetPwshVersion
    if (-not $raw) { return [pscustomobject]@{ Installed = $false; Version = $null } }
    $ver = $null
    try { $ver = [version]$raw } catch { $null = $_ }
    if (-not $ver) { return [pscustomobject]@{ Installed = $false; Version = $raw } }
    [pscustomobject]@{ Installed = ($ver -ge $MinVersion); Version = $raw }
}

# ---------- public ----------

function Invoke-Powershell7Stage {
    <#
    .SYNOPSIS
        Ensure PowerShell 7+ is installed. Returns
            @{ Overall='Pass'|'Warn'|'Fail'; Steps=@(); Detail; Remediation }

    .PARAMETER MinVersion       Minimum acceptable version (default 7.4).
    .PARAMETER WingetId          winget package id (Microsoft.PowerShell).
    .PARAMETER MsiUrl            Fallback MSI URL (operator can override).
    .PARAMETER MsiSha256         Required hash to validate the MSI download.
    .PARAMETER DryRun            Skip mutating calls; just report decisions.
    #>
    [CmdletBinding()]
    param(
        [version]$MinVersion = '7.4',
        [string]$WingetId    = 'Microsoft.PowerShell',
        [string]$MsiUrl,
        [string]$MsiSha256,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    # 1. Already installed?
    $probe = Test-Pwsh7Already -MinVersion $MinVersion
    if ($probe.Installed) {
        _step 'Detect existing pwsh' 'Pass' "pwsh $($probe.Version) already installed (>= $MinVersion)"
        return [pscustomobject]@{
            Overall = 'Pass'
            Steps   = $steps.ToArray()
            Detail  = "pwsh $($probe.Version) already present"
        }
    } elseif ($probe.Version) {
        _step 'Detect existing pwsh' 'Warn' "pwsh $($probe.Version) present but below $MinVersion -- upgrading"
    } else {
        _step 'Detect existing pwsh' 'Warn' 'pwsh not found -- installing'
    }

    if ($DryRun) {
        _step 'Install pwsh 7' 'Skipped' '-DryRun: skipping install path'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: would have installed pwsh 7' }
    }

    # 2. Try winget first.
    $wingetOk = $false
    if (& $script:Pwsh7Invokers.TestWingetAvailable) {
        $r = Install-PkgViaWinget -Id $WingetId
        if ($r.Ok) {
            _step 'winget install' 'Pass' "installed $WingetId via winget"
            $wingetOk = $true
        } else {
            _step 'winget install' 'Warn' "winget exited $($r.ExitCode); falling back to MSI ($($r.Detail))"
        }
    } else {
        _step 'winget install' 'Skipped' 'winget not available -- using MSI fallback'
    }

    # 3. Fallback to direct MSI download.
    if (-not $wingetOk) {
        if (-not $MsiUrl) {
            _step 'MSI fallback' 'Fail' 'no -MsiUrl provided and winget did not succeed'
            return [pscustomobject]@{
                Overall     = 'Fail'
                Steps       = $steps.ToArray()
                Detail      = 'pwsh 7 not installed: winget unavailable/failed and no MSI URL was provided'
                Remediation = 'Pass -MsiUrl + -MsiSha256, or install winget, or install pwsh 7 manually from https://aka.ms/PowerShell.'
            }
        }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pwsh-7-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.msi')
        $dl  = Get-PkgDownload -Url $MsiUrl -Dest $tmp -Sha256 $MsiSha256
        if (-not $dl.Ok) {
            _step 'MSI download' 'Fail' $dl.Detail
            return [pscustomobject]@{
                Overall     = 'Fail'
                Steps       = $steps.ToArray()
                Detail      = "pwsh 7 MSI download failed: $($dl.Detail)"
                Remediation = 'Verify MsiUrl + MsiSha256 are correct and the controller can reach the URL.'
            }
        }
        _step 'MSI download' 'Pass' "downloaded + verified ($($dl.Detail))"
        $ins = Install-PkgMsi -MsiPath $tmp
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if (-not $ins.Ok) {
            _step 'MSI install' 'Fail' $ins.Detail
            return [pscustomobject]@{
                Overall     = 'Fail'
                Steps       = $steps.ToArray()
                Detail      = "msiexec exited $($ins.ExitCode); see log $($ins.Log)"
                Remediation = "Inspect $($ins.Log) and re-run; ensure no other pwsh process is holding files."
            }
        }
        _step 'MSI install' 'Pass' "installed via MSI (exit $($ins.ExitCode); log $($ins.Log))"
    }

    # 4. Verify post-install.
    $probe2 = Test-Pwsh7Already -MinVersion $MinVersion
    if ($probe2.Installed) {
        _step 'Verify pwsh' 'Pass' "pwsh $($probe2.Version) confirmed installed"
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "pwsh $($probe2.Version) installed" }
    }

    _step 'Verify pwsh' 'Fail' "Post-install probe still does not see pwsh >= $MinVersion (saw '$($probe2.Version)')"
    [pscustomobject]@{
        Overall     = 'Fail'
        Steps       = $steps.ToArray()
        Detail      = "pwsh install reported success but post-install probe failed"
        Remediation = 'Open a NEW elevated shell and run `pwsh -Version` manually; verify the install actually completed.'
    }
}
