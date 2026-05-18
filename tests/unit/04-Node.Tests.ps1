#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Pkg','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("node-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\04-Node.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-NodeStage' {

    BeforeEach {
        Reset-NodeInvoker
        & (Get-Module Pkg) { Reset-PkgInvoker }
    }

    It 'short-circuits Pass when node is already at required version' {
        Set-NodeInvoker -Name GetNodeVersion -ScriptBlock { 'v20.11.0' }
        $r = Invoke-NodeStage -MinVersion '18.0' 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Detail | Should -Match 'already present'
    }

    It 'returns Pass via -DryRun when node is absent' {
        Set-NodeInvoker -Name GetNodeVersion -ScriptBlock { $null }
        $r = Invoke-NodeStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'returns Fail when node is absent and no MsiUrl is provided' {
        Set-NodeInvoker -Name GetNodeVersion -ScriptBlock { $null }
        $r = Invoke-NodeStage 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail | Should -Match 'no MsiUrl'
    }

    It 'downloads + installs + verifies on a happy path' {
        $script:probeCalls = 0
        Set-NodeInvoker -Name GetNodeVersion -ScriptBlock {
            $script:probeCalls++
            if ($script:probeCalls -ge 2) { 'v20.11.0' } else { $null }
        }
        Set-NodeInvoker -Name RefreshPathFromRegistry -ScriptBlock {}
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name Download       -ScriptBlock { param($u,$d,$t) 'msi-bytes' | Set-Content -LiteralPath $d -Encoding ascii -NoNewline }
            Set-PkgInvoker -Name FileHashSha256 -ScriptBlock { param($p) 'EXPECTED' }
            Set-PkgInvoker -Name RunMsi         -ScriptBlock { param($p,$x) [pscustomobject]@{ ExitCode = 0; Log = 'C:\Temp\log' } }
        }
        $r = Invoke-NodeStage -MsiUrl 'https://nodejs.org/x.msi' -MsiSha256 'EXPECTED' 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Download node MSI').Status | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Install node MSI').Status  | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Verify node').Status       | Should -Be 'Pass'
    }

    It 'returns Fail on hash mismatch during download' {
        Set-NodeInvoker -Name GetNodeVersion -ScriptBlock { $null }
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name Download       -ScriptBlock { param($u,$d,$t) 'bad' | Set-Content -LiteralPath $d -Encoding ascii -NoNewline }
            Set-PkgInvoker -Name FileHashSha256 -ScriptBlock { param($p) 'BADHASH' }
        }
        $r = Invoke-NodeStage -MsiUrl 'https://nodejs.org/x.msi' -MsiSha256 'EXPECTED' 6>$null
        $r.Overall | Should -Be 'Fail'
    }

    It 'returns Fail when msiexec exits non-zero / non-3010' {
        Set-NodeInvoker -Name GetNodeVersion -ScriptBlock { $null }
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name Download       -ScriptBlock { param($u,$d,$t) 'msi' | Set-Content -LiteralPath $d -Encoding ascii -NoNewline }
            Set-PkgInvoker -Name FileHashSha256 -ScriptBlock { param($p) 'EXPECTED' }
            Set-PkgInvoker -Name RunMsi         -ScriptBlock { param($p,$x) [pscustomobject]@{ ExitCode = 1603; Log = 'C:\Temp\log' } }
        }
        $r = Invoke-NodeStage -MsiUrl 'https://x' -MsiSha256 'EXPECTED' 6>$null
        $r.Overall | Should -Be 'Fail'
    }
}
