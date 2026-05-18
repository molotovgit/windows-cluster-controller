<#
.SYNOPSIS
    Stage 8 -- Apply firewall rules: open MeshCentral 443 (and agent
    port if different) on the configured profiles; constrain MongoDB
    27017 to loopback. Uses lib/Firewall for idempotent create-or-replace.

.DESCRIPTION
    Rules are named with a 'ClusterController:' prefix so they're easy
    to spot in 'Get-NetFirewallRule' and easy to uninstall later.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Firewall','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

function Invoke-FirewallStage {
    [CmdletBinding()]
    param(
        $Config,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $httpsPort = [int]$cfg.controller.https_port
    $agentPort = [int]$cfg.controller.agent_port
    $annPort   = [int]$cfg.controller.announcer_port
    $samePort  = [bool]$cfg.meshcentral.agents_port_same_as_https
    $profiles  = @($cfg.firewall.profiles)
    $dbMode    = "$($cfg.db.mode)"
    $dbPort    = if ($cfg.db.mongodb.PSObject.Properties['port']) { [int]$cfg.db.mongodb.port } else { 27017 }

    _step 'Resolve firewall plan' 'Pass' "https=$httpsPort agent=$agentPort announcer=$annPort profiles=$($profiles -join ',') db=$dbMode"

    if ($DryRun) {
        _step 'Apply firewall rules' 'Skipped' '-DryRun: would have created or replaced rules'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: firewall' }
    }

    # Plan: each rule we want to ensure present.
    $plan = New-Object System.Collections.Generic.List[object]
    $plan.Add([pscustomobject]@{ Name = 'ClusterController: MeshCentral HTTPS'; Port = "$httpsPort"; Address = $null })
    if (-not $samePort -and $agentPort -ne $httpsPort) {
        $plan.Add([pscustomobject]@{ Name = 'ClusterController: MeshCentral Agent'; Port = "$agentPort"; Address = $null })
    }
    $plan.Add([pscustomobject]@{ Name = 'ClusterController: Announcer'; Port = "$annPort"; Address = $null })
    if ($dbMode -eq 'mongodb') {
        $plan.Add([pscustomobject]@{ Name = 'ClusterController: MongoDB Loopback'; Port = "$dbPort"; Address = '127.0.0.1' })
    }

    $anyFail = $false
    foreach ($r in $plan) {
        $result = New-IdempotentFirewallRule -Name $r.Name -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $r.Port -Profile $profiles -LocalAddress $r.Address
        if ($result.Ok) {
            _step "Rule '$($r.Name)'" 'Pass' "$($result.Action): $($result.Detail)"
        } else {
            $anyFail = $true
            _step "Rule '$($r.Name)'" 'Fail' "$($result.Action): $($result.Detail)"
        }
    }

    if ($anyFail) {
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = 'one or more firewall rules could not be created/replaced'
            Remediation = "Inspect 'Get-NetFirewallRule -DisplayName ClusterController:*' and the failed step's Detail; re-run as Administrator."
        }
    }

    [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "$($plan.Count) firewall rule(s) ensured" }
}
