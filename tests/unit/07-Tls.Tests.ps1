#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Stage 7 unit tests. Cert generation is delegated to lib/Tls's seams;
# the stage itself routes on config.tls.mode + writes the thumbprint
# into MeshCentral's config.json.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='test-only literal -> SecureString')]
param()

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Tls','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tls-stage-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\07-Tls.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-TlsStage (self-signed)' {

    BeforeEach {
        Reset-TlsStageInvoker
        & (Get-Module Tls) { Reset-TlsInvoker }
    }

    It 'returns Pass via -DryRun without calling any cert seam' {
        & (Get-Module Tls) {
            Set-TlsInvoker -Name NewSelfSignedCert -ScriptBlock { param($s) throw 'should not be called' }
        }
        $r = Invoke-TlsStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'generates a self-signed cert in default mode and reports thumbprint' {
        & (Get-Module Tls) {
            Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) $null }
            Set-TlsInvoker -Name NewSelfSignedCert -ScriptBlock { param($s) [pscustomobject]@{ Thumbprint = 'AAAA1111'; Subject = "CN=$($s.Cn)"; NotAfter = (Get-Date).AddDays(100) } }
            Set-TlsInvoker -Name ExportToRoot -ScriptBlock { param($t,$s) }
        }
        $r = Invoke-TlsStage 6>$null
        $r.Overall    | Should -Be 'Pass'
        $r.Thumbprint | Should -Be 'AAAA1111'
    }
}

Describe 'Invoke-TlsStage (import)' {

    BeforeEach {
        Reset-TlsStageInvoker
        & (Get-Module Tls) { Reset-TlsInvoker }
    }

    It 'returns Fail when pfx_path is empty' {
        $cfg = Get-ControllerConfigDefault
        $cfg.tls.mode = 'import'
        $cfg.tls.import.pfx_path = $null
        $r = Invoke-TlsStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail  | Should -Match 'no pfx_path'
    }

    It 'returns Fail when the password env var is not set' {
        $cfg = Get-ControllerConfigDefault
        $cfg.tls.mode = 'import'
        $cfg.tls.import.pfx_path = (Join-Path $script:tmp 'x.pfx')
        'x' | Set-Content -LiteralPath $cfg.tls.import.pfx_path -Encoding ascii
        Set-TlsStageInvoker -Name GetPfxPassword -ScriptBlock { param($n) $null }
        $r = Invoke-TlsStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail  | Should -Match 'PFX password'
    }

    It 'imports the PFX and records the thumbprint on success' {
        $cfg = Get-ControllerConfigDefault
        $cfg.tls.mode = 'import'
        $cfg.tls.import.pfx_path = (Join-Path $script:tmp 'good.pfx')
        'pfx-bytes' | Set-Content -LiteralPath $cfg.tls.import.pfx_path -Encoding ascii
        Set-TlsStageInvoker -Name GetPfxPassword -ScriptBlock { param($n) (ConvertTo-SecureString 'x' -AsPlainText -Force) }
        & (Get-Module Tls) {
            Set-TlsInvoker -Name GetByCn   -ScriptBlock { param($cn,$store) $null }
            Set-TlsInvoker -Name ImportPfx -ScriptBlock { param($p,$pw,$st) [pscustomobject]@{ Thumbprint = 'BBBB2222'; Subject = 'CN=controller.lan'; NotAfter = (Get-Date).AddDays(30) } }
        }
        $r = Invoke-TlsStage -Config $cfg 6>$null
        $r.Overall    | Should -Be 'Pass'
        $r.Thumbprint | Should -Be 'BBBB2222'
    }
}

Describe 'Invoke-TlsStage (letsencrypt stub)' {

    BeforeEach {
        Reset-TlsStageInvoker
        & (Get-Module Tls) { Reset-TlsInvoker }
    }

    It 'reuses an existing CN match when present' {
        $cfg = Get-ControllerConfigDefault
        $cfg.tls.mode = 'letsencrypt'
        & (Get-Module Tls) {
            Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) [pscustomobject]@{ Thumbprint = 'CCCC3333'; Subject = "CN=$cn"; NotAfter = (Get-Date).AddDays(60) } }
        }
        $r = Invoke-TlsStage -Config $cfg 6>$null
        $r.Overall    | Should -Be 'Pass'
        $r.Thumbprint | Should -Be 'CCCC3333'
    }

    It 'returns Fail when no existing cert exists in letsencrypt stub mode' {
        $cfg = Get-ControllerConfigDefault
        $cfg.tls.mode = 'letsencrypt'
        & (Get-Module Tls) {
            Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) $null }
        }
        $r = Invoke-TlsStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
    }
}

Describe 'Invoke-TlsStage (unsupported)' {
    BeforeEach { Reset-TlsStageInvoker; & (Get-Module Tls) { Reset-TlsInvoker } }

    It 'returns Fail for an unsupported tls.mode' {
        $cfg = Get-ControllerConfigDefault
        $cfg.tls.mode = 'fancy'
        $r = Invoke-TlsStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail  | Should -Match 'unsupported'
    }
}
