#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Pkg','Service','Net','Config','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("db-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\05-Db.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-DbStage (NeDB)' {

    BeforeEach {
        Reset-DbInvoker
        & (Get-Module Pkg) { Reset-PkgInvoker }
        & (Get-Module Service) { Reset-ServiceInvoker }
        & (Get-Module Net) { Reset-NetInvoker }
    }

    It 'returns Pass with skipped install when db.mode=nedb' {
        $cfg = Get-ControllerConfigDefault
        $cfg.db.mode = 'nedb'
        $r = Invoke-DbStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Skip MongoDB install').Status | Should -Be 'Pass'
    }

    It 'returns Pass when no Config provided (defaults to nedb)' {
        $r = Invoke-DbStage 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Detail  | Should -Match 'NeDB'
    }

    It 'returns Fail when db.mode is unsupported' {
        $cfg = Get-ControllerConfigDefault
        $cfg.db.mode = 'postgres'
        $r = Invoke-DbStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail  | Should -Match 'unsupported db.mode'
    }
}

Describe 'Invoke-DbStage (MongoDB)' {

    BeforeEach {
        Reset-DbInvoker
        & (Get-Module Pkg)     { Reset-PkgInvoker }
        & (Get-Module Service) { Reset-ServiceInvoker }
        & (Get-Module Net)     { Reset-NetInvoker }
    }

    It 'short-circuits the install path when MongoDB is already installed' {
        $cfg = Get-ControllerConfigDefault
        $cfg.db.mode = 'mongodb'
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name GetInstalledByName -ScriptBlock { param($re) [pscustomobject]@{ DisplayName='MongoDB Server'; DisplayVersion='7.0.4'; UninstallString='' } }
            Set-PkgInvoker -Name Download           -ScriptBlock { param($u,$d,$t) throw 'should not be called' }
            Set-PkgInvoker -Name RunMsi             -ScriptBlock { param($p,$x) throw 'should not be called' }
        }
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true }
        }
        $r = Invoke-DbStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'Detect existing MongoDB').Status | Should -Be 'Pass'
    }

    It 'returns Pass via -DryRun without invoking any installer' {
        $cfg = Get-ControllerConfigDefault
        $cfg.db.mode = 'mongodb'
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name GetInstalledByName -ScriptBlock { param($re) $null }
            Set-PkgInvoker -Name Download           -ScriptBlock { param($u,$d,$t) throw 'should not be called' }
        }
        $r = Invoke-DbStage -Config $cfg -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'returns Fail when mongodb mode is set but no MsiUrl supplied' {
        $cfg = Get-ControllerConfigDefault
        $cfg.db.mode = 'mongodb'
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name GetInstalledByName -ScriptBlock { param($re) $null }
        }
        $r = Invoke-DbStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail  | Should -Match 'MongoDB MSI URL'
    }

    It 'writes mongod.cfg with the configured bind address' {
        $cfg = Get-ControllerConfigDefault
        $cfg.db.mode = 'mongodb'
        $script:capCfg = $null
        Set-DbInvoker -Name WriteMongoConfig -ScriptBlock { param($p,$b) $script:capCfg = $b }
        Set-DbInvoker -Name EnsureDir        -ScriptBlock { param($p) }
        & (Get-Module Pkg) {
            Set-PkgInvoker -Name GetInstalledByName -ScriptBlock { param($re) [pscustomobject]@{ DisplayName='MongoDB Server'; DisplayVersion='7'; UninstallString='' } }
        }
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
        }
        & (Get-Module Net) { Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true } }
        Invoke-DbStage -Config $cfg 6>$null | Out-Null
        $script:capCfg | Should -Not -BeNullOrEmpty
        $script:capCfg | Should -Match 'bindIp: 127\.0\.0\.1'
    }
}
