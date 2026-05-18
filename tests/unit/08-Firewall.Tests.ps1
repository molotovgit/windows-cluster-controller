#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Firewall','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fw-stage-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\08-Firewall.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-FirewallStage' {

    BeforeEach { & (Get-Module Firewall) { Reset-FirewallInvoker } }

    It 'returns Pass via -DryRun' {
        $r = Invoke-FirewallStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'creates rules for HTTPS + Announcer in NeDB mode (no MongoDB rule)' {
        & (Get-Module Firewall) {
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) $null }
            Set-FirewallInvoker -Name NewRule -ScriptBlock { param($s) }
        }
        $cfg = Get-ControllerConfigDefault   # nedb default
        $r = Invoke-FirewallStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Pass'
        $rules = $r.Steps | Where-Object { $_.Name -like "Rule '*'" } | ForEach-Object { $_.Name -replace "^Rule '","" -replace "'$","" }
        $rules | Should -Contain 'ClusterController: MeshCentral HTTPS'
        $rules | Should -Contain 'ClusterController: Announcer'
        $rules | Should -Not -Contain 'ClusterController: MongoDB Loopback'
    }

    It 'adds a loopback-only MongoDB rule when db.mode=mongodb' {
        & (Get-Module Firewall) {
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) $null }
            Set-FirewallInvoker -Name NewRule -ScriptBlock { param($s) }
        }
        $cfg = Get-ControllerConfigDefault
        $cfg.db.mode = 'mongodb'
        $r = Invoke-FirewallStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Pass'
        $rules = $r.Steps | Where-Object Name -like "Rule '*'" | ForEach-Object { $_.Name -replace "^Rule '","" -replace "'$","" }
        $rules | Should -Contain 'ClusterController: MongoDB Loopback'
    }

    It 'returns Fail when any rule cannot be created' {
        & (Get-Module Firewall) {
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) $null }
            Set-FirewallInvoker -Name NewRule -ScriptBlock { param($s) throw 'access denied' }
        }
        $cfg = Get-ControllerConfigDefault
        $r = Invoke-FirewallStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
    }
}
