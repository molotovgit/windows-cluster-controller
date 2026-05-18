#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Cross-project contract test: the controller's Announcer payload must be
# parseable by the host's discovery code AND the host's HTTPS-endpoint
# probe must accept what MeshCentral would serve.
#
# This test imports BOTH the controller's Announce module and the host's
# Discovery module (when the host repo is available alongside) and proves:
#   1. The controller's New-AnnouncerPayload emits the JSON shape the
#      host's Discovery contract expects (type='cluster-controller',
#      hostname, https_port, agent_port).
#   2. The host's Test-ControllerEndpoint correctly validates a MeshCentral-
#      branded HTTPS response (the marker check the controller's TLS stage
#      sets up).
#   3. When the host repo isn't present on the same machine, the controller-
#      side contract still passes in isolation.

# Discovery-time check: Pester 5 evaluates -Skip parameters at discovery, before
# BeforeAll runs, so the "is the host repo co-located?" probe has to happen here.
$script:HostRepoFound = $false
$ctrlRootDisc = (Resolve-Path "$PSScriptRoot\..\..").Path
$hostCand     = Join-Path $ctrlRootDisc '..\windows-cluster-host'
if (Test-Path -LiteralPath (Join-Path $hostCand 'src\lib\Discovery.psm1')) {
    $script:HostRepoFound = $true
}

BeforeAll {
    $script:ctrlRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $hostCandidate   = Join-Path $script:ctrlRoot '..\windows-cluster-host'
    $script:hostRoot = if (Test-Path -LiteralPath $hostCandidate) { (Resolve-Path $hostCandidate).Path } else { $null }

    Get-Module Announce  | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:ctrlRoot 'src\lib\Announce.psm1') -Force

    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'    # required for the host's Discovery test seam
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:hostAvailable = $false
    if ($script:hostRoot) {
        $disc = Join-Path $script:hostRoot 'src\lib\Discovery.psm1'
        if (Test-Path -LiteralPath $disc) {
            Get-Module Discovery | Remove-Module -Force -ErrorAction SilentlyContinue
            Import-Module $disc -Force
            $script:hostAvailable = $true
        }
    }
}

AfterAll {
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
}

Describe 'Controller announcer payload contract' {

    It 'emits the keys the host discovery would consume' {
        $p = New-AnnouncerPayload -Hostname 'controller.lan' -LanIp '192.168.1.7' -HttpsPort 443 -AgentPort 4433 -Version '0.1.0'
        $p.PSObject.Properties.Name | Should -Contain 'type'
        $p.PSObject.Properties.Name | Should -Contain 'hostname'
        $p.PSObject.Properties.Name | Should -Contain 'lan_ip'
        $p.PSObject.Properties.Name | Should -Contain 'https_port'
        $p.PSObject.Properties.Name | Should -Contain 'agent_port'
        $p.type | Should -Be 'cluster-controller'
    }

    It 'round-trips through JSON without losing typed values' {
        $orig = New-AnnouncerPayload -Hostname 'x.lan' -LanIp '10.0.0.7' -HttpsPort 443 -AgentPort 4433
        $json = $orig | ConvertTo-Json -Depth 4
        $rt   = $json | ConvertFrom-Json
        $rt.type       | Should -Be $orig.type
        $rt.hostname   | Should -Be $orig.hostname
        $rt.lan_ip     | Should -Be $orig.lan_ip
        [int]$rt.https_port | Should -Be ([int]$orig.https_port)
        [int]$rt.agent_port | Should -Be ([int]$orig.agent_port)
    }
}

Describe 'Host Discovery accepts the controller (when host repo is co-located)' {

    It 'host Discovery Test-ControllerEndpoint accepts a MeshCentral-branded HTTPS response' -Skip:(-not $script:HostRepoFound) {
        & (Get-Module Discovery) {
            Set-DiscoveryInvoker -Name TestTcp   -ScriptBlock { param($a,$p,$t) $true }
            Set-DiscoveryInvoker -Name HttpProbe -ScriptBlock {
                param($u,$t) [pscustomobject]@{ Status = 200; Body = '<html><title>MeshCentral</title></html>' }
            }
        }
        $r = Test-ControllerEndpoint -Address '10.0.0.7' -Port 443
        $r.Ok | Should -BeTrue
        $r.Url | Should -Match '^https://10\.0\.0\.7:443/'
    }

    It 'host Discovery rejects a captive-portal HTTPS response (no MeshCentral marker)' -Skip:(-not $script:HostRepoFound) {
        & (Get-Module Discovery) {
            Set-DiscoveryInvoker -Name TestTcp   -ScriptBlock { param($a,$p,$t) $true }
            Set-DiscoveryInvoker -Name HttpProbe -ScriptBlock {
                param($u,$t) [pscustomobject]@{ Status = 200; Body = '<html><title>Captive Portal</title></html>' }
            }
        }
        $r = Test-ControllerEndpoint -Address '10.0.0.7' -Port 443
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'marker-missing'
    }

    It 'host Discovery rejects a target with no HTTPS listener' -Skip:(-not $script:HostRepoFound) {
        & (Get-Module Discovery) {
            Set-DiscoveryInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $false }
        }
        $r = Test-ControllerEndpoint -Address '10.0.0.99' -Port 443
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'tcp-closed'
    }
}

Describe 'End-to-end contract: announcer JSON drives controller-side discovery' {

    It 'a controller emitting the canonical payload produces values a host can connect to' -Skip:(-not $script:HostRepoFound) {
        $payload = New-AnnouncerPayload -Hostname 'controller.lan' -LanIp '192.168.1.7' -HttpsPort 443 -AgentPort 4433
        $payloadJson = $payload | ConvertTo-Json -Depth 4
        $parsed = $payloadJson | ConvertFrom-Json
        # Simulate what the host's Find-Controller would do: use lan_ip + https_port,
        # then validate via Test-ControllerEndpoint (with a MeshCentral-branded stub).
        & (Get-Module Discovery) {
            Set-DiscoveryInvoker -Name TestTcp   -ScriptBlock { param($a,$p,$t) $true }
            Set-DiscoveryInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = 'MeshCentral' } }
        }
        $r = Test-ControllerEndpoint -Address ([string]$parsed.lan_ip) -Port ([int]$parsed.https_port)
        $r.Ok | Should -BeTrue
    }
}
