#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\03-OpenSshClient.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-OpenSshClientStage' {
    BeforeEach { Reset-OpenSshClientInvoker }

    It 'short-circuits Pass when capability is already Installed' {
        Set-OpenSshClientInvoker -Name GetCapability -ScriptBlock { param($f) [pscustomobject]@{ Found=$true; Name='OpenSSH.Client~~~~0.0.1.0'; State='Installed' } }
        $r = Invoke-OpenSshClientStage 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Detail  | Should -Match 'already installed'
    }

    It 'passes via -DryRun without invoking install' {
        Set-OpenSshClientInvoker -Name GetCapability -ScriptBlock { param($f) [pscustomobject]@{ Found=$true; Name='OpenSSH.Client~~~~0.0.1.0'; State='NotPresent' } }
        Set-OpenSshClientInvoker -Name AddCapability -ScriptBlock { param($n) throw 'should not be called' }
        $r = Invoke-OpenSshClientStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Install OpenSSH client').Status | Should -Be 'Skipped'
    }

    It 'uses Add-WindowsCapability when probe is NotPresent and verify succeeds' {
        $script:probeCalls = 0
        Set-OpenSshClientInvoker -Name GetCapability -ScriptBlock {
            param($f)
            $script:probeCalls++
            if ($script:probeCalls -ge 2) { [pscustomobject]@{ Found=$true; Name='OpenSSH.Client~~~~0.0.1.0'; State='Installed' } }
            else { [pscustomobject]@{ Found=$true; Name='OpenSSH.Client~~~~0.0.1.0'; State='NotPresent' } }
        }
        Set-OpenSshClientInvoker -Name AddCapability -ScriptBlock { param($n) }
        Set-OpenSshClientInvoker -Name TestSshOnPath -ScriptBlock { $true }
        $r = Invoke-OpenSshClientStage 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'WindowsCapability install').Status | Should -Be 'Pass'
    }

    It 'falls back to DISM when Add-WindowsCapability throws' {
        Set-OpenSshClientInvoker -Name GetCapability  -ScriptBlock { param($f) [pscustomobject]@{ Found=$true; Name='OpenSSH.Client~~~~0.0.1.0'; State='NotPresent' } }
        Set-OpenSshClientInvoker -Name AddCapability  -ScriptBlock { param($n) throw 'capability service unavailable' }
        Set-OpenSshClientInvoker -Name RunDism        -ScriptBlock { param($n) [pscustomobject]@{ ExitCode = 0 } }
        Set-OpenSshClientInvoker -Name TestSshOnPath  -ScriptBlock { $true }
        $r = Invoke-OpenSshClientStage 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'DISM install').Status | Should -Be 'Pass'
    }

    It 'returns Fail when BOTH WindowsCapability and DISM fail' {
        Set-OpenSshClientInvoker -Name GetCapability  -ScriptBlock { param($f) [pscustomobject]@{ Found=$true; Name='OpenSSH.Client~~~~0.0.1.0'; State='NotPresent' } }
        Set-OpenSshClientInvoker -Name AddCapability  -ScriptBlock { param($n) throw 'fail-1' }
        Set-OpenSshClientInvoker -Name RunDism        -ScriptBlock { param($n) [pscustomobject]@{ ExitCode = 87 } }
        $r = Invoke-OpenSshClientStage 6>$null
        $r.Overall | Should -Be 'Fail'
    }

    It 'returns Warn when install reports success but post-install verify cannot see ssh' {
        Set-OpenSshClientInvoker -Name GetCapability  -ScriptBlock { param($f) [pscustomobject]@{ Found=$true; Name='OpenSSH.Client~~~~0.0.1.0'; State='NotPresent' } }
        Set-OpenSshClientInvoker -Name AddCapability  -ScriptBlock { param($n) }
        Set-OpenSshClientInvoker -Name TestSshOnPath  -ScriptBlock { $false }
        $r = Invoke-OpenSshClientStage 6>$null
        $r.Overall | Should -Be 'Warn'
    }
}
