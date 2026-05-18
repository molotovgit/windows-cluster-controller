<#
.SYNOPSIS
    Stage 4 -- Install Node.js LTS. Combines the download (SHA256-verified)
    and the silent MSI install.

.DESCRIPTION
    MeshCentral needs Node.js to run. We pin a known-good LTS version in
    cluster-controller.json (.meshcentral.node_version_pin) or the caller
    supplies the URL + hash directly via parameters.

    Strategy:
      1. Probe: `node -v` >= -MinVersion -> Skip with Pass.
      2. Download MSI via lib/Pkg Get-PkgDownload (SHA256 verified).
      3. Install via lib/Pkg Install-PkgMsi (msiexec /qn).
      4. Refresh PATH from the registry (so this same shell can see node).
      5. Verify `node -v` after install.

    Idempotency: re-running with node already installed returns Pass
    immediately. No reboot required.
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

function Get-DefaultNodeInvoker {
    @{
        # Returns the node -v version string ("v20.11.0") or $null if absent.
        GetNodeVersion = {
            $cmd = Get-Command -Name 'node' -ErrorAction SilentlyContinue
            if (-not $cmd) { return $null }
            try {
                $raw = & $cmd.Source --version 2>$null
                if ($raw) { return ($raw -as [string]).Trim() }
            } catch { $null = $_ }
            return $null
        }
        # Refresh this process's PATH from the registry so a just-installed
        # node.exe is visible without restarting the shell.
        RefreshPathFromRegistry = {
            try {
                $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
                $user    = [Environment]::GetEnvironmentVariable('Path','User')
                if ($machine -or $user) {
                    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
                }
            } catch { $null = $_ }
        }
    }
}

$script:NodeInvokers = Get-DefaultNodeInvoker

function Confirm-NodeTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-NodeInvoker."
    }
}

function Set-NodeInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GetNodeVersion','RefreshPathFromRegistry')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-NodeTestSeamAllowed
    $script:NodeInvokers[$Name] = $ScriptBlock
}

function Reset-NodeInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-NodeTestSeamAllowed
    $script:NodeInvokers = Get-DefaultNodeInvoker
}

function ConvertTo-NodeVersionObject {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $clean = $Raw.TrimStart('v')
    try { return [version]$clean } catch { return $null }
}

# ---------- public ----------

function Invoke-NodeStage {
    <#
    .SYNOPSIS Install (or confirm) Node.js LTS.
    .PARAMETER MsiUrl       Direct URL to the Node MSI on nodejs.org. Required if not yet installed.
    .PARAMETER MsiSha256    Hex digest the download is verified against.
    .PARAMETER MinVersion   Minimum acceptable version (default 18.0; LTS line covers 20+).
    .PARAMETER DryRun       Report decisions without downloading or installing.
    #>
    [CmdletBinding()]
    param(
        [string]$MsiUrl,
        [string]$MsiSha256,
        [version]$MinVersion = '18.0',
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    # 1. Probe.
    $raw = & $script:NodeInvokers.GetNodeVersion
    $ver = ConvertTo-NodeVersionObject -Raw $raw
    if ($ver -and $ver -ge $MinVersion) {
        _step 'Detect existing node' 'Pass' "node $raw already installed (>= $MinVersion)"
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "node $raw already present" }
    }
    if ($ver) {
        _step 'Detect existing node' 'Warn' "node $raw present but below $MinVersion -- upgrading"
    } else {
        _step 'Detect existing node' 'Warn' 'node not on PATH -- installing'
    }

    if ($DryRun) {
        _step 'Install node' 'Skipped' '-DryRun: skipping download + install'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: would have installed Node.js LTS' }
    }

    if (-not $MsiUrl) {
        _step 'Install node' 'Fail' 'no -MsiUrl provided'
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = 'Node.js not installed and no MsiUrl supplied'
            Remediation = 'Pass -MsiUrl + -MsiSha256 from a known-good LTS release on nodejs.org.'
        }
    }

    # 2. Download.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('node-lts-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.msi')
    $dl  = Get-PkgDownload -Url $MsiUrl -Dest $tmp -Sha256 $MsiSha256
    if (-not $dl.Ok) {
        _step 'Download node MSI' 'Fail' $dl.Detail
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = "Node.js MSI download failed: $($dl.Detail)"
            Remediation = 'Verify MsiUrl + MsiSha256 are correct and the controller can reach nodejs.org.'
        }
    }
    _step 'Download node MSI' 'Pass' "downloaded + verified ($($dl.Detail))"

    # 3. Install.
    $ins = Install-PkgMsi -MsiPath $tmp
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if (-not $ins.Ok) {
        _step 'Install node MSI' 'Fail' $ins.Detail
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = "msiexec exited $($ins.ExitCode); see log $($ins.Log)"
            Remediation = "Inspect $($ins.Log); ensure no other node process is holding files."
        }
    }
    _step 'Install node MSI' 'Pass' "installed (exit $($ins.ExitCode))"

    # 4. Refresh PATH so we can probe in this same shell.
    & $script:NodeInvokers.RefreshPathFromRegistry
    _step 'Refresh PATH' 'Pass' 'machine + user PATH merged into this process'

    # 5. Verify.
    $raw2 = & $script:NodeInvokers.GetNodeVersion
    $ver2 = ConvertTo-NodeVersionObject -Raw $raw2
    if ($ver2 -and $ver2 -ge $MinVersion) {
        _step 'Verify node' 'Pass' "node $raw2 confirmed"
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "node $raw2 installed" }
    }

    _step 'Verify node' 'Fail' "post-install probe still does not see node >= $MinVersion (saw '$raw2')"
    [pscustomobject]@{
        Overall     = 'Fail'
        Steps       = $steps.ToArray()
        Detail      = 'install reported success but verify failed'
        Remediation = 'Open a NEW elevated shell and run `node -v`; if missing, re-run installer manually or inspect %ProgramFiles%\nodejs.'
    }
}
