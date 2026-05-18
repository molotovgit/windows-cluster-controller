#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Config','Service','Firewall','Smb','State') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERCTRL_NOAUTORUN        = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uninst-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'
    $env:CLUSTERCTRL_REG_BASE  = "HKCU:\Software\ClusterController-uninst-$([guid]::NewGuid().ToString('N').Substring(0,8))"

    . (Join-Path $repoRoot 'scripts\Uninstall-Controller.ps1')
}

AfterAll {
    Reset-ClusterLogState
    Remove-Item -LiteralPath $env:CLUSTERCTRL_REG_BASE -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_NOAUTORUN        -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR          -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR        -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_REG_BASE          -ErrorAction SilentlyContinue
}

Describe 'Invoke-ControllerUninstall' {

    BeforeEach {
        Reset-UninstallInvoker
        & (Get-Module Smb)      { Reset-SmbInvoker }
        & (Get-Module Firewall) { Reset-FirewallInvoker }
        & (Get-Module State)    { Reset-ResumeTaskInvoker }
    }

    It 'returns Skipped without -Yes' {
        $r = Invoke-ControllerUninstall
        $r.Overall | Should -Be 'Skipped'
        $r.Detail  | Should -Match '-Yes'
    }

    It 'happy path with -Yes: stops + removes everything, preserves data dirs' {
        Set-UninstallInvoker -Name RemoveAnnouncerService   -ScriptBlock { [pscustomobject]@{ ExitCode = 0 } }
        Set-UninstallInvoker -Name TestNodeOnPath           -ScriptBlock { 'C:\node.exe' }
        Set-UninstallInvoker -Name RunMeshcentralUninstall  -ScriptBlock { param($n,$e,$w) [pscustomobject]@{ ExitCode = 0 } }
        Set-UninstallInvoker -Name ScDelete                 -ScriptBlock { param($n) [pscustomobject]@{ ExitCode = 0 } }
        Set-UninstallInvoker -Name ListClusterRules         -ScriptBlock { @([pscustomobject]@{ DisplayName='ClusterController: MeshCentral HTTPS' }) }
        Set-UninstallInvoker -Name RemoveItemTree           -ScriptBlock { param($p) }
        & (Get-Module Smb) {
            Set-SmbInvoker -Name GetShare    -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path='C:\share'; Description='' } }
            Set-SmbInvoker -Name RemoveShare -ScriptBlock { param($n) }
        }
        & (Get-Module Firewall) {
            Set-FirewallInvoker -Name GetRule    -ScriptBlock { param($n) [pscustomobject]@{ Name=$n; Enabled='True'; Direction='Inbound'; Action='Allow'; Profile='Domain'; Protocol='TCP'; LocalPort='443'; LocalAddress=$null } }
            Set-FirewallInvoker -Name RemoveRule -ScriptBlock { param($n) }
        }
        & (Get-Module State) {
            Set-ResumeTaskInvoker -Operation Test       -ScriptBlock { $false }
            Set-ResumeTaskInvoker -Operation Unregister -ScriptBlock { }
        }
        $r = Invoke-ControllerUninstall -Yes
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -like 'Data dirs').Status | Should -Be 'Skipped'
    }

    It 'with -PurgeData wipes ClusterController and MeshCentral roots' {
        $script:purged = New-Object System.Collections.Generic.List[string]
        $cap = $script:purged
        Set-UninstallInvoker -Name RemoveAnnouncerService   -ScriptBlock { [pscustomobject]@{ ExitCode = 0 } }
        Set-UninstallInvoker -Name TestNodeOnPath           -ScriptBlock { 'C:\node.exe' }
        Set-UninstallInvoker -Name RunMeshcentralUninstall  -ScriptBlock { param($n,$e,$w) [pscustomobject]@{ ExitCode = 0 } }
        Set-UninstallInvoker -Name ScDelete                 -ScriptBlock { param($n) [pscustomobject]@{ ExitCode = 0 } }
        Set-UninstallInvoker -Name ListClusterRules         -ScriptBlock { @() }
        Set-UninstallInvoker -Name RemoveItemTree           -ScriptBlock { param($p) $cap.Add($p) }.GetNewClosure()
        & (Get-Module Smb) {
            Set-SmbInvoker -Name GetShare    -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Path=$null; Description=$null } }
        }
        & (Get-Module State) {
            Set-ResumeTaskInvoker -Operation Test       -ScriptBlock { $false }
            Set-ResumeTaskInvoker -Operation Unregister -ScriptBlock { }
        }
        Invoke-ControllerUninstall -Yes -PurgeData 6>$null | Out-Null
        @($script:purged | Where-Object { $_ -match 'ClusterController$' }).Count | Should -BeGreaterOrEqual 1
        @($script:purged | Where-Object { $_ -match 'MeshCentral$'        }).Count | Should -BeGreaterOrEqual 1
    }
}
