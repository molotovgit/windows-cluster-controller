#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("prov-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\10-Provisioning.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ADMIN_PASS      -ErrorAction SilentlyContinue
}

Describe 'Invoke-ProvisioningStage' {

    BeforeEach { Reset-ProvisioningInvoker }

    It 'returns Pass via -DryRun' {
        $r = Invoke-ProvisioningStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'generates a random password and writes admin-bootstrap.txt when env var unset' {
        Remove-Item Env:CLUSTERCTRL_ADMIN_PASS -ErrorAction SilentlyContinue
        $script:wroteBootstrap = $false
        Set-ProvisioningInvoker -Name CreateAdminAccount  -ScriptBlock { param($n,$e,$w,$u,$p) [pscustomobject]@{ ExitCode = 0 } }
        Set-ProvisioningInvoker -Name NewSecurePassword   -ScriptBlock { param($l) 'fakepass1234567890' }
        Set-ProvisioningInvoker -Name WriteAdminBootstrap -ScriptBlock { param($p,$b) $script:wroteBootstrap = $true }
        Set-ProvisioningInvoker -Name RunMeshctrl         -ScriptBlock { param($v,$a) [pscustomobject]@{ ExitCode = 0 } }
        Set-ProvisioningInvoker -Name EnsureDir           -ScriptBlock { param($p) }
        $r = Invoke-ProvisioningStage 6>$null
        $r.Overall | Should -BeIn 'Pass','Warn'
        $script:wroteBootstrap | Should -BeTrue
    }

    It 'does NOT write admin-bootstrap.txt when password is sourced from env var' {
        $env:CLUSTERCTRL_ADMIN_PASS = 'OperatorChose-AStrong-Pass'
        try {
            $script:wroteBootstrap = $false
            Set-ProvisioningInvoker -Name CreateAdminAccount  -ScriptBlock { param($n,$e,$w,$u,$p) [pscustomobject]@{ ExitCode = 0 } }
            Set-ProvisioningInvoker -Name WriteAdminBootstrap -ScriptBlock { param($p,$b) $script:wroteBootstrap = $true }
            Set-ProvisioningInvoker -Name RunMeshctrl         -ScriptBlock { param($v,$a) [pscustomobject]@{ ExitCode = 0 } }
            Set-ProvisioningInvoker -Name EnsureDir           -ScriptBlock { param($p) }
            Invoke-ProvisioningStage 6>$null | Out-Null
            $script:wroteBootstrap | Should -BeFalse
        } finally {
            Remove-Item Env:CLUSTERCTRL_ADMIN_PASS -ErrorAction SilentlyContinue
        }
    }

    It 'records both device groups (hosts + vms)' {
        $script:groupCalls = @()
        Set-ProvisioningInvoker -Name CreateAdminAccount  -ScriptBlock { param($n,$e,$w,$u,$p) [pscustomobject]@{ ExitCode = 0 } }
        Set-ProvisioningInvoker -Name NewSecurePassword   -ScriptBlock { param($l) 'p' }
        Set-ProvisioningInvoker -Name WriteAdminBootstrap -ScriptBlock { param($p,$b) }
        Set-ProvisioningInvoker -Name RunMeshctrl         -ScriptBlock {
            param($v,$a)
            if ($v -eq 'AddDeviceGroup') { $script:groupCalls += $a[1] }   # --name <value>
            [pscustomobject]@{ ExitCode = 0 }
        }
        Set-ProvisioningInvoker -Name EnsureDir -ScriptBlock { param($p) }
        Invoke-ProvisioningStage 6>$null | Out-Null
        $script:groupCalls | Should -Contain 'cluster-hosts'
        $script:groupCalls | Should -Contain 'cluster-vms'
    }

    It 'reports Warn when meshctrl AddDeviceGroup exits non-zero (idempotency edge)' {
        Set-ProvisioningInvoker -Name CreateAdminAccount  -ScriptBlock { param($n,$e,$w,$u,$p) [pscustomobject]@{ ExitCode = 0 } }
        Set-ProvisioningInvoker -Name NewSecurePassword   -ScriptBlock { param($l) 'p' }
        Set-ProvisioningInvoker -Name WriteAdminBootstrap -ScriptBlock { param($p,$b) }
        Set-ProvisioningInvoker -Name RunMeshctrl         -ScriptBlock { param($v,$a) [pscustomobject]@{ ExitCode = 4 } }
        Set-ProvisioningInvoker -Name EnsureDir           -ScriptBlock { param($p) }
        $r = Invoke-ProvisioningStage 6>$null
        # Overall remains Pass: AddDeviceGroup non-zero is Warn-level, not Fail.
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object { $_.Name -like "Device group*" } | Select-Object -First 1).Status | Should -Be 'Warn'
    }
}
