#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Announce','Service','Net','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ann-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\12-Announcer.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-AnnouncerStage' {

    BeforeEach {
        Reset-AnnouncerStageInvoker
        & (Get-Module Service) { Reset-ServiceInvoker }
        & (Get-Module Net)     { Reset-NetInvoker }
    }

    It 'returns Pass via -DryRun' {
        $r = Invoke-AnnouncerStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'writes payload + script and registers the service' {
        $script:writes = New-Object System.Collections.Generic.List[string]
        $w = $script:writes
        Set-AnnouncerStageInvoker -Name WriteFile -ScriptBlock { param($p,$b) $w.Add($p) }.GetNewClosure()
        Set-AnnouncerStageInvoker -Name ResolvePwshExe -ScriptBlock { 'C:\pwsh.exe' }
        & (Get-Module Service) {
            $script:state = 'NotInstalled'
            Set-ServiceInvoker -Name GetService -ScriptBlock {
                param($n)
                if ($script:state -eq 'NotInstalled') { [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } }
                else { [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
            }
            Set-ServiceInvoker -Name RunNssm -ScriptBlock { param($a) $script:state = 'Running'; [pscustomobject]@{ ExitCode = 0 } }
            Set-ServiceInvoker -Name SetStartType -ScriptBlock { param($n,$t) }
            Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) }
        }
        & (Get-Module Net) { Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true } }
        $r = Invoke-AnnouncerStage 6>$null
        $r.Overall | Should -Be 'Pass'
        $script:writes.Count | Should -BeGreaterOrEqual 2
        @($script:writes | Where-Object { $_ -match 'announcer\.ps1$' }).Count        | Should -BeGreaterOrEqual 1
        @($script:writes | Where-Object { $_ -match 'announcer-payload\.json$' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'returns Fail when no PowerShell exe is available' {
        Set-AnnouncerStageInvoker -Name WriteFile      -ScriptBlock { param($p,$b) }
        Set-AnnouncerStageInvoker -Name ResolvePwshExe -ScriptBlock { $null }
        $r = Invoke-AnnouncerStage 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail  | Should -Match 'PowerShell exe'
    }

    It 'returns Fail when NSSM registration fails' {
        Set-AnnouncerStageInvoker -Name WriteFile      -ScriptBlock { param($p,$b) }
        Set-AnnouncerStageInvoker -Name ResolvePwshExe -ScriptBlock { 'C:\pwsh.exe' }
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } }
            Set-ServiceInvoker -Name RunNssm    -ScriptBlock { param($a) [pscustomobject]@{ ExitCode = 1 } }
        }
        $r = Invoke-AnnouncerStage 6>$null
        $r.Overall | Should -Be 'Fail'
    }
}
