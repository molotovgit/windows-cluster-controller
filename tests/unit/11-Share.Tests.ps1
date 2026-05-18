#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Smb','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("share-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\11-Share.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShareStage' {

    BeforeEach {
        Reset-ShareInvoker
        & (Get-Module Smb) { Reset-SmbInvoker }
    }

    It 'returns Pass via -DryRun' {
        $r = Invoke-ShareStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'returns Warn when no VHDX files are present (operator step)' {
        Set-ShareInvoker -Name EnsureDir -ScriptBlock { param($p) }
        Set-ShareInvoker -Name ListDir   -ScriptBlock { param($p,$f) @() }
        & (Get-Module Smb) {
            Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Path=$null; Description=$null } }
            Set-SmbInvoker -Name NewShare -ScriptBlock { param($s) }
        }
        # Need the share root to exist for the path-presence guard in New-IdempotentSmbShare.
        $cfg = Get-ControllerConfigDefault
        $cfg.share.root = $script:tmp
        $r = Invoke-ShareStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Warn'
        ($r.Steps | Where-Object Name -eq 'Golden VHDX present').Status | Should -Be 'Warn'
    }

    It 'returns Pass when at least one VHDX file is present' {
        Set-ShareInvoker -Name EnsureDir -ScriptBlock { param($p) }
        Set-ShareInvoker -Name ListDir   -ScriptBlock { param($p,$f) @([pscustomobject]@{ Name='golden.vhdx' }) }
        & (Get-Module Smb) {
            Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Path=$null; Description=$null } }
            Set-SmbInvoker -Name NewShare -ScriptBlock { param($s) }
        }
        $cfg = Get-ControllerConfigDefault
        $cfg.share.root = $script:tmp
        $r = Invoke-ShareStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'returns Fail when New-IdempotentSmbShare fails' {
        Set-ShareInvoker -Name EnsureDir -ScriptBlock { param($p) }
        Set-ShareInvoker -Name ListDir   -ScriptBlock { param($p,$f) @() }
        & (Get-Module Smb) {
            Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Path=$null; Description=$null } }
            Set-SmbInvoker -Name NewShare -ScriptBlock { param($s) throw 'access denied' }
        }
        $cfg = Get-ControllerConfigDefault
        $cfg.share.root = $script:tmp
        $r = Invoke-ShareStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
    }
}
