<#
.SYNOPSIS
    Remove the controller-side cluster setup. Stops services, removes
    firewall rules + SMB share + registered scheduled task. Preserves
    data dirs by default; pass -PurgeData to also wipe them.

.DESCRIPTION
    Intentionally does NOT uninstall Node.js, MongoDB, or PowerShell 7 --
    those may be in use elsewhere on the same PC. Operator can remove
    them with winget / Apps & Features afterwards if desired.

    Steps:
      1. Stop + remove ClusterAnnouncer service (NSSM).
      2. Stop + remove MeshCentral service (via `node meshcentral --uninstall`,
         or sc.exe delete as fallback).
      3. Remove the ClusterShare SMB share.
      4. Remove all 'ClusterController:*' firewall rules.
      5. Unregister the resume scheduled task (if present).
      6. Remove HKLM:\Software\ClusterController state.
      7. (Optional, with -PurgeData) Remove %ProgramData%\ClusterController
         and %ProgramData%\MeshCentral trees.

    Always prompts for confirmation unless -Yes is set.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$PurgeData,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $repoRoot 'src\lib'
foreach ($mod in 'Logging','Config','Service','Firewall','Smb','State') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultUninstallInvoker {
    @{
        # Remove the entire ClusterAnnouncer service via NSSM.
        RemoveAnnouncerService = {
            $p = Start-Process -FilePath 'nssm.exe' -ArgumentList @('stop','ClusterAnnouncer') -Wait -PassThru -WindowStyle Hidden
            $null = $p
            $p = Start-Process -FilePath 'nssm.exe' -ArgumentList @('remove','ClusterAnnouncer','confirm') -Wait -PassThru -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        # Run `node meshcentral --uninstall` to remove the MeshCentral service.
        RunMeshcentralUninstall = {
            param([string]$NodeExe, [string]$Entry, [string]$WorkingDir)
            $p = Start-Process -FilePath $NodeExe -ArgumentList @($Entry, '--uninstall') -WorkingDirectory $WorkingDir -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        # sc.exe fallback for service removal.
        ScDelete = {
            param([string]$ServiceName)
            $p = Start-Process -FilePath 'sc.exe' -ArgumentList @('delete', $ServiceName) -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        ListClusterRules = {
            try { @(Get-NetFirewallRule -DisplayName 'ClusterController:*' -ErrorAction SilentlyContinue) }
            catch { $null = $_; @() }
        }
        RemoveItemTree = {
            param([string]$Path)
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        TestNodeOnPath = {
            $c = Get-Command -Name 'node' -ErrorAction SilentlyContinue
            if ($c) { $c.Source } else { $null }
        }
    }
}

$script:UninstallInvokers = Get-DefaultUninstallInvoker

function Confirm-UninstallTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-UninstallInvoker."
    }
}

function Set-UninstallInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RemoveAnnouncerService','RunMeshcentralUninstall','ScDelete','ListClusterRules','RemoveItemTree','TestNodeOnPath')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-UninstallTestSeamAllowed
    $script:UninstallInvokers[$Name] = $ScriptBlock
}

function Reset-UninstallInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-UninstallTestSeamAllowed
    $script:UninstallInvokers = Get-DefaultUninstallInvoker
}

# ---------- public ----------

