#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Service','Net','Smb','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\13-Verify.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-VerifyStage' {

    BeforeEach {
        Reset-VerifyInvoker
        & (Get-Module Service) { Reset-ServiceInvoker }
        & (Get-Module Net)     { Reset-NetInvoker }
    }

    It 'returns Pass on the happy path (NeDB; all services Running; HTTPS up; SMB present; VHDX present)' {
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name TestTcp    -ScriptBlock { param($a,$p,$t) $true }
            Set-NetInvoker -Name HttpProbe  -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = 'MeshCentral' } }
        }
        Set-VerifyInvoker -Name GetSmbShare  -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path='C:\share' } }
        Set-VerifyInvoker -Name ListDir      -ScriptBlock { param($p,$f) @([pscustomobject]@{ Name='golden.vhdx' }) }
        Set-VerifyInvoker -Name WriteSummary -ScriptBlock { param($p,$b) }
        $r = Invoke-VerifyStage 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.FailCount | Should -Be 0
    }

    It 'returns Warn when VHDX dir is empty even though everything else is OK' {
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true }
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = '' } }
        }
        Set-VerifyInvoker -Name GetSmbShare  -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path='C:\share' } }
        Set-VerifyInvoker -Name ListDir      -ScriptBlock { param($p,$f) @() }
        Set-VerifyInvoker -Name WriteSummary -ScriptBlock { param($p,$b) }
        $r = Invoke-VerifyStage 6>$null
        $r.Overall | Should -Be 'Warn'
    }

    It 'returns Fail when MeshCentral service is not Running' {
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock {
                param($n)
                if ($n -eq 'MeshCentral') { [pscustomobject]@{ Found=$true; Status='Stopped'; StartType='Automatic' } }
                else { [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
            }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true }
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = '' } }
        }
        Set-VerifyInvoker -Name GetSmbShare  -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path='C:\share' } }
        Set-VerifyInvoker -Name ListDir      -ScriptBlock { param($p,$f) @([pscustomobject]@{ Name='g.vhdx' }) }
        Set-VerifyInvoker -Name WriteSummary -ScriptBlock { param($p,$b) }
        $r = Invoke-VerifyStage 6>$null
        $r.Overall | Should -Be 'Fail'
    }

    It 'summary text names the URL, admin user, share, groups' {
        $script:capBody = $null
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true }
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = '' } }
        }
        Set-VerifyInvoker -Name GetSmbShare  -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path='C:\share' } }
        Set-VerifyInvoker -Name ListDir      -ScriptBlock { param($p,$f) @([pscustomobject]@{ Name='g.vhdx' }) }
        Set-VerifyInvoker -Name WriteSummary -ScriptBlock { param($p,$b) $script:capBody = $b }
        Invoke-VerifyStage 6>$null | Out-Null
        $script:capBody | Should -Match 'https://controller\.lan:443/'
        $script:capBody | Should -Match 'cluster-hosts'
        $script:capBody | Should -Match 'cluster-vms'
        $script:capBody | Should -Match 'clusteradmin'
        $script:capBody | Should -Match 'ClusterShare'
    }
}
