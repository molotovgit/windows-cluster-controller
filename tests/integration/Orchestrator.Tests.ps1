#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Integration test: orchestrator wiring + plan shape + per-stage routing.
# Every stage is stubbed via Get-Command pointer replacement so the test
# doesn't depend on real Win11 surfaces.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','State','Retry','HardwareDetect','Net','Pkg','Service','Firewall','Tls','Smb','Config','Announce') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERCTRL_NOAUTORUN        = '1'
    $script:testRegBase = "HKCU:\Software\ClusterController-orch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $env:CLUSTERCTRL_REG_BASE         = $script:testRegBase
    $env:CLUSTERCTRL_STATE_DIR        = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-state-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $env:CLUSTERCTRL_LOG_DIR          = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-log-"   + [guid]::NewGuid().ToString('N').Substring(0,8))

    . (Join-Path $repoRoot 'src\Invoke-ClusterControllerSetup.ps1')

    # Helper: replace every Invoke-*Stage function with a stub returning the
    # given Overall. Uses [scriptblock]::Create so each scriptblock has the
    # stage name baked in at definition time (avoiding foreach-closure pitfalls).
    function Set-AllStageStub {
        param([string]$StageOverall = 'Pass')
        $stages = @(
            'Invoke-PreflightStage','Invoke-Powershell7Stage','Invoke-OpenSshClientStage',
            'Invoke-NodeStage','Invoke-DbStage','Invoke-MeshcentralStage','Invoke-TlsStage',
            'Invoke-FirewallStage','Invoke-MeshcentralServiceStage','Invoke-ProvisioningStage',
            'Invoke-ShareStage','Invoke-AnnouncerStage','Invoke-VerifyStage'
        )
        foreach ($name in $stages) {
            $body = "param() [pscustomobject]@{ Overall = '$StageOverall'; Detail = 'stub $name' }"
            Set-Item -Path "function:Global:$name" -Value ([scriptblock]::Create($body))
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

Describe 'Invoke-ClusterControllerSetup' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:testRegBase) {
            Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs all 13 stages on the happy path and reports Overall=Pass' {
        Set-AllStageStub
        $r = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Stages.Count | Should -Be 13
        @($r.Stages | Where-Object Overall -eq 'Fail').Count | Should -Be 0
    }

    It 'preserves stage ordering 1..13 with the expected names' {
        Set-AllStageStub
        $r = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        ($r.Stages | ForEach-Object Number) | Should -Be @(1..13)
        ($r.Stages | ForEach-Object Name)   | Should -Be @('Preflight','Powershell7','OpenSshClient','Node','Db','Meshcentral','Tls','Firewall','MeshcentralService','Provisioning','Share','Announcer','Verify')
    }

    It 'resumes from the prior stage marker on -Resume' {
        Set-AllStageStub
        Save-StageMarker -StageNumber 6
        $r = Invoke-ClusterControllerSetup -DryRun -NoRestart -Resume 6>$null
        # Stages 1..6 should be Skipped, 7..13 should be present.
        $skipped = @($r.Stages | Where-Object Overall -eq 'Skipped' | ForEach-Object Number)
        $skipped | Should -Contain 1
        $skipped | Should -Contain 6
        $r.Overall | Should -Be 'Pass'
    }

    It 'StartFromStage skips lower-numbered stages' {
        Set-AllStageStub
        $r = Invoke-ClusterControllerSetup -DryRun -NoRestart -StartFromStage 10 6>$null
        $r.Stages | Where-Object Number -lt 10 | ForEach-Object { $_.Overall } | Should -BeIn @('Skipped')
        $r.Stages | Where-Object Number -ge 10 | ForEach-Object { $_.Overall } | Should -Not -Contain 'Skipped'
    }

    It 'records Status=Completed on success and gives back a Run identity' {
        Set-AllStageStub
        $r = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r.RunId | Should -Match '^[0-9a-f-]{36}$'
        (Get-ClusterRunStatus).Status | Should -Be 'Completed'
        Get-StageMarker | Should -BeNullOrEmpty
    }

    It 'gives back a fresh RunId on a back-to-back fresh run' {
        Set-AllStageStub
        $r1 = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r2 = Invoke-ClusterControllerSetup -DryRun -NoRestart 6>$null
        $r1.Overall | Should -Be 'Pass'
        $r2.Overall | Should -Be 'Pass'
        $r1.RunId   | Should -Not -Be $r2.RunId
    }
}
