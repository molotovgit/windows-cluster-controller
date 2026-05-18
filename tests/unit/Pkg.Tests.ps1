#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Pkg.psm1'
    Get-Module Pkg | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:Pkg = Get-Module Pkg
}

AfterAll {
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module Pkg | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-PkgDownload' {

    BeforeEach {
        & $script:Pkg { Reset-PkgInvoker }
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pkg-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'short-circuits when destination already exists and hash matches' {
        $dest = Join-Path $script:tmp 'a.bin'
        'data' | Set-Content -LiteralPath $dest -Encoding ascii
        $expected = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        & $script:Pkg {
            Set-PkgInvoker -Name Download -ScriptBlock { param($u,$d,$t) throw 'should not have been called' }
        }
        $r = Get-PkgDownload -Url 'https://x/y' -Dest $dest -Sha256 $expected
        $r.Ok | Should -BeTrue
        $r.AlreadyPresent | Should -BeTrue
    }

    It 'downloads and verifies a fresh file when seam delivers correct bytes' {
        $dest = Join-Path $script:tmp 'b.bin'
        & $script:Pkg {
            Set-PkgInvoker -Name Download -ScriptBlock { param($u,$d,$t) 'payload' | Set-Content -LiteralPath $d -Encoding ascii -NoNewline }
        }
        $stage = Join-Path $script:tmp 'stage-b.bin'
        'payload' | Set-Content -LiteralPath $stage -Encoding ascii -NoNewline
        $expected = (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash

        $r = Get-PkgDownload -Url 'https://example/b' -Dest $dest -Sha256 $expected
        $r.Ok | Should -BeTrue
        $r.AlreadyPresent | Should -BeFalse
        $r.ActualHash | Should -Be $expected
    }

    It 'deletes the partial file and reports failure on SHA256 mismatch' {
        $dest = Join-Path $script:tmp 'c.bin'
        & $script:Pkg {
            Set-PkgInvoker -Name Download -ScriptBlock { param($u,$d,$t) 'bad-payload' | Set-Content -LiteralPath $d -Encoding ascii -NoNewline }
        }
        $r = Get-PkgDownload -Url 'https://x/c' -Dest $dest -Sha256 'DEADBEEF'  # wrong
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'SHA256 mismatch'
        Test-Path -LiteralPath $dest | Should -BeFalse   # cleaned up
    }

    It 'surfaces a network error as Ok=$false' {
        $dest = Join-Path $script:tmp 'd.bin'
        & $script:Pkg {
            Set-PkgInvoker -Name Download -ScriptBlock { param($u,$d,$t) throw 'connection refused' }
        }
        $r = Get-PkgDownload -Url 'https://nope/d' -Dest $dest
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'download failed'
    }
}

Describe 'Install-PkgMsi' {

    BeforeEach { & $script:Pkg { Reset-PkgInvoker } }

    It 'reports Ok=$true on exit 0' {
        $tmpMsi = Join-Path ([System.IO.Path]::GetTempPath()) ("fake-msi-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.msi')
        'msi-bytes' | Set-Content -LiteralPath $tmpMsi -Encoding ascii
        try {
            & $script:Pkg { Set-PkgInvoker -Name RunMsi -ScriptBlock { param($p,$x) [pscustomobject]@{ ExitCode = 0; Log = 'C:\Temp\log' } } }
            (Install-PkgMsi -MsiPath $tmpMsi).Ok | Should -BeTrue
        } finally { Remove-Item -LiteralPath $tmpMsi -Force -ErrorAction SilentlyContinue }
    }

    It 'reports Ok=$true on exit 3010 (reboot required)' {
        $tmpMsi = Join-Path ([System.IO.Path]::GetTempPath()) ("fake-msi-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.msi')
        'msi-bytes' | Set-Content -LiteralPath $tmpMsi -Encoding ascii
        try {
            & $script:Pkg { Set-PkgInvoker -Name RunMsi -ScriptBlock { param($p,$x) [pscustomobject]@{ ExitCode = 3010; Log = 'C:\Temp\log' } } }
            (Install-PkgMsi -MsiPath $tmpMsi).Ok | Should -BeTrue
        } finally { Remove-Item -LiteralPath $tmpMsi -Force -ErrorAction SilentlyContinue }
    }

    It 'reports Ok=$false on a non-zero non-3010 exit' {
        $tmpMsi = Join-Path ([System.IO.Path]::GetTempPath()) ("fake-msi-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.msi')
        'msi-bytes' | Set-Content -LiteralPath $tmpMsi -Encoding ascii
        try {
            & $script:Pkg { Set-PkgInvoker -Name RunMsi -ScriptBlock { param($p,$x) [pscustomobject]@{ ExitCode = 1603; Log = 'C:\Temp\log' } } }
            $r = Install-PkgMsi -MsiPath $tmpMsi
            $r.Ok | Should -BeFalse
            $r.ExitCode | Should -Be 1603
        } finally { Remove-Item -LiteralPath $tmpMsi -Force -ErrorAction SilentlyContinue }
    }

    It 'reports Ok=$false when the MSI path does not exist' {
        $r = Install-PkgMsi -MsiPath 'C:\does\not\exist.msi'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'MSI not found'
    }
}

Describe 'Install-PkgViaWinget' {

    BeforeEach { & $script:Pkg { Reset-PkgInvoker } }

    It 'maps exit 0 to Ok=$true' {
        & $script:Pkg { Set-PkgInvoker -Name RunWinget -ScriptBlock { param($id,$v) [pscustomobject]@{ ExitCode = 0 } } }
        (Install-PkgViaWinget -Id 'Microsoft.PowerShell').Ok | Should -BeTrue
    }

    It 'maps any non-zero exit to Ok=$false' {
        & $script:Pkg { Set-PkgInvoker -Name RunWinget -ScriptBlock { param($id,$v) [pscustomobject]@{ ExitCode = 2 } } }
        (Install-PkgViaWinget -Id 'Foo.Bar').Ok | Should -BeFalse
    }
}

Describe 'Test-PkgInstalled' {

    BeforeEach { & $script:Pkg { Reset-PkgInvoker } }

    It 'returns Found=$true with details when the seam matches' {
        & $script:Pkg {
            Set-PkgInvoker -Name GetInstalledByName -ScriptBlock {
                param($re) [pscustomobject]@{ DisplayName = 'Node.js'; DisplayVersion = '20.11.0'; UninstallString = 'msiexec /x{...}' }
            }
        }
        $r = Test-PkgInstalled -NameRegex '^Node\.js'
        $r.Found | Should -BeTrue
        $r.DisplayName | Should -Be 'Node.js'
        $r.DisplayVersion | Should -Be '20.11.0'
    }

    It 'returns Found=$false when the seam returns $null' {
        & $script:Pkg { Set-PkgInvoker -Name GetInstalledByName -ScriptBlock { param($re) $null } }
        (Test-PkgInstalled -NameRegex 'no.such.product').Found | Should -BeFalse
    }
}
