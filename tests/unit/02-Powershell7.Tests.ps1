#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Pkg','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ps7-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\02-Powershell7.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-Powershell7Stage' {

    BeforeEach {
        Reset-Pwsh7Invoker
        & (Get-Module Pkg) { Reset-PkgInvoker }
    }

    It 'short-circuits Pass when pwsh >= MinVersion is already installed' {
        Set-Pwsh7Invoker -Name GetPwshVersion -ScriptBlock { '7.4.1' }
        $r = Invoke-Powershell7Stage -MinVersion '7.4' 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Detail | Should -Match 'already present'
    }

    It 'returns Pass via -DryRun when pwsh is not installed' {
        Set-Pwsh7Invoker -Name GetPwshVersion -ScriptBlock { $null }
        $r = Invoke-Powershell7Stage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Install pwsh 7').Status | Should -Be 'Skipped'
    }

    It 'tries winget first when available and reports Pass on success' {
        $script:probeCalls = 0
        Set-Pwsh7Invoker -Name TestWingetAvailable -ScriptBlock { $true }
        Set-Pwsh7Invoker -Name GetPwshVersion -ScriptBlock {
            $script:probeCalls++
            if ($script:probeCalls -ge 2) { '7.4.1' } else { $null }
        }
        & (Get-Module Pkg) { Set-PkgInvoker -Name RunWinget -ScriptBlock { param($id,$v) [pscustomobject]@{ ExitCode = 0 } } }
        $r = Invoke-Powershell7Stage 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'winget install').Status | Should -Be 'Pass'
    }

    It 'falls back to MSI when winget fails and -MsiUrl is provided' {
        Set-Pwsh7Invoker -Name TestWingetAvailable -ScriptBlock { $true }
        $script:probeCalls = 0
        Set-Pwsh7Invoker -Name GetPwshVersion -ScriptBlock {
            $script:probeCalls++
            if ($script:probeCalls -ge 2) { '7.4.1' } else { $null }
        }
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name RunWinget       -ScriptBlock { param($id,$v) [pscustomobject]@{ ExitCode = 2 } }
            Set-PkgInvoker -Name Download        -ScriptBlock { param($u,$d,$t) 'msi-bytes' | Set-Content -LiteralPath $d -Encoding ascii -NoNewline }
            Set-PkgInvoker -Name FileHashSha256  -ScriptBlock { param($p) 'DEADBEEF' }
            Set-PkgInvoker -Name RunMsi          -ScriptBlock { param($p,$x) [pscustomobject]@{ ExitCode = 0; Log = 'C:\Temp\log' } }
        }
        $r = Invoke-Powershell7Stage -MsiUrl 'https://example/pwsh.msi' -MsiSha256 'DEADBEEF' 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'MSI install').Status | Should -Be 'Pass'
    }

    It 'returns Fail when winget unavailable and no MsiUrl is provided' {
        Set-Pwsh7Invoker -Name TestWingetAvailable -ScriptBlock { $false }
        Set-Pwsh7Invoker -Name GetPwshVersion -ScriptBlock { $null }
        $r = Invoke-Powershell7Stage 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail | Should -Match 'no MSI URL'
    }

    It 'returns Fail when MSI download hash mismatches' {
        Set-Pwsh7Invoker -Name TestWingetAvailable -ScriptBlock { $false }
        Set-Pwsh7Invoker -Name GetPwshVersion -ScriptBlock { $null }
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name Download       -ScriptBlock { param($u,$d,$t) 'bad' | Set-Content -LiteralPath $d -Encoding ascii -NoNewline }
            Set-PkgInvoker -Name FileHashSha256 -ScriptBlock { param($p) 'BADHASH' }
        }
        $r = Invoke-Powershell7Stage -MsiUrl 'https://example/pwsh.msi' -MsiSha256 'EXPECTED' 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'MSI download').Status | Should -Be 'Fail'
    }
}
