<#
.SYNOPSIS
    Top-level orchestrator for the windows-cluster-controller setup.

.DESCRIPTION
    Imports all lib modules and stage scripts, then runs the 13 stages
    in order:
        1. Preflight       (read-only)
        2. Powershell7     (winget -> MSI fallback)
        3. OpenSshClient   (capability -> DISM fallback)
        4. Node            (download + install Node.js LTS)
        5. Db              (NeDB skip OR MongoDB install + configure + start)
        6. Meshcentral     (dir + npm install + config.json)
        7. Tls             (self-signed | import | LE-stub)
        8. Firewall        (idempotent rules; MongoDB loopback if used)
        9. MeshcentralService (install + start service)
       10. Provisioning    (admin account + device groups + agent bundles)
       11. Share           (golden-VHDX dir + SMB share)
       12. Announcer       (NSSM-registered HttpListener)
       13. Verify          (health checks + setup-summary.txt)

    Reboot handling: none of the 13 stages require a forced reboot on
    a typical Windows 11 Pro host (no Hyper-V enable here). Still the
    orchestrator keeps the State-module scaffolding present so the
    pattern is consistent with the host's; an operator can use -Resume
    after a manual reboot or power event.

    On final success: Complete-ClusterRun clears the stage marker, sets
    Status=Completed, and unregisters the resume task.

    Exit codes: 0 Pass, 1 Fail, 2 RebootRequired (unused at present), 3 throw.

.PARAMETER ConfigPath
    Path to cluster-controller.json. Default: <repo>\config\cluster-controller.json
    or the example file.

.PARAMETER Resume / .PARAMETER StartFromStage
    See host orchestrator -- same semantics.

.PARAMETER DryRun / .PARAMETER NoRestart / .PARAMETER RegBase
    Same semantics as the host's.

.PARAMETER NodeMsiUrl / .PARAMETER NodeMsiSha256
    Forwarded to Stage 4 (Node).

.PARAMETER Pwsh7MsiUrl / .PARAMETER Pwsh7MsiSha256
    Forwarded to Stage 2 (Powershell7) for the MSI fallback path.

.PARAMETER MongoMsiUrl / .PARAMETER MongoMsiSha256
    Forwarded to Stage 5 (Db) when db.mode=mongodb.

.OUTPUTS
    pscustomobject @{ Overall; Stages[]; StartedAt; FinishedAt; ElapsedSeconds; RunId }
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [string]$ConfigPath,
    [Parameter(ParameterSetName = 'Resume')][switch]$Resume,
    [Parameter(ParameterSetName = 'StartFrom')]
    [ValidateRange(1,13)][int]$StartFromStage,
    [switch]$DryRun,
    [switch]$NoRestart,
    [string]$RegBase,

    [string]$NodeMsiUrl, [string]$NodeMsiSha256,
    [string]$Pwsh7MsiUrl, [string]$Pwsh7MsiSha256,
    [string]$MongoMsiUrl, [string]$MongoMsiSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- bootstrap ----------

$repoRoot     = Split-Path -Parent $PSScriptRoot
$libDir       = Join-Path $PSScriptRoot 'lib'
$stagesDir    = Join-Path $PSScriptRoot 'stages'
$orchVersion  = '0.1.0'

