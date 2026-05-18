#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','HardwareDetect','Net') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'

    # Per-suite temp dirs so logging doesn't write into %ProgramData%.
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pf-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\01-Preflight.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-PreflightStage' {

    BeforeEach {
        # Stub the surfaces we control: HardwareDetect (for SKU) and Net (for port probe).
        & (Get-Module HardwareDetect) {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Professional' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Professional' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Pro' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Pro' }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $false }   # port 443 free
        }
    }

    AfterEach {
        & (Get-Module HardwareDetect) { Reset-HardwareDetector }
        & (Get-Module Net) { Reset-NetInvoker }
    }

    It 'returns a structured report shape regardless of pass/fail mix' {
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $r | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties['Overall']    | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties['Checks']     | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties['PassCount']  | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties['FailCount']  | Should -Not -BeNullOrEmpty
        @($r.Checks).Count | Should -BeGreaterOrEqual 9
    }

    It 'records the Administrator check' {
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        ($r.Checks | Where-Object { $_.Name -eq 'Administrator' }).Count | Should -Be 1
    }

    It 'records a Windows SKU check that resolves to Pro when stubs provide Professional' {
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $skuCheck = $r.Checks | Where-Object { $_.Name -eq 'Windows SKU' }
        $skuCheck.Status | Should -Be 'Pass'
        $skuCheck.Detail | Should -Match 'Pro'
    }

    It 'flags the HTTPS-port check Fail when the Net seam reports the port is in use' {
        & (Get-Module Net) {
            Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $p -eq 443 }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $portCheck = $r.Checks | Where-Object { $_.Name -like 'TCP*free' }
        $portCheck.Status | Should -Be 'Fail'
    }

    It 'records a PowerShell version check (Pass on pwsh 7+, Warn on 5.1)' {
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $verCheck = $r.Checks | Where-Object { $_.Name -eq 'PowerShell version' }
        $verCheck.Status | Should -BeIn 'Pass','Warn'
    }

    It 'overall is at most Warn when -IgnoreFailures is set, even with Fail checks present' {
        # Force a Fail via the SKU path: pretend it's Home.
        & (Get-Module HardwareDetect) {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Home' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Core' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Home' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Home' }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $r.Overall | Should -BeIn 'Pass','Warn'
    }

    It 'overall is Fail when SKU is Home and -IgnoreFailures is NOT set' {
        & (Get-Module HardwareDetect) {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Home' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Core' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Home' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Home' }
        }
        $r = Invoke-PreflightStage 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.FailCount | Should -BeGreaterThan 0
    }
}
