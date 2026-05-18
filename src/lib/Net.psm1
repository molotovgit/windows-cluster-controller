<#
.SYNOPSIS
    Network helpers for the windows-cluster-controller setup script: port
    probes, free-port discovery, DNS resolution, local-IP listing, default
    gateway. Used by Firewall + service-health checks.

.DESCRIPTION
    Every function delegates I/O through a hashtable of "invoker" closures
    so unit tests can stub the network surface without touching real sockets
    or DNS. Production callers get real System.Net.Sockets / Resolve-DnsName.

    Test seams are gated by CLUSTERCTRL_ALLOW_TEST_SEAMS=1 -- so production
    deployments cannot accidentally swap them.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- invoker seam ----------

function Get-DefaultNetInvoker {
    @{
        # TCP connect to (address, port) with timeoutMs. Returns $true if accepting.
        TestTcp = {
            param([string]$Address, [int]$Port, [int]$TimeoutMs = 750)
            if (-not $Address) { return $false }
            $client = $null
            try {
                $client = [System.Net.Sockets.TcpClient]::new()
                $iar    = $client.BeginConnect($Address, $Port, $null, $null)
                $ok     = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
                if (-not $ok) { return $false }
                $client.EndConnect($iar)
                return $true
            } catch { return $false }
            finally { if ($client) { try { $client.Close() } catch { $null = $_ } } }
        }
        # Probe an HTTP/HTTPS URL with a timeout. Returns @{Status; Body} or $null.
        HttpProbe = {
            param([string]$Url, [int]$TimeoutMs = 2500)
            try {
                $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec ([math]::Ceiling($TimeoutMs / 1000)) -SkipCertificateCheck -ErrorAction Stop
                return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = "$($resp.Content)" }
            } catch {
                $null = $_
                return $null
            }
        }
        Resolve = {
            param([string]$Name)
            try {
                $r = Resolve-DnsName -Name $Name -ErrorAction Stop -DnsOnly -QuickTimeout -Type A |
                     Where-Object { $_.Type -in 'A','AAAA' -and $_.IPAddress } |
                     Select-Object -First 1
                if ($r) { return "$($r.IPAddress)" }
                return $null
            } catch { $null = $_; return $null }
        }
        LocalIPv4 = {
            try {
                Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
                    Select-Object IPAddress, PrefixLength, InterfaceAlias
            } catch { $null = $_; @() }
        }
        DefaultGateway = {
            try {
                $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                     Sort-Object -Property RouteMetric |
                     Select-Object -First 1
                if ($r) { return "$($r.NextHop)" }
                return $null
            } catch { $null = $_; return $null }
        }
    }
}

$script:NetInvokers = Get-DefaultNetInvoker

function Confirm-NetTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-NetInvoker / Reset-NetInvoker."
    }
}

function Set-NetInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('TestTcp','HttpProbe','Resolve','LocalIPv4','DefaultGateway')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-NetTestSeamAllowed
    $script:NetInvokers[$Name] = $ScriptBlock
}

function Reset-NetInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-NetTestSeamAllowed
    $script:NetInvokers = Get-DefaultNetInvoker
}

# ---------- public ----------

function Test-NetPortInUse {
    <#
    .SYNOPSIS Return $true if something is already listening on (Address, Port).
    .DESCRIPTION
        For "is this port available?" checks before starting MeshCentral on 443
        or MongoDB on 27017. Default address is 127.0.0.1 (loopback) since the
        controller binds its services there or to 0.0.0.0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$Address = '127.0.0.1',
        [int]$TimeoutMs = 500
    )
    return [bool](& $script:NetInvokers.TestTcp $Address $Port $TimeoutMs)
}

function Test-NetTcpOpen {
    <#
    .SYNOPSIS Return $true if a remote TCP endpoint accepts a connection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 1500
    )
    return [bool](& $script:NetInvokers.TestTcp $Address $Port $TimeoutMs)
}

function Find-NetFreePort {
    <#
    .SYNOPSIS
        Scan -CandidatePorts in order, return the first one not in use on
        -Address (default loopback). Returns $null if none free.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int[]]$CandidatePorts,
        [string]$Address = '127.0.0.1',
        [int]$TimeoutMs = 300
    )
    foreach ($p in $CandidatePorts) {
        if (-not (& $script:NetInvokers.TestTcp $Address $p $TimeoutMs)) { return $p }
    }
    return $null
}

function Test-NetHttpReachable {
    <#
    .SYNOPSIS
        HTTP/HTTPS probe with optional content matcher. Returns @{Ok; Status; Body}.

    .PARAMETER ExpectStatus
        Required HTTP status code (default 200). Pass 0 to accept any 2xx.

    .PARAMETER ExpectMatch
        Optional regex the body must match. Skipped if empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutMs = 2500,
        [int]$ExpectStatus = 200,
        [string]$ExpectMatch
    )
    $r = & $script:NetInvokers.HttpProbe $Url $TimeoutMs
    if (-not $r) { return [pscustomobject]@{ Ok=$false; Status=0; Body=''; Reason='no-response' } }
    $statusOk = if ($ExpectStatus -eq 0) { $r.Status -ge 200 -and $r.Status -lt 300 } else { $r.Status -eq $ExpectStatus }
    if (-not $statusOk) {
        return [pscustomobject]@{ Ok=$false; Status=$r.Status; Body=$r.Body; Reason="status=$($r.Status)" }
    }
    if ($ExpectMatch -and $r.Body -notmatch $ExpectMatch) {
        return [pscustomobject]@{ Ok=$false; Status=$r.Status; Body=$r.Body; Reason="body did not match /$ExpectMatch/" }
    }
    return [pscustomobject]@{ Ok=$true; Status=$r.Status; Body=$r.Body; Reason='' }
}

function Resolve-NetHostName {
    <#
    .SYNOPSIS DNS A/AAAA lookup; returns the first IPv4/IPv6 or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return & $script:NetInvokers.Resolve $Name
}

function Get-NetLocalIPv4 {
    <#
    .SYNOPSIS Return IPv4 addresses bound on this PC (excluding APIPA + loopback).
    #>
    [CmdletBinding()]
    param()
    return @(& $script:NetInvokers.LocalIPv4)
}

function Get-NetDefaultGateway {
    <#
    .SYNOPSIS Return the next-hop of the lowest-metric default route, or $null.
    #>
    [CmdletBinding()]
    param()
    return & $script:NetInvokers.DefaultGateway
}

Export-ModuleMember -Function `
    Test-NetPortInUse, Test-NetTcpOpen, Find-NetFreePort, `
    Test-NetHttpReachable, Resolve-NetHostName, `
    Get-NetLocalIPv4, Get-NetDefaultGateway