if (-not $ConfigPath) {
    $candidates = @(
        (Join-Path $repoRoot 'config\cluster-controller.json'),
        (Join-Path $repoRoot 'config\cluster-controller.example.json')
    )
    $ConfigPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

# Import libs first so each stage can rely on them.
foreach ($mod in 'Logging','State','Retry','HardwareDetect','Net','Pkg','Service','Firewall','Tls','Smb','Config','Announce') {
    $p = Join-Path $libDir "$mod.psm1"
    if (Test-Path -LiteralPath $p) {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module -Name $p -Force
    }
}

Initialize-ClusterLog -ConsoleLevel Info | Out-Null

# Dot-source the 13 stage scripts.
$stageScripts = @(
    Join-Path $stagesDir '01-Preflight.ps1'
    Join-Path $stagesDir '02-Powershell7.ps1'
    Join-Path $stagesDir '03-OpenSshClient.ps1'
    Join-Path $stagesDir '04-Node.ps1'
    Join-Path $stagesDir '05-Db.ps1'
    Join-Path $stagesDir '06-Meshcentral.ps1'
    Join-Path $stagesDir '07-Tls.ps1'
    Join-Path $stagesDir '08-Firewall.ps1'
    Join-Path $stagesDir '09-MeshcentralService.ps1'
    Join-Path $stagesDir '10-Provisioning.ps1'
    Join-Path $stagesDir '11-Share.ps1'
    Join-Path $stagesDir '12-Announcer.ps1'
    Join-Path $stagesDir '13-Verify.ps1'
)
foreach ($s in $stageScripts) {
    if (-not (Test-Path -LiteralPath $s)) { throw "Orchestrator: stage script '$s' not found." }
    . $s
}

# ---------- helpers ----------

function Read-ClusterControllerConfig {
    param([string]$Path)
    $r = Read-ControllerConfig -Path $Path
    if (-not $r.Ok) {
        Write-ClusterLog -Level Warn -Stage 'orchestrator' `
            -Message "Could not parse $Path; using defaults. Detail: $($r.Detail)"
    }
    return $r.Config
}

function Get-Plan {
    param(
        [pscustomobject]$Config, [string]$ConfigPath, [string]$OrchVersion,
        [switch]$DryRun,
        [string]$NodeMsiUrl, [string]$NodeMsiSha256,
        [string]$Pwsh7MsiUrl, [string]$Pwsh7MsiSha256,
        [string]$MongoMsiUrl, [string]$MongoMsiSha256
    )
    @(
        @{ Number = 1;  Name = 'Preflight';
           FunctionName = 'Invoke-PreflightStage'
           Splat = @{ Config = $Config; IgnoreFailures = [bool]$DryRun } }
        @{ Number = 2;  Name = 'Powershell7';
           FunctionName = 'Invoke-Powershell7Stage'
           Splat = @{ MsiUrl = $Pwsh7MsiUrl; MsiSha256 = $Pwsh7MsiSha256; DryRun = [bool]$DryRun } }
        @{ Number = 3;  Name = 'OpenSshClient';
           FunctionName = 'Invoke-OpenSshClientStage'
           Splat = @{ DryRun = [bool]$DryRun } }
        @{ Number = 4;  Name = 'Node';
           FunctionName = 'Invoke-NodeStage'
           Splat = @{ MsiUrl = $NodeMsiUrl; MsiSha256 = $NodeMsiSha256; DryRun = [bool]$DryRun } }
        @{ Number = 5;  Name = 'Db';
           FunctionName = 'Invoke-DbStage'
           Splat = @{ Config = $Config; MongoMsiUrl = $MongoMsiUrl; MongoMsiSha256 = $MongoMsiSha256; DryRun = [bool]$DryRun } }
        @{ Number = 6;  Name = 'Meshcentral';
           FunctionName = 'Invoke-MeshcentralStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 7;  Name = 'Tls';
           FunctionName = 'Invoke-TlsStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 8;  Name = 'Firewall';
           FunctionName = 'Invoke-FirewallStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 9;  Name = 'MeshcentralService';
           FunctionName = 'Invoke-MeshcentralServiceStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 10; Name = 'Provisioning';
           FunctionName = 'Invoke-ProvisioningStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 11; Name = 'Share';
           FunctionName = 'Invoke-ShareStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 12; Name = 'Announcer';
           FunctionName = 'Invoke-AnnouncerStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 13; Name = 'Verify';
           FunctionName = 'Invoke-VerifyStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
    )
}

# ---------- main ----------

function Invoke-ClusterControllerSetup {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$Resume,
        [int]$StartFromStage,
        [switch]$DryRun,
        [switch]$NoRestart,
        [string]$RegBase,
        [string]$NodeMsiUrl, [string]$NodeMsiSha256,
        [string]$Pwsh7MsiUrl, [string]$Pwsh7MsiSha256,
        [string]$MongoMsiUrl, [string]$MongoMsiSha256
    )

    Start-StageLog -Name 'orchestrator'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stageResults = New-Object System.Collections.Generic.List[pscustomobject]

    try {
        if (-not $RegBase) { $RegBase = $env:CLUSTERCTRL_REG_BASE }
        $cfg = Read-ClusterControllerConfig -Path $ConfigPath

        $startAt = 1
        if ($Resume) {
            $marker = Get-StageMarker -RegBase $RegBase
            if ($marker) {
                $startAt = $marker + 1
                Write-ClusterLog -Level Info -Stage 'orchestrator' `
                    -Message "Resume: prior marker=$marker, starting from stage $startAt."
            } else {
                Write-ClusterLog -Level Info -Stage 'orchestrator' -Message 'Resume requested but no prior stage marker; starting from stage 1.'
            }
        } elseif ($StartFromStage) {
            $startAt = $StartFromStage
            Write-ClusterLog -Level Info -Stage 'orchestrator' -Message "StartFromStage=$StartFromStage."
        }

        Set-ClusterRunVersion -Version $orchVersion -RegBase $RegBase
        Save-StageMarker -StageNumber $startAt -RegBase $RegBase
        $plan = Get-Plan -Config $cfg -ConfigPath $ConfigPath -OrchVersion $orchVersion `
                         -DryRun:$DryRun `
                         -NodeMsiUrl $NodeMsiUrl -NodeMsiSha256 $NodeMsiSha256 `
                         -Pwsh7MsiUrl $Pwsh7MsiUrl -Pwsh7MsiSha256 $Pwsh7MsiSha256 `
                         -MongoMsiUrl $MongoMsiUrl -MongoMsiSha256 $MongoMsiSha256

        foreach ($entry in $plan) {
            if ($entry.Number -lt $startAt) {
                Write-ClusterLog -Level Info -Stage 'orchestrator' `
                    -Message ("Stage {0:00} {1}: SKIPPED (already done in previous run)" -f $entry.Number, $entry.Name)
                $stageResults.Add([pscustomobject]@{
                    Number = $entry.Number; Name = $entry.Name; Overall = 'Skipped'; Detail = 'Skipped by resume / StartFromStage.'
                })
                continue
            }
            Save-StageMarker -StageNumber $entry.Number -RegBase $RegBase
            Start-StageLog -Name $entry.Name
            try {
                $cmd     = Get-Command -Name $entry.FunctionName -ErrorAction Stop
                $stageArgs = $entry.Splat
                $r = & $cmd @stageArgs
                $overall = if ($r -and $r.PSObject.Properties['Overall']) { "$($r.Overall)" } else { 'Pass' }
                $detail  = if ($r -and $r.PSObject.Properties['Detail'])  { "$($r.Detail)"  } elseif ($r) { 'see structured result' } else { '' }
                $stageResults.Add([pscustomobject]@{
                    Number = $entry.Number; Name = $entry.Name; Overall = $overall; Detail = $detail
                })
                Write-ClusterLog -Level Info -Stage 'orchestrator' `
                    -Message ("Stage {0:00} {1}: {2}" -f $entry.Number, $entry.Name, $overall)
                Stop-StageLog -Outcome $(if ($overall -eq 'Fail') { 'Failure' } elseif ($overall -eq 'Warn') { 'Warning' } else { 'Success' })

                if ($overall -eq 'Fail') {
                    $remed = if ($r -and $r.PSObject.Properties['Remediation']) { "$($r.Remediation)" } else { '' }
                    $msg   = "Stage $($entry.Number) $($entry.Name) failed: $detail $remed"
                    Write-ClusterLog -Level Error -Stage 'orchestrator' -Message $msg
                    Set-ClusterRunStatus -Status Failed -LastError $msg -RegBase $RegBase
                    $sw.Stop()
                    return New-OrchResult -Overall 'Fail' -StageResults $stageResults `
                                          -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
                }
            } catch {
                $exMsg = $_.Exception.Message
                Write-ClusterLog -Level Error -Stage 'orchestrator' `
                    -Message ("Stage {0:00} {1} threw: {2}" -f $entry.Number, $entry.Name, $exMsg) -ErrorRecord $_
                Stop-StageLog -Outcome Failure -Detail $exMsg
                $stageResults.Add([pscustomobject]@{
                    Number = $entry.Number; Name = $entry.Name; Overall = 'Fail'; Detail = "Threw: $exMsg"
                })
                Set-ClusterRunStatus -Status Failed -LastError "Stage $($entry.Number) $($entry.Name) threw: $exMsg" -RegBase $RegBase
                $sw.Stop()
                return New-OrchResult -Overall 'Fail' -StageResults $stageResults `
                                      -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
            }
        }

        $sw.Stop()
        Complete-ClusterRun -RegBase $RegBase
        Write-ClusterLog -Level Info -Stage 'orchestrator' -Message 'All 13 stages passed. Run complete.'
        return New-OrchResult -Overall 'Pass' -StageResults $stageResults `
                              -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
    } finally {
        if (Get-OpenStageName | Where-Object { $_ -eq 'orchestrator' }) { Stop-StageLog -Outcome Success | Out-Null }
    }
}

function New-OrchResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Overall,
        [Parameter(Mandatory)][System.Collections.Generic.List[pscustomobject]]$StageResults,
        [Parameter(Mandatory)][double]$ElapsedSeconds,
        [string]$RegBase
    )
    $status = Get-ClusterRunStatus -RegBase $RegBase
    return [pscustomobject]@{
        Overall        = $Overall
        Stages         = $StageResults.ToArray()
        StartedAt      = if ($status) { $status.StartedAt } else { $null }
        FinishedAt     = [datetime]::UtcNow.ToString('o')
        ElapsedSeconds = [math]::Round($ElapsedSeconds,2)
        RunId          = if ($status) { $status.RunId } else { $null }
    }
}

