<#
.SYNOPSIS
    Stage 11 -- Share. Create the golden-VHDX drop dir + the
    ClusterShare SMB export that host PCs pull from.

.DESCRIPTION
    Combines GoldenVhdxDir (planned PR 35) and Smb (planned PR 36)
    because both touch the same %ProgramData%\ClusterController\share
    tree. Idempotent throughout.

    Emits a Warn (NOT a Fail) when the golden VHDX dir is empty -- the
    operator is expected to drop a golden Win11 Pro VHDX into it after
    initial controller setup. The host PCs cannot deploy VMs without it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Smb','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

function Get-DefaultShareInvoker {
    @{
        EnsureDir = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        }
        ListDir = {
            param([string]$Path, [string]$Filter = '*')
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            @(Get-ChildItem -Path $Path -Filter $Filter -File -ErrorAction SilentlyContinue)
        }
    }
}

$script:ShareInvokers = Get-DefaultShareInvoker

function Confirm-ShareTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-ShareInvoker."
    }
}

function Set-ShareInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('EnsureDir','ListDir')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-ShareTestSeamAllowed
    $script:ShareInvokers[$Name] = $ScriptBlock
}

function Reset-ShareInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-ShareTestSeamAllowed
    $script:ShareInvokers = Get-DefaultShareInvoker
}

function Invoke-ShareStage {
    [CmdletBinding()]
    param(
        $Config,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $shareName = "$($cfg.share.name)"
    $shareRoot = Expand-ConfigPath -Value "$($cfg.share.root)"
    $vhdxDir   = Join-Path $shareRoot "$($cfg.share.vhdx_subdir)"
    $agentsDir = Join-Path $shareRoot "$($cfg.share.agents_subdir)"

    _step 'Resolve share plan' 'Pass' "name=$shareName root=$shareRoot vhdx=$vhdxDir agents=$agentsDir"

    if ($DryRun) {
        _step 'Create share dirs + SMB share' 'Skipped' '-DryRun: would have created dirs and SMB share'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: share' }
    }

    # 1. Ensure dir tree.
    foreach ($p in $shareRoot, $vhdxDir, $agentsDir) {
        try { & $script:ShareInvokers.EnsureDir $p } catch {
            _step 'Create share dirs' 'Fail' "could not create '$p': $($_.Exception.Message)"
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = "dir creation failed" }
        }
    }
    _step 'Create share dirs' 'Pass' "all three present"

    # 2. Golden VHDX warning (Warn, not Fail).
    $vhdxFiles = @(& $script:ShareInvokers.ListDir $vhdxDir '*.vhdx')
    if ($vhdxFiles.Count -eq 0) {
        _step 'Golden VHDX present' 'Warn' "no *.vhdx files in $vhdxDir -- host PCs will not be able to deploy VMs until you drop a golden Win11 Pro VHDX here."
    } else {
        _step 'Golden VHDX present' 'Pass' "$($vhdxFiles.Count) VHDX file(s) found"
    }

    # 3. Create / update the SMB share via lib/Smb.
    $smb = New-IdempotentSmbShare -Name $shareName -Path $shareRoot `
                                  -Description 'Cluster Controller share (golden VHDX + agent bundles)' `
                                  -ReadAccess @('Authenticated Users') `
                                  -FullAccess @('Administrators')
    if (-not $smb.Ok) {
        _step "SMB share '$shareName'" 'Fail' "$($smb.Action): $($smb.Detail)"
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = "SMB share '$shareName' could not be created: $($smb.Detail)"
            Remediation = "Inspect 'Get-SmbShare $shareName' and resolve the path conflict or permission issue."
        }
    }
    _step "SMB share '$shareName'" 'Pass' "$($smb.Action): $($smb.Detail)"

    $overall = if ($vhdxFiles.Count -eq 0) { 'Warn' } else { 'Pass' }
    [pscustomobject]@{
        Overall = $overall
        Steps   = $steps.ToArray()
        Detail  = "share '$shareName' -> $shareRoot ready ($($vhdxFiles.Count) VHDX file(s))"
    }
}