function Invoke-ControllerUninstall {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Uninstall is the explicit purpose; -Yes flag is the affirmative consent.')]
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$PurgeData,
        [switch]$Yes
    )

    if (-not $Yes) {
        # No interactive prompt -- be safe and refuse without explicit affirmative.
        return [pscustomobject]@{
            Overall = 'Skipped'
            Steps   = @()
            Detail  = 'Uninstall not run: pass -Yes to confirm. With -PurgeData also wipes %ProgramData%\ClusterController and %ProgramData%\MeshCentral.'
        }
    }

    $cfg = (Read-ControllerConfig -Path $ConfigPath).Config
    $dataDir   = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $mcRoot    = Split-Path -Parent $dataDir
    $entry     = Join-Path $mcRoot 'node_modules\meshcentral\meshcentral.js'
    $shareName = "$($cfg.share.name)"
    $shareRoot = Expand-ConfigPath -Value "$($cfg.share.root)"
    $ctrlRoot  = Split-Path -Parent $shareRoot   # %ProgramData%\ClusterController

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    # 1. Announcer.
    try {
        $r = & $script:UninstallInvokers.RemoveAnnouncerService
        _step 'Remove ClusterAnnouncer service' 'Pass' "nssm exit $($r.ExitCode)"
    } catch {
        _step 'Remove ClusterAnnouncer service' 'Warn' "$($_.Exception.Message)"
    }

    # 2. MeshCentral.
    $nodeExe = & $script:UninstallInvokers.TestNodeOnPath
    $mcRemoved = $false
    if ($nodeExe -and (Test-Path -LiteralPath $entry)) {
        try {
            $r = & $script:UninstallInvokers.RunMeshcentralUninstall $nodeExe $entry $mcRoot
            if ($r.ExitCode -eq 0) {
                _step 'Remove MeshCentral service (built-in)' 'Pass' "node --uninstall exit 0"
                $mcRemoved = $true
            } else {
                _step 'Remove MeshCentral service (built-in)' 'Warn' "node --uninstall exit $($r.ExitCode); falling back to sc.exe delete"
            }
        } catch {
            _step 'Remove MeshCentral service (built-in)' 'Warn' "$($_.Exception.Message); falling back to sc.exe delete"
        }
    }
    if (-not $mcRemoved) {
        try {
            $r = & $script:UninstallInvokers.ScDelete 'MeshCentral'
            _step 'Remove MeshCentral service (sc.exe)' 'Pass' "sc.exe delete exit $($r.ExitCode)"
        } catch {
            _step 'Remove MeshCentral service (sc.exe)' 'Warn' "$($_.Exception.Message)"
        }
    }

    # 3. SMB share.
    $sm = Remove-IdempotentSmbShare -Name $shareName
    _step "Remove SMB share '$shareName'" $(if ($sm.Ok) { 'Pass' } else { 'Warn' }) $sm.Detail

    # 4. Firewall rules.
    $rules = @(& $script:UninstallInvokers.ListClusterRules)
    foreach ($r in $rules) {
        try {
            $rem = Remove-IdempotentFirewallRule -Name "$($r.DisplayName)"
            _step "Remove rule '$($r.DisplayName)'" $(if ($rem.Ok) { 'Pass' } else { 'Warn' }) $rem.Detail
        } catch {
            _step "Remove rule '$($r.DisplayName)'" 'Warn' "$($_.Exception.Message)"
        }
    }

    # 5. Resume scheduled task.
    try {
        Unregister-ResumeTask
        _step 'Remove resume scheduled task' 'Pass' 'unregistered (or was not present)'
    } catch {
        _step 'Remove resume scheduled task' 'Warn' "$($_.Exception.Message)"
    }

    # 6. Registry state.
    try {
        Reset-ClusterRunState
        _step 'Wipe HKLM:\Software\ClusterController state' 'Pass' 'state cleared'
    } catch {
        _step 'Wipe HKLM:\Software\ClusterController state' 'Warn' "$($_.Exception.Message)"
    }

    # 7. Data dirs (only with -PurgeData).
    if ($PurgeData) {
        foreach ($p in $ctrlRoot, (Split-Path -Parent $mcRoot)) {
            # Split-Path of $mcRoot is %ProgramData% which is too broad; we ONLY purge
            # %ProgramData%\ClusterController and %ProgramData%\MeshCentral itself.
        }
        $purge = @($ctrlRoot, $mcRoot)
        foreach ($p in $purge) {
            try {
                & $script:UninstallInvokers.RemoveItemTree $p
                _step "Purge $p" 'Pass' 'removed (if present)'
            } catch {
                _step "Purge $p" 'Warn' "$($_.Exception.Message)"
            }
        }
    } else {
        _step 'Data dirs' 'Skipped' 'preserved; pass -PurgeData to wipe %ProgramData%\ClusterController + %ProgramData%\MeshCentral'
    }

    [pscustomobject]@{
        Overall = 'Pass'
        Steps   = $steps.ToArray()
        Detail  = "Controller uninstalled (purge=$PurgeData). Node.js / MongoDB / PowerShell 7 left in place; remove via Apps & Features if no longer needed."
    }
}

if ($env:CLUSTERCTRL_NOAUTORUN -ne '1') {
    $r = Invoke-ControllerUninstall -ConfigPath $ConfigPath -PurgeData:$PurgeData -Yes:$Yes
    $r.Steps | Format-Table -AutoSize Name, Status, Detail
    Write-Host "Overall: $($r.Overall)" -ForegroundColor $(if ($r.Overall -eq 'Pass') { 'Green' } else { 'Yellow' })
}
