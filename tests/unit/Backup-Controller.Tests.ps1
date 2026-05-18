#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Config','Service') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERCTRL_NOAUTORUN        = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("backup-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'scripts\Backup-Controller.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_NOAUTORUN        -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR          -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR        -ErrorAction SilentlyContinue
}

Describe 'Invoke-ControllerBackup' {

    BeforeEach {
        Reset-BackupInvoker
        & (Get-Module Service) { Reset-ServiceInvoker }
    }

    It 'creates an archive at the expected output path' {
        $outDir = Join-Path $script:tmp 'out'
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
        $script:capturedArchive = $null
        $capRef = $script:capturedArchive

        Set-BackupInvoker -Name EnsureDir       -ScriptBlock { param($p) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null } }
        Set-BackupInvoker -Name CopyTree        -ScriptBlock { param($f,$t) $true }
        Set-BackupInvoker -Name CopyFile        -ScriptBlock { param($f,$t) $true }
        Set-BackupInvoker -Name FileHashSha256  -ScriptBlock { param($p) 'DEADBEEF' }
        Set-BackupInvoker -Name GetToolVersion  -ScriptBlock { param($t) "$t-test-version" }
        Set-BackupInvoker -Name Compress        -ScriptBlock { param($s,$d) 'stub' | Set-Content -LiteralPath $d -Encoding ascii }

        $r = Invoke-ControllerBackup -OutputDir $outDir 6>$null
        $r | Should -Match '\.zip$'
        Test-Path -LiteralPath $r | Should -BeTrue
    }

    It 'manifest is included inside the staged tree before compression' {
        $outDir = Join-Path $script:tmp 'out3'
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
        Set-BackupInvoker -Name EnsureDir -ScriptBlock {
            param($p) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
        }
        Set-BackupInvoker -Name CopyTree        -ScriptBlock { param($f,$t) $true }
        Set-BackupInvoker -Name CopyFile        -ScriptBlock { param($f,$t) $true }
        Set-BackupInvoker -Name FileHashSha256  -ScriptBlock { param($p) 'X' }
        Set-BackupInvoker -Name GetToolVersion  -ScriptBlock { param($t) "v" }
        $script:manifestSeen = $false
        Set-BackupInvoker -Name Compress -ScriptBlock {
            param($s,$d)
            $script:manifestSeen = Test-Path -LiteralPath (Join-Path $s 'manifest.txt')
            'stub' | Set-Content -LiteralPath $d -Encoding ascii
        }
        Invoke-ControllerBackup -OutputDir $outDir 6>$null | Out-Null
        $script:manifestSeen | Should -BeTrue
    }

}
