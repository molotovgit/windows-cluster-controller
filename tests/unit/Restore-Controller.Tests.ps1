#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Config','Service','Net') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERCTRL_NOAUTORUN        = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("restore-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'scripts\Restore-Controller.ps1')
}

AfterAll {
    Reset-ClusterLogState
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_NOAUTORUN        -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR          -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR        -ErrorAction SilentlyContinue
}

Describe 'Invoke-ControllerRestore' {

    BeforeEach {
        Reset-RestoreInvoker
        & (Get-Module Service) { Reset-ServiceInvoker }
    }

    It 'fails when archive path does not exist' {
        { Invoke-ControllerRestore -ArchivePath 'C:\nope.zip' 6>$null } | Should -Throw
    }

    It 'fails when manifest.txt is missing from the extracted archive' {
        $archive = Join-Path $script:tmp 'a.zip'
        'x' | Set-Content -LiteralPath $archive -Encoding ascii
        Set-RestoreInvoker -Name EnsureDir     -ScriptBlock { param($p) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null } }
        Set-RestoreInvoker -Name ExpandArchive -ScriptBlock { param($s,$d) }  # extracts nothing -- manifest missing
        $r = Invoke-ControllerRestore -ArchivePath $archive 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'Manifest present').Status | Should -Be 'Fail'
    }

    It 'refuses cross-hostname restore without -Force' {
        $archive = Join-Path $script:tmp 'b.zip'
        'x' | Set-Content -LiteralPath $archive -Encoding ascii
        Set-RestoreInvoker -Name EnsureDir     -ScriptBlock { param($p) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null } }
        Set-RestoreInvoker -Name ExpandArchive -ScriptBlock {
            param($s,$d)
            # Plant a manifest with a DIFFERENT hostname so the check fires.
            "controller_hostname: someother.lan`nutc: 2026-01-01T00:00:00Z`ncopied_components: meshcentral-data" |
                Set-Content -LiteralPath (Join-Path $d 'manifest.txt') -Encoding utf8
        }
        $r = Invoke-ControllerRestore -ArchivePath $archive 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'Hostname match').Status | Should -Be 'Fail'
    }

    It 'happy path: extract -> manifest ok -> hashes ok -> stop -> swap -> start' {
        $archive = Join-Path $script:tmp 'c.zip'
        'x' | Set-Content -LiteralPath $archive -Encoding ascii
        Set-RestoreInvoker -Name EnsureDir     -ScriptBlock { param($p) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null } }
        Set-RestoreInvoker -Name ExpandArchive -ScriptBlock {
            param($s,$d)
            "controller_hostname: controller.lan`nutc: 2026-01-01T00:00:00Z`ncopied_components: meshcentral-data" |
                Set-Content -LiteralPath (Join-Path $d 'manifest.txt') -Encoding utf8
        }
        Set-RestoreInvoker -Name ListFiles       -ScriptBlock { param($p) @() }     # target is empty
        Set-RestoreInvoker -Name FileHashSha256  -ScriptBlock { param($p) 'AA' }    # not used (manifest has no hash lines)
        Set-RestoreInvoker -Name SafeReplaceDir  -ScriptBlock { param($live,$src) }
        Set-RestoreInvoker -Name CopyFile        -ScriptBlock { param($f,$t) $true }
        & (Get-Module Service) {
            $script:state = 'Running'
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status=$script:state; StartType='Automatic' } }
            Set-ServiceInvoker -Name StopService  -ScriptBlock { param($n) $script:state = 'Stopped' }
            Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) $script:state = 'Running' }
        }
        $r = Invoke-ControllerRestore -ArchivePath $archive 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Stop MeshCentral').Status  | Should -BeIn 'Pass','Warn'
        ($r.Steps | Where-Object Name -eq 'Start MeshCentral').Status | Should -BeIn 'Pass','Warn'
    }
}
