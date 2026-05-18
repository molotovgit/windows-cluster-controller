#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Tls.psm1'
    Get-Module Tls | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:Tls = Get-Module Tls
}

AfterAll {
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module Tls | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ControllerSelfSignedCert' {

    BeforeEach { & $script:Tls { Reset-TlsInvoker } }

    It 'reuses an existing cert with the same CN' {
        & $script:Tls {
            Set-TlsInvoker -Name GetByCn -ScriptBlock {
                param($cn,$store)
                [pscustomobject]@{ Thumbprint = 'AABB1122'; Subject = "CN=$cn"; NotAfter = (Get-Date).AddDays(100) }
            }
            Set-TlsInvoker -Name NewSelfSignedCert -ScriptBlock { param($s) throw 'should not be called' }
        }
        $r = New-ControllerSelfSignedCert -Cn 'controller.lan'
        $r.Ok | Should -BeTrue
        $r.Reused | Should -BeTrue
        $r.Thumbprint | Should -Be 'AABB1122'
    }

    It 'generates a fresh cert when none exists and includes Cn + extras in SAN' {
        $script:specCapture = $null
        & $script:Tls {
            Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) $null }
            Set-TlsInvoker -Name NewSelfSignedCert -ScriptBlock {
                param($s) $script:specCapture = $s; [pscustomobject]@{ Thumbprint = 'CCDD3344'; Subject = "CN=$($s.Cn)"; NotAfter = (Get-Date).AddDays($s.ValidDays) }
            }
        }
        $r = New-ControllerSelfSignedCert -Cn 'controller.lan' -AdditionalSans @('controller','192.168.1.7')
        $r.Ok | Should -BeTrue
        $r.Reused | Should -BeFalse
        $r.Thumbprint | Should -Be 'CCDD3344'
        $spec = & $script:Tls { $script:specCapture }
        $spec.DnsNames | Should -Contain 'controller.lan'
        $spec.DnsNames | Should -Contain 'controller'
        $spec.DnsNames | Should -Contain '192.168.1.7'
    }

    It 'invokes ExportToRoot when -InstallToRoot' {
        $script:rootSeen = $false
        & $script:Tls {
            $script:rootSeen = $false
            Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) $null }
            Set-TlsInvoker -Name NewSelfSignedCert -ScriptBlock { param($s) [pscustomobject]@{ Thumbprint = 'FOO'; Subject = "CN=$($s.Cn)"; NotAfter = (Get-Date).AddDays(1) } }
            Set-TlsInvoker -Name ExportToRoot -ScriptBlock { param($tp,$st) $script:rootSeen = $true }
        }
        New-ControllerSelfSignedCert -Cn 'x' -InstallToRoot | Out-Null
        $seen = & $script:Tls { $script:rootSeen }
        $seen | Should -BeTrue
    }
}

Describe 'Import-ControllerPfxCert' {

    BeforeEach { & $script:Tls { Reset-TlsInvoker } }

    It 'reports Ok=$false when PFX path missing' {
        $r = Import-ControllerPfxCert -PfxPath 'C:\does\not\exist.pfx' -Password (ConvertTo-SecureString 'x' -AsPlainText -Force)
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'PFX not found'
    }

    It 'reuses an already-imported cert when ExpectedCn matches' {
        $tmpPfx = Join-Path ([System.IO.Path]::GetTempPath()) ("test.pfx")
        'x' | Set-Content -LiteralPath $tmpPfx -Encoding ascii
        try {
            & $script:Tls {
                Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) [pscustomobject]@{ Thumbprint = 'EE12'; Subject = "CN=$cn"; NotAfter = (Get-Date).AddDays(1) } }
                Set-TlsInvoker -Name ImportPfx -ScriptBlock { param($p,$pw,$st) throw 'should not be called' }
            }
            $r = Import-ControllerPfxCert -PfxPath $tmpPfx -Password (ConvertTo-SecureString 'x' -AsPlainText -Force) -ExpectedCn 'controller.lan'
            $r.Reused | Should -BeTrue
        } finally { Remove-Item -LiteralPath $tmpPfx -Force -ErrorAction SilentlyContinue }
    }

    It 'imports when no matching cert exists' {
        $tmpPfx = Join-Path ([System.IO.Path]::GetTempPath()) ("test2.pfx")
        'x' | Set-Content -LiteralPath $tmpPfx -Encoding ascii
        try {
            & $script:Tls {
                Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) $null }
                Set-TlsInvoker -Name ImportPfx -ScriptBlock { param($p,$pw,$st) [pscustomobject]@{ Thumbprint = 'NEW1'; Subject = 'CN=imported'; NotAfter = (Get-Date).AddDays(30) } }
            }
            $r = Import-ControllerPfxCert -PfxPath $tmpPfx -Password (ConvertTo-SecureString 'x' -AsPlainText -Force) -ExpectedCn 'controller.lan'
            $r.Ok | Should -BeTrue
            $r.Reused | Should -BeFalse
            $r.Thumbprint | Should -Be 'NEW1'
        } finally { Remove-Item -LiteralPath $tmpPfx -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-ControllerCert' {

    BeforeEach { & $script:Tls { Reset-TlsInvoker } }

    It 'finds by thumbprint' {
        & $script:Tls {
            Set-TlsInvoker -Name GetByThumbprint -ScriptBlock { param($tp,$store) [pscustomobject]@{ Thumbprint = $tp; Subject = 'CN=x'; NotAfter = (Get-Date) } }
        }
        $r = Get-ControllerCert -Thumbprint 'ABCD'
        $r.Found | Should -BeTrue
        $r.Thumbprint | Should -Be 'ABCD'
    }

    It 'finds by Cn' {
        & $script:Tls {
            Set-TlsInvoker -Name GetByCn -ScriptBlock { param($cn,$store) [pscustomobject]@{ Thumbprint = 'BB'; Subject = "CN=$cn"; NotAfter = (Get-Date) } }
        }
        (Get-ControllerCert -Cn 'controller.lan').Found | Should -BeTrue
    }

    It 'returns Found=$false when nothing matches' {
        & $script:Tls { Set-TlsInvoker -Name GetByThumbprint -ScriptBlock { param($tp,$store) $null } }
        (Get-ControllerCert -Thumbprint 'NOPE').Found | Should -BeFalse
    }
}
