<#
.SYNOPSIS
    Stage 3 -- Install the OpenSSH Client Windows Capability so the
    controller can `ssh` / `Invoke-Command -HostName` against the host PCs.

.DESCRIPTION
    Strategy (idempotent):
      1. Probe via Get-WindowsCapability -- skip with Pass if Installed.
      2. Try Add-WindowsCapability -Online (primary).
      3. Fallback to DISM /Online /Add-Capability when WindowsCapability
         is unavailable or fails.
      4. Verify ssh.exe is on PATH after install.

    No reboot is required for OpenSSH client.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Retry') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultOpenSshClientInvoker {
    @{
        GetCapability = {
            param([string]$Filter = 'OpenSSH.Client*')
            try {
                $cap = Get-WindowsCapability -Online -ErrorAction Stop |
                       Where-Object { $_.Name -like $Filter } |
                       Select-Object -First 1
                if (-not $cap) { return [pscustomobject]@{ Found = $false; Name = $null; State = 'Unknown' } }
                [pscustomobject]@{ Found = $true; Name = "$($cap.Name)"; State = "$($cap.State)" }
            } catch {
                $null = $_
                [pscustomobject]@{ Found = $false; Name = $null; State = 'Unknown' }
            }
        }
        AddCapability = {
            param([string]$Name)
            Add-WindowsCapability -Online -Name $Name -ErrorAction Stop | Out-Null
        }
        RunDism = {
            param([string]$Name)
            $p = Start-Process -FilePath 'dism.exe' -ArgumentList @('/Online','/Quiet','/NoRestart','/Add-Capability',"/CapabilityName:$Name") -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        TestSshOnPath = {
            [bool](Get-Command -Name 'ssh' -ErrorAction SilentlyContinue)
        }
    }
}

$script:OpenSshClientInvokers = Get-DefaultOpenSshClientInvoker

function Confirm-OpenSshClientTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-OpenSshClientInvoker."
    }
}

function Set-OpenSshClientInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GetCapability','AddCapability','RunDism','TestSshOnPath')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-OpenSshClientTestSeamAllowed
    $script:OpenSshClientInvokers[$Name] = $ScriptBlock
}

function Reset-OpenSshClientInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-OpenSshClientTestSeamAllowed
    $script:OpenSshClientInvokers = Get-DefaultOpenSshClientInvoker
}

# ---------- public ----------

function Invoke-OpenSshClientStage {
    [CmdletBinding()]
    param(
        [string]$CapabilityName = 'OpenSSH.Client~~~~0.0.1.0',
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    # 1. Probe.
    $cap = & $script:OpenSshClientInvokers.GetCapability 'OpenSSH.Client*'
    if ($cap.Found -and $cap.State -eq 'Installed') {
        _step 'Detect OpenSSH client' 'Pass' "$($cap.Name) already Installed"
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'already installed' }
    }
    if ($cap.Found) {
        _step 'Detect OpenSSH client' 'Warn' "$($cap.Name) State=$($cap.State); proceeding to install"
    } else {
        _step 'Detect OpenSSH client' 'Warn' 'capability listing did not include OpenSSH.Client*; will attempt install anyway'
    }

    if ($DryRun) {
        _step 'Install OpenSSH client' 'Skipped' '-DryRun: would have installed via WindowsCapability/DISM'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: would have installed OpenSSH client' }
    }

    # 2. Primary: Add-WindowsCapability.
    $name = if ($cap.Found -and $cap.Name) { $cap.Name } else { $CapabilityName }
    $primaryOk = $false
    try {
        & $script:OpenSshClientInvokers.AddCapability $name
        _step 'WindowsCapability install' 'Pass' "Add-WindowsCapability ($name)"
        $primaryOk = $true
    } catch {
        _step 'WindowsCapability install' 'Warn' "Add-WindowsCapability failed: $($_.Exception.Message). Falling back to DISM."
    }

    # 3. Fallback: DISM.
    if (-not $primaryOk) {
        $r = & $script:OpenSshClientInvokers.RunDism $name
        if ($r.ExitCode -ne 0) {
            _step 'DISM install' 'Fail' "DISM exited $($r.ExitCode)"
            return [pscustomobject]@{
                Overall     = 'Fail'
                Steps       = $steps.ToArray()
                Detail      = "OpenSSH client install failed via both WindowsCapability and DISM"
                Remediation = "Try manually: Add-WindowsCapability -Online -Name $name"
            }
        }
        _step 'DISM install' 'Pass' "DISM installed $name"
    }

    # 4. Verify.
    $sshOnPath = [bool](& $script:OpenSshClientInvokers.TestSshOnPath)
    $cap2      = & $script:OpenSshClientInvokers.GetCapability 'OpenSSH.Client*'
    if ($sshOnPath -or ($cap2.Found -and $cap2.State -eq 'Installed')) {
        _step 'Verify ssh' 'Pass' "ssh available (state=$($cap2.State), on-path=$sshOnPath)"
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'OpenSSH client installed' }
    }

    _step 'Verify ssh' 'Warn' "post-install probe still doesn't show ssh; may need a new shell to refresh PATH"
    [pscustomobject]@{
        Overall = 'Warn'
        Steps   = $steps.ToArray()
        Detail  = 'install reported success but PATH does not yet contain ssh.exe'
        Remediation = 'Open a new shell or reboot. ssh.exe is at C:\Windows\System32\OpenSSH\ssh.exe.'
    }
}
