<#
.SYNOPSIS
    Stage 13 -- Verify everything is running, then write a human-readable
    setup-summary.txt for the operator.

.DESCRIPTION
    Combines HealthVerify (PR 38) + OperatorSummary (PR 39).

    Checks:
      1. MeshCentral service Running.
      2. (when db.mode=mongodb) MongoDB service Running + 27017 listening loopback.
      3. ClusterAnnouncer service Running + announcer_port listening.
      4. HTTPS endpoint https://localhost:<port>/ responds.
      5. SMB share present.
      6. Golden VHDX dir contains >= 1 .vhdx (Warn, not Fail, if empty).

    Writes a setup-summary.txt summarising URL, admin user, group
    names, share path, next-step instructions for host setup.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Service','Net','Smb','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

function Get-DefaultVerifyInvoker {
    @{
        GetSmbShare = {
            param([string]$Name)
            try {
                $s = Get-SmbShare -Name $Name -ErrorAction Stop
                [pscustomobject]@{ Found = $true; Path = "$($s.Path)" }
            } catch { $null = $_; [pscustomobject]@{ Found = $false; Path = $null } }
        }
        ListDir = {
            param([string]$Path, [string]$Filter)
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            @(Get-ChildItem -Path $Path -Filter $Filter -File -ErrorAction SilentlyContinue)
        }
        WriteSummary = {
            param([string]$Path, [string]$Body)
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($Path, $Body, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

$script:VerifyInvokers = Get-DefaultVerifyInvoker

function Confirm-VerifyTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-VerifyInvoker."
    }
}

function Set-VerifyInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GetSmbShare','ListDir','WriteSummary')][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-VerifyTestSeamAllowed
    $script:VerifyInvokers[$Name] = $ScriptBlock
}

function Reset-VerifyInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-VerifyTestSeamAllowed
    $script:VerifyInvokers = Get-DefaultVerifyInvoker
}

