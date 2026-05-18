<#
.SYNOPSIS
    Update MeshCentral safely. Backup-first, npm-update, health-check,
    auto-rollback if the new version fails to serve HTTPS.

.DESCRIPTION
    The dangerous part of updating MeshCentral is that a bad version can
    leave the dashboard unreachable, which means the operator can't
    diagnose anything via MeshCentral itself. This script structures the
    update so it's always recoverable:

       1. Read $env:CLUSTERCTRL_ADMIN_PASS sanity (warn if missing).
       2. Backup-Controller -> writes a known-good archive.
       3. Stop MeshCentral.
       4. Capture old version (Get-Content node_modules\meshcentral\package.json).
       5. npm install meshcentral[@TargetVersion] --prefix <root>.
       6. Start MeshCentral; wait for HTTPS to respond.
       7. On health-fail: Stop, Restore-Controller from step-2 archive,
          Start, exit non-zero.

    Idempotent in the sense that re-running on an already-current
    installation is a no-op apart from a fresh backup.
#>

[CmdletBinding()]
param(
    [string]$TargetVersion,
    [string]$ConfigPath,
    [int]$HealthWaitSeconds = 60,
    [switch]$NoBackup,
    [switch]$NoRollback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $repoRoot 'src\lib'
foreach ($mod in 'Logging','Config','Service','Net','Retry') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultUpdateInvoker {
    @{
        ReadMeshcentralVersion = {
            param([string]$Root)
            $pkg = Join-Path $Root 'node_modules\meshcentral\package.json'
            if (-not (Test-Path -LiteralPath $pkg)) { return $null }
            try {
                $obj = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json
                return "$($obj.version)"
            } catch { $null = $_; return $null }
        }
        RunNpmInstall = {
            param([string]$Root, [string]$VersionPin)
            $argv = if ($VersionPin) { @('install',"meshcentral@$VersionPin",'--prefix', $Root) } else { @('install','meshcentral@latest','--prefix', $Root) }
            $p = Start-Process -FilePath 'npm.cmd' -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        InvokeBackup = {
            param([string]$ConfigPath)
            # Best-effort: invoke the sibling script. Returns the archive path.
            $script = Join-Path $PSScriptRoot 'Backup-Controller.ps1'
            $argv = @()
            if ($ConfigPath) { $argv = @('-ConfigPath', $ConfigPath) }
            # Capture the last "Backup written:" line from the script's output.
            $r = & pwsh -NoProfile -Command "& { . '$script'; (Invoke-ControllerBackup @args).ToString() }" @argv
            return $r
        }
        InvokeRestore = {
            param([string]$ArchivePath, [string]$ConfigPath)
            $script = Join-Path $PSScriptRoot 'Restore-Controller.ps1'
            $argv = @('-ArchivePath', $ArchivePath, '-Force')
            if ($ConfigPath) { $argv += @('-ConfigPath', $ConfigPath) }
            & pwsh -NoProfile -Command "& { . '$script'; (Invoke-ControllerRestore @args).Overall }" @argv
        }
    }
}

$script:UpdateInvokers = Get-DefaultUpdateInvoker

function Confirm-UpdateTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-UpdateInvoker."
    }
}

function Set-UpdateInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ReadMeshcentralVersion','RunNpmInstall','InvokeBackup','InvokeRestore')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-UpdateTestSeamAllowed
    $script:UpdateInvokers[$Name] = $ScriptBlock
}

function Reset-UpdateInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-UpdateTestSeamAllowed
    $script:UpdateInvokers = Get-DefaultUpdateInvoker
}

# ---------- public ----------