# Auto-run gate. Tests dot-source with CLUSTERCTRL_NOAUTORUN=1.
if ($env:CLUSTERCTRL_NOAUTORUN -ne '1') {
    $result = Invoke-ClusterControllerSetup `
        -ConfigPath $ConfigPath `
        -Resume:$Resume `
        -StartFromStage $StartFromStage `
        -DryRun:$DryRun `
        -NoRestart:$NoRestart `
        -RegBase $RegBase `
        -NodeMsiUrl $NodeMsiUrl -NodeMsiSha256 $NodeMsiSha256 `
        -Pwsh7MsiUrl $Pwsh7MsiUrl -Pwsh7MsiSha256 $Pwsh7MsiSha256 `
        -MongoMsiUrl $MongoMsiUrl -MongoMsiSha256 $MongoMsiSha256

    Write-Host ""
    Write-Host "===== Cluster Controller setup result =====" -ForegroundColor Cyan
    Write-Host ("Overall: {0}" -f $result.Overall) -ForegroundColor $(switch ($result.Overall) { 'Pass' {'Green'} 'Warn' {'Yellow'} 'Fail' {'Red'} default {'White'} })
    Write-Host ("RunId  : {0}" -f $result.RunId)
    Write-Host ("Elapsed: {0} s" -f $result.ElapsedSeconds)
    Write-Host ""
    $result.Stages | Format-Table -AutoSize Number, Name, Overall, Detail

    switch ($result.Overall) {
        'Pass' { exit 0 }
        'Warn' { exit 0 }
        'Fail' { exit 1 }
        default { exit 3 }
    }
}
