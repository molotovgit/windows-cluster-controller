<#
.SYNOPSIS
    Idempotent Windows Firewall rule helpers for the controller setup.
    Used by Stage 15 (Firewall) to open MeshCentral 443, agent port, and
    constrain MongoDB to loopback.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultFirewallInvoker {
    @{
        GetRule = {
            param([string]$Name)
            try {
                $r = Get-NetFirewallRule -DisplayName $Name -ErrorAction Stop |
                     Select-Object -First 1
                if (-not $r) { return $null }
                $filter = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                $addr   = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    Name        = "$($r.DisplayName)"
                    Enabled     = "$($r.Enabled)"
                    Direction   = "$($r.Direction)"
                    Action      = "$($r.Action)"
                    Profile     = "$($r.Profile)"
                    Protocol    = if ($filter) { "$($filter.Protocol)" } else { $null }
                    LocalPort   = if ($filter) { "$($filter.LocalPort)" } else { $null }
                    LocalAddress= if ($addr)   { "$($addr.LocalAddress)" } else { $null }
                }
            } catch { $null = $_; $null }
        }
        NewRule = {
            param($Spec)
            $p = @{
                DisplayName = $Spec.Name
                Direction   = $Spec.Direction
                Action      = $Spec.Action
                Protocol    = $Spec.Protocol
                LocalPort   = $Spec.LocalPort
                Profile     = $Spec.Profile
                Enabled     = 'True'
            }
            if ($Spec.PSObject.Properties['LocalAddress'] -and $Spec.LocalAddress) {
                $p['LocalAddress'] = $Spec.LocalAddress
            }
            New-NetFirewallRule @p | Out-Null
        }
        RemoveRule = {
            param([string]$Name)
            Remove-NetFirewallRule -DisplayName $Name -ErrorAction Stop
        }
    }
}

$script:FirewallInvokers = Get-DefaultFirewallInvoker

function Confirm-FirewallTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-FirewallInvoker / Reset-FirewallInvoker."
    }
}

function Set-FirewallInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GetRule','NewRule','RemoveRule')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-FirewallTestSeamAllowed
    $script:FirewallInvokers[$Name] = $ScriptBlock
}

function Reset-FirewallInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-FirewallTestSeamAllowed
    $script:FirewallInvokers = Get-DefaultFirewallInvoker
}

function Test-FirewallRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    [bool](& $script:FirewallInvokers.GetRule $Name)
}

function New-IdempotentFirewallRule {
    <#
    .SYNOPSIS
        Create a firewall rule, or replace it if the existing one's spec
        differs. Returns @{Ok; Action ('created'|'replaced'|'unchanged');
        Detail}.

    .DESCRIPTION
        The 'replaced' path is REMOVE + ADD; this is intentional and
        avoids the messy Set-NetFirewallRule semantics around changing
        protocol or port lists.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent rule creation; ShouldProcess would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Inbound','Outbound')]
        [string]$Direction = 'Inbound',
        [Parameter(Mandatory)]
        [ValidateSet('Allow','Block')]
        [string]$Action = 'Allow',
        [Parameter(Mandatory)]
        [ValidateSet('TCP','UDP')]
        [string]$Protocol,
        [Parameter(Mandatory)][string]$LocalPort,
        [string[]]$Profile = @('Domain','Private'),
        [string]$LocalAddress
    )

    $profileStr = ($Profile -join ',')
    $spec = [pscustomobject]@{
        Name = $Name; Direction = $Direction; Action = $Action
        Protocol = $Protocol; LocalPort = $LocalPort; Profile = $profileStr
        LocalAddress = $LocalAddress
    }

    $existing = & $script:FirewallInvokers.GetRule $Name
    if ($existing) {
        $same = ($existing.Direction -eq $Direction) -and
                ($existing.Action    -eq $Action) -and
                ("$($existing.Protocol)"  -eq $Protocol) -and
                ("$($existing.LocalPort)" -eq $LocalPort) -and
                ("$($existing.Profile)"   -eq $profileStr) -and
                ((-not $LocalAddress) -or ("$($existing.LocalAddress)" -eq $LocalAddress))
        if ($same) {
            return [pscustomobject]@{ Ok = $true; Action = 'unchanged'; Detail = "rule '$Name' already matches" }
        }
        try { & $script:FirewallInvokers.RemoveRule $Name }
        catch { return [pscustomobject]@{ Ok = $false; Action = 'replace-failed'; Detail = "remove failed: $($_.Exception.Message)" } }
    }

    try {
        & $script:FirewallInvokers.NewRule $spec
    } catch {
        return [pscustomobject]@{ Ok = $false; Action = 'create-failed'; Detail = "New-NetFirewallRule failed: $($_.Exception.Message)" }
    }

    [pscustomobject]@{
        Ok     = $true
        Action = if ($existing) { 'replaced' } else { 'created' }
        Detail = "rule '$Name' active ($Direction $Protocol/$LocalPort, profiles=$profileStr)"
    }
}

function Remove-IdempotentFirewallRule {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent rule removal; ShouldProcess would break unattended setup.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $existing = & $script:FirewallInvokers.GetRule $Name
    if (-not $existing) {
        return [pscustomobject]@{ Ok = $true; Action = 'absent'; Detail = "rule '$Name' was not present" }
    }
    try {
        & $script:FirewallInvokers.RemoveRule $Name
        [pscustomobject]@{ Ok = $true; Action = 'removed'; Detail = "rule '$Name' removed" }
    } catch {
        [pscustomobject]@{ Ok = $false; Action = 'remove-failed'; Detail = "$($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function `
    Test-FirewallRule, New-IdempotentFirewallRule, Remove-IdempotentFirewallRule
