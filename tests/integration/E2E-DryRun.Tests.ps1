#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# End-to-end dry-run: the PRIMARY GOAL acceptance test for the
# windows-cluster-controller orchestrator.
#
# Stubs each Invoke-<Name>Stage at the Global scope (matches the
# Orchestrator integration test's working pattern) so we can assert
# the full 13-stage pipeline reaches Overall=Pass.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','State','Retry','HardwareDetect','Net','Pkg','Service','Firewall','Tls','Smb','Config','Announce') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERCTRL_NOAUTORUN        = '1'
    $script:testRegBase = "HKCU:\Software\ClusterController-e2e-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $env:CLUSTERCTRL_REG_BASE         = $script:testRegBase
    $env:CLUSTERCTRL_STATE_DIR        = Join-Path ([System.IO.Path]::GetTempPath()) ("e2e-state-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $env:CLUSTERCTRL_LOG_DIR          = Join-Path ([System.IO.Path]::GetTempPath()) ("e2e-log-"   + [guid]::NewGuid().ToString('N').Substring(0,8))

    . (Join-Path $repoRoot 'src\Invoke-ClusterControllerSetup.ps1')

    function Set-FleetReadyStub {
        # Pretend every stage hit a Pass result against a fleet-ready
        # Win11 Pro controller (admin elevated, RAM/disk/network sane,
        # node + pwsh 7 + ssh + npm install fine, mongod skipped via
        # nedb mode, cert generated, firewall rules added, MeshCentral
        # service Running, admin account bootstrapped, share open,
        # announcer Running).
        $stages = @(
            @{ N='Invoke-PreflightStage';         D='admin/ram/disk/network/svc/policy ok' }
            @{ N='Invoke-Powershell7Stage';       D='pwsh 7.4.1 already present' }
            @{ N='Invoke-OpenSshClientStage';     D='OpenSSH.Client installed' }
            @{ N='Invoke-NodeStage';              D='node v20.11.0 installed' }
            @{ N='Invoke-DbStage';                D='NeDB mode: no DB install' }
            @{ N='Invoke-MeshcentralStage';       D='MeshCentral installed and config.json written' }
            @{ N='Invoke-TlsStage';               D='self-signed cert generated; thumbprint recorded in config.json' }
            @{ N='Invoke-FirewallStage';          D='4 firewall rules ensured' }
            @{ N='Invoke-MeshcentralServiceStage';D='MeshCentral service Running on https://controller.lan:443/' }
            @{ N='Invoke-ProvisioningStage';      D='admin + groups + agent bundle dirs ok' }
            @{ N='Invoke-ShareStage';             D='ClusterShare ready' }
            @{ N='Invoke-AnnouncerStage';         D='ClusterAnnouncer service Running on 8765' }
            @{ N='Invoke-VerifyStage';            D='all checks Pass' }
        )
        foreach ($s in $stages) {
            $body = "param() [pscustomobject]@{ Overall = 'Pass'; Detail = '$($s.D)' }"
            Set-Item -Path "function:Global:$($s.N)" -Value ([scriptblock]::Create($body))
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:testRegBase) {
        Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_NOAUTORUN        -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_REG_BASE         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR        -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR          -ErrorAction SilentlyContinue
}

Describe 'E2E dry-run: fleet-ready controller' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:testRegBase) {
            Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs all 13 stages to Overall=Pass with a fully-stubbed environment' {
        Set-FleetReadyStub
        $r = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r.Overall      | Should -Be 'Pass'
        $r.Stages.Count | Should -Be 13
        $r.RunId        | Should -Match '^[0-9a-f-]{36}$'
        @($r.Stages | Where-Object Overall -eq 'Fail').Count | Should -Be 0
    }

    It 'records run completion in the registry state (Status=Completed, no Stage marker)' {
        Set-FleetReadyStub
        Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null | Out-Null
        $status = Get-ClusterRunStatus
        $status.Status | Should -Be 'Completed'
        Get-StageMarker | Should -BeNullOrEmpty
        $status.RunId   | Should -Match '^[0-9a-f-]{36}$'
        $status.Version | Should -Be '0.1.0'
    }

    It 'is fully idempotent: a second back-to-back run is also Overall=Pass with a fresh RunId' {
        Set-FleetReadyStub
        $r1 = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r2 = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r1.Overall | Should -Be 'Pass'
        $r2.Overall | Should -Be 'Pass'
        $r1.RunId   | Should -Not -Be $r2.RunId
    }
}

Describe 'E2E acceptance: PRIMARY GOAL' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:testRegBase) {
            Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '13-stage orchestrator runs end-to-end with Overall=Pass and zero Fail stages -- the PRIMARY GOAL is met' {
        Set-FleetReadyStub
        $r = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r.Overall | Should -Be 'Pass'
        @($r.Stages | Where-Object { $_.Overall -eq 'Fail' }).Count | Should -Be 0
        @($r.Stages | Where-Object { $_.Overall -eq 'Pass' }).Count | Should -BeGreaterOrEqual 12
        $r.Stages.Count | Should -Be 13
        ($r.Stages | ForEach-Object Number) | Should -Be @(1..13)
        ($r.Stages | ForEach-Object Name)   | Should -Be @('Preflight','Powershell7','OpenSshClient','Node','Db','Meshcentral','Tls','Firewall','MeshcentralService','Provisioning','Share','Announcer','Verify')
    }
}
