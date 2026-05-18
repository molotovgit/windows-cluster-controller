#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Config','Service','Net','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERCTRL_NOAUTORUN        = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("update-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'scripts\Update-MeshCentral.ps1')
}

AfterAll {
    Reset-ClusterLogState
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_NOAUTORUN        -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR          -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR        -ErrorAction SilentlyContinue
}

Describe 'Invoke-MeshcentralUpdate' {

    BeforeEach {
        Reset-UpdateInvoker
        & (Get-Module Service) { Reset-ServiceInvoker }
        & (Get-Module Net)     { Reset-NetInvoker }
    }

    It 'fails when current MeshCentral version cannot be read' {
        Set-UpdateInvoker -Name ReadMeshcentralVersion -ScriptBlock { param($r) $null }
        $r = Invoke-MeshcentralUpdate 6>$null
        $r.Overall | Should -Be 'Fail'
    }

    It 'happy path: backup -> npm install -> start -> healthy -> Pass' {
        $script:vCalls = 0
        Set-UpdateInvoker -Name ReadMeshcentralVersion -ScriptBlock {
            param($r) $script:vCalls++; if ($script:vCalls -eq 1) { '1.1.0' } else { '1.2.0' }
        }
        Set-UpdateInvoker -Name InvokeBackup           -ScriptBlock { param($cfg) Join-Path ([System.IO.Path]::GetTempPath()) 'ok.zip' }
        $arch = Join-Path ([System.IO.Path]::GetTempPath()) 'ok.zip'
        'x' | Set-Content -LiteralPath $arch -Encoding ascii
        Set-UpdateInvoker -Name RunNpmInstall          -ScriptBlock { param($r,$v) [pscustomobject]@{ ExitCode = 0 } }
        & (Get-Module Service) {
            $script:svcState = 'Running'
            Set-ServiceInvoker -Name GetService -ScriptBlock {
                param($n) [pscustomobject]@{ Found=$true; Status=$script:svcState; StartType='Automatic' }
            }
            Set-ServiceInvoker -Name StopService  -ScriptBlock { param($n) $script:svcState = 'Stopped' }
            Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) $script:svcState = 'Running' }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = '' } }
        }
        $r = Invoke-MeshcentralUpdate 6>$null
        $r.Overall    | Should -Be 'Pass'
        $r.OldVersion | Should -Be '1.1.0'
        $r.NewVersion | Should -Be '1.2.0'
        Remove-Item -LiteralPath $arch -Force -ErrorAction SilentlyContinue
    }


    It 'reports Fail when npm install exits non-zero' {
        Set-UpdateInvoker -Name ReadMeshcentralVersion -ScriptBlock { param($r) '1.1.0' }
        $arch = Join-Path ([System.IO.Path]::GetTempPath()) 'npmfail.zip'
        'x' | Set-Content -LiteralPath $arch -Encoding ascii
        Set-UpdateInvoker -Name InvokeBackup -ScriptBlock { param($cfg) $arch }.GetNewClosure()
        Set-UpdateInvoker -Name RunNpmInstall -ScriptBlock { param($r,$v) [pscustomobject]@{ ExitCode = 1 } }
        & (Get-Module Service) {
            $script:svcState = 'Stopped'
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status=$script:svcState; StartType='Automatic' } }
            Set-ServiceInvoker -Name StopService -ScriptBlock { param($n) $script:svcState = 'Stopped' }
            Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) $script:svcState = 'Running' }
        }
        $r = Invoke-MeshcentralUpdate 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'npm install meshcentral').Status | Should -Be 'Fail'
        Remove-Item -LiteralPath $arch -Force -ErrorAction SilentlyContinue
    }
}