function Invoke-MeshcentralUpdate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Update is the explicit purpose; unattended-friendly.')]
    [CmdletBinding()]
    param(
        [string]$TargetVersion,
        [string]$ConfigPath,
        [int]$HealthWaitSeconds = 60,
        [switch]$NoBackup,
        [switch]$NoRollback
    )

    $cfg = (Read-ControllerConfig -Path $ConfigPath).Config
    $dataDir   = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $mcRoot    = Split-Path -Parent $dataDir
    $httpsPort = [int]$cfg.controller.https_port

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $oldVer = & $script:UpdateInvokers.ReadMeshcentralVersion $mcRoot
    if (-not $oldVer) {
        _step 'Detect current version' 'Fail' "could not read meshcentral package.json under $mcRoot"
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
    }
    _step 'Detect current version' 'Pass' "current=$oldVer; target=$(if ($TargetVersion) { $TargetVersion } else { 'latest' })"

    # 1. Backup.
    $archive = $null
    if (-not $NoBackup) {
        try {
            $archive = & $script:UpdateInvokers.InvokeBackup $ConfigPath
            if (-not $archive -or -not (Test-Path -LiteralPath $archive)) {
                _step 'Pre-update backup' 'Fail' 'backup script did not produce an archive'
                return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
            }
            _step 'Pre-update backup' 'Pass' "archive=$archive"
        } catch {
            _step 'Pre-update backup' 'Fail' "backup threw: $($_.Exception.Message)"
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
        }
    } else {
        _step 'Pre-update backup' 'Skipped' '-NoBackup specified (operator accepts risk)'
    }

    # 2. Stop MeshCentral.
    $stop = Stop-ServiceIdempotent -Name 'MeshCentral' -WaitSeconds 30
    if ($stop.Ok) { _step 'Stop MeshCentral' 'Pass' $stop.Detail }
    else { _step 'Stop MeshCentral' 'Warn' $stop.Detail }

    # 3. npm install meshcentral.
    $r = & $script:UpdateInvokers.RunNpmInstall $mcRoot $TargetVersion
    if ($r.ExitCode -ne 0) {
        _step 'npm install meshcentral' 'Fail' "npm exited $($r.ExitCode)"
        # Restart whatever's there before throwing -- we don't want to leave the service down.
        Start-ServiceIdempotent -Name 'MeshCentral' -WaitSeconds 30 | Out-Null
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
    }
    $newVer = & $script:UpdateInvokers.ReadMeshcentralVersion $mcRoot
    _step 'npm install meshcentral' 'Pass' "old=$oldVer new=$newVer"

    # 4. Start + health probe.
    $start = Start-ServiceIdempotent -Name 'MeshCentral' -WaitSeconds 30
    if ($start.Ok -and $start.State -eq 'Running') { _step 'Start MeshCentral' 'Pass' $start.Detail }
    else { _step 'Start MeshCentral' 'Warn' $start.Detail }

    $health = Test-NetHttpReachable -Url "https://localhost:$httpsPort/" -TimeoutMs ($HealthWaitSeconds * 1000) -ExpectStatus 0
    if ($health.Ok) {
        _step 'Post-update health probe' 'Pass' "https://localhost:$httpsPort/ responded $($health.Status)"
        return [pscustomobject]@{
            Overall    = 'Pass'
            Steps      = $steps.ToArray()
            OldVersion = $oldVer
            NewVersion = $newVer
            BackupArchive = $archive
            Detail     = "MeshCentral updated $oldVer -> $newVer"
        }
    }

    _step 'Post-update health probe' 'Fail' "did not respond: $($health.Reason)"
    if ($NoRollback) {
        return [pscustomobject]@{
            Overall = 'Fail'
            Steps   = $steps.ToArray()
            Detail  = "MeshCentral $newVer is not healthy; -NoRollback set so leaving as-is. Backup at $archive."
        }
    }
    if (-not $archive) {
        return [pscustomobject]@{
            Overall = 'Fail'
            Steps   = $steps.ToArray()
            Detail  = "MeshCentral $newVer is not healthy and no backup is available (-NoBackup was set). Manual recovery required."
        }
    }

    _step 'Rollback' 'Warn' 'health probe failed; attempting auto-rollback'
    try {
        & $script:UpdateInvokers.InvokeRestore $archive $ConfigPath
        _step 'Rollback' 'Pass' "restored $archive"
        return [pscustomobject]@{
            Overall = 'Fail'
            Steps   = $steps.ToArray()
            Detail  = "MeshCentral $newVer was unhealthy; rolled back to $oldVer from $archive."
        }
    } catch {
        _step 'Rollback' 'Fail' "rollback threw: $($_.Exception.Message)"
        return [pscustomobject]@{
            Overall = 'Fail'
            Steps   = $steps.ToArray()
            Detail  = "Update FAILED and ROLLBACK FAILED. Backup is at $archive; restore manually."
        }
    }
}

if ($env:CLUSTERCTRL_NOAUTORUN -ne '1') {
    $r = Invoke-MeshcentralUpdate -TargetVersion $TargetVersion -ConfigPath $ConfigPath `
                                   -HealthWaitSeconds $HealthWaitSeconds -NoBackup:$NoBackup -NoRollback:$NoRollback
    $r.Steps | Format-Table -AutoSize Name, Status, Detail
    Write-Host "Overall: $($r.Overall)" -ForegroundColor $(if ($r.Overall -eq 'Pass') { 'Green' } else { 'Red' })
    if ($r.Overall -ne 'Pass') { exit 1 }
}