function Format-ControllerSummary {
    param(
        [pscustomobject[]]$Checks,
        [string]$Overall,
        [string]$Url,
        [string]$AdminUser,
        [string]$HostsGroup,
        [string]$VmsGroup,
        [string]$SharePath,
        [string]$ShareName,
        [int]$VhdxCount,
        [hashtable]$Meta
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Cluster Controller setup summary")
    [void]$sb.AppendLine("===============================")
    [void]$sb.AppendLine("Generated:  $([datetime]::UtcNow.ToString('o'))")
    [void]$sb.AppendLine("Overall:    $Overall")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("MeshCentral URL:    $Url")
    [void]$sb.AppendLine("Admin user:         $AdminUser")
    [void]$sb.AppendLine("Device groups:      $HostsGroup (hosts), $VmsGroup (vms)")
    [void]$sb.AppendLine("SMB share:          \\<controller-hostname>\$ShareName -> $SharePath")
    [void]$sb.AppendLine("Golden VHDX files:  $VhdxCount under $SharePath\vhdx")
    if ($Meta) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Run metadata:")
        foreach ($k in ($Meta.Keys | Sort-Object)) {
            [void]$sb.AppendLine(("  {0,-12} {1}" -f $k, $Meta[$k]))
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Checks:")
    foreach ($c in $Checks) {
        [void]$sb.AppendLine(("  [{0,-4}] {1}: {2}" -f $c.Status, $c.Name, $c.Detail))
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Next steps on each host PC:")
    [void]$sb.AppendLine("  1. Drop a golden Win11 Pro VHDX into $SharePath\vhdx if not already present.")
    [void]$sb.AppendLine("  2. Open an elevated pwsh on each host PC and run windows-cluster-host install.ps1.")
    [void]$sb.AppendLine("  3. Watch hosts appear in MeshCentral at $Url under the '$HostsGroup' group.")
    return $sb.ToString()
}

function Invoke-VerifyStage {
    [CmdletBinding()]
    param(
        $Config,
        [string]$SummaryPath,
        [hashtable]$Meta,
        [switch]$DryRun
    )

    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $hostname  = "$($cfg.controller.hostname)"
    $httpsPort = [int]$cfg.controller.https_port
    $annPort   = [int]$cfg.controller.announcer_port
    $dbMode    = "$($cfg.db.mode)"
    $dbBind    = if ($cfg.db.mongodb.PSObject.Properties['bind']) { "$($cfg.db.mongodb.bind)" } else { '127.0.0.1' }
    $dbPort    = if ($cfg.db.mongodb.PSObject.Properties['port']) { [int]$cfg.db.mongodb.port }  else { 27017 }
    $shareName = "$($cfg.share.name)"
    $shareRoot = Expand-ConfigPath -Value "$($cfg.share.root)"
    $vhdxDir   = Join-Path $shareRoot "$($cfg.share.vhdx_subdir)"
    $hostsGrp  = "$($cfg.meshcentral.device_groups.hosts)"
    $vmsGrp    = "$($cfg.meshcentral.device_groups.vms)"
    $adminUser = "$($cfg.admin.username)"
    if (-not $SummaryPath) {
        $progData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
        $SummaryPath = Join-Path $progData 'ClusterController\setup-summary.txt'
    }
    $url = "https://${hostname}:${httpsPort}/"

    $checks = New-Object System.Collections.Generic.List[object]
    function _check($n,$s,$d) { $checks.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    if ($DryRun) {
        _check 'Verify (DryRun)' 'Pass' '-DryRun: skipping real health checks; orchestrator-level dry-run is enough'
        return [pscustomobject]@{
            Overall     = 'Pass'
            Checks      = $checks.ToArray()
            Summary     = ''
            SummaryPath = $SummaryPath
            PassCount   = 1
            WarnCount   = 0
            FailCount   = 0
        }
    }

    # 1. MeshCentral service.
    $mc = Get-ServiceInfo -Name 'MeshCentral'
    if ($mc.Found -and $mc.Status -eq 'Running') {
        _check 'MeshCentral service' 'Pass' "Running ($($mc.StartType))"
    } elseif ($mc.Found) {
        _check 'MeshCentral service' 'Fail' "state=$($mc.Status); expected Running"
    } else {
        _check 'MeshCentral service' 'Fail' 'service not installed -- Stage 9 did not complete'
    }

    # 2. MongoDB (only when configured).
    if ($dbMode -eq 'mongodb') {
        $db = Get-ServiceInfo -Name 'MongoDB'
        if ($db.Found -and $db.Status -eq 'Running') {
            _check 'MongoDB service' 'Pass' "Running ($($db.StartType))"
        } else {
            _check 'MongoDB service' 'Fail' "state=$($db.Status)"
        }
        if (Test-NetPortInUse -Port $dbPort -Address $dbBind -TimeoutMs 1000) {
            _check 'MongoDB port' 'Pass' "${dbBind}:${dbPort} accepting connections"
        } else {
            _check 'MongoDB port' 'Warn' "${dbBind}:${dbPort} did not respond"
        }
    }

    # 3. Announcer.
    $ann = Get-ServiceInfo -Name 'ClusterAnnouncer'
    if ($ann.Found -and $ann.Status -eq 'Running') {
        _check 'ClusterAnnouncer service' 'Pass' "Running ($($ann.StartType))"
    } else {
        _check 'ClusterAnnouncer service' 'Fail' "state=$($ann.Status)"
    }
    if (Test-NetPortInUse -Port $annPort -Address '127.0.0.1' -TimeoutMs 1000) {
        _check "Announcer port $annPort" 'Pass' 'listening on 127.0.0.1'
    } else {
        _check "Announcer port $annPort" 'Warn' 'did not respond yet'
    }

    # 4. HTTPS endpoint.
    $http = Test-NetHttpReachable -Url "https://localhost:$httpsPort/" -TimeoutMs 3000 -ExpectStatus 0
    if ($http.Ok) {
        _check 'HTTPS endpoint' 'Pass' "https://localhost:$httpsPort/ responded $($http.Status)"
    } else {
        _check 'HTTPS endpoint' 'Warn' "did not respond: $($http.Reason)"
    }

    # 5. SMB share.
    $sm = & $script:VerifyInvokers.GetSmbShare $shareName
    if ($sm.Found) {
        _check 'SMB share' 'Pass' "$shareName -> $($sm.Path)"
    } else {
        _check 'SMB share' 'Fail' "share '$shareName' not present"
    }

    # 6. Golden VHDX (Warn-only).
    $vhdx = @(& $script:VerifyInvokers.ListDir $vhdxDir '*.vhdx')
    if ($vhdx.Count -ge 1) {
        _check 'Golden VHDX' 'Pass' "$($vhdx.Count) file(s) under $vhdxDir"
    } else {
        _check 'Golden VHDX' 'Warn' "no VHDX in $vhdxDir; host PCs cannot deploy VMs until you drop one in"
    }

    # ---- summary ----
    $failCount = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
    $warnCount = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
    $passCount = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
    $overall = if ($failCount -gt 0) { 'Fail' } elseif ($warnCount -gt 0) { 'Warn' } else { 'Pass' }

    $summary = Format-ControllerSummary `
        -Checks $checks.ToArray() -Overall $overall -Url $url `
        -AdminUser $adminUser -HostsGroup $hostsGrp -VmsGroup $vmsGrp `
        -SharePath $shareRoot -ShareName $shareName -VhdxCount $vhdx.Count -Meta $Meta

    if (-not $DryRun) {
        try {
            & $script:VerifyInvokers.WriteSummary $SummaryPath $summary
        } catch { $null = $_ }
    }

    [pscustomobject]@{
        Overall     = $overall
        Checks      = $checks.ToArray()
        Summary     = $summary
        SummaryPath = $SummaryPath
        PassCount   = $passCount
        WarnCount   = $warnCount
        FailCount   = $failCount
    }
}
