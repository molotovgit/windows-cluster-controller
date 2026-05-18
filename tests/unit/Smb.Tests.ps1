#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Smb.psm1'
    Get-Module Smb | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:Smb = Get-Module Smb

    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("smb-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module Smb | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-IdempotentSmbShare' {
    BeforeEach { & $script:Smb { Reset-SmbInvoker } }

    It 'refuses when the backing path does not exist' {
        $r = New-IdempotentSmbShare -Name 'X' -Path 'C:\does\not\exist'
        $r.Ok | Should -BeFalse
        $r.Action | Should -Be 'path-missing'
    }

    It 'creates a new share when none exists' {
        & $script:Smb {
            Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Path=$null; Description=$null } }
            Set-SmbInvoker -Name NewShare -ScriptBlock { param($s) }
        }
        $r = New-IdempotentSmbShare -Name 'ClusterShare' -Path $script:tmp -Description 'cluster share'
        $r.Ok | Should -BeTrue
        $r.Action | Should -Be 'created'
    }

    It 'returns unchanged when share exists with same path + description' {
        & $script:Smb { $script:fixedPath = $args[0] } $script:tmp
        & $script:Smb {
            Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path=$script:fixedPath; Description='cluster share' } }
            Set-SmbInvoker -Name NewShare -ScriptBlock { param($s) throw 'should not be called' }
        }
        $r = New-IdempotentSmbShare -Name 'ClusterShare' -Path $script:tmp -Description 'cluster share'
        $r.Action | Should -Be 'unchanged'
    }

    It 'refuses to silently re-point an existing share to a different path' {
        $other = Join-Path ([System.IO.Path]::GetTempPath()) ("smb-other-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -Path $other -ItemType Directory -Force | Out-Null
        try {
            & $script:Smb { $script:otherPath = $args[0] } $other
            & $script:Smb {
                Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path=$script:otherPath; Description='' } }
            }
            $r = New-IdempotentSmbShare -Name 'ClusterShare' -Path $script:tmp
            $r.Ok | Should -BeFalse
            $r.Action | Should -Be 'path-conflict'
        } finally {
            Remove-Item -LiteralPath $other -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Remove-IdempotentSmbShare' {
    BeforeEach { & $script:Smb { Reset-SmbInvoker } }

    It 'is a no-op success when share is absent' {
        & $script:Smb { Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Path=$null; Description=$null } } }
        (Remove-IdempotentSmbShare -Name 'X').Action | Should -Be 'absent'
    }

    It 'invokes RemoveShare when share is present' {
        $script:removed = $false
        & $script:Smb {
            $script:removed = $false
            Set-SmbInvoker -Name GetShare -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Path='C:\Y'; Description='' } }
            Set-SmbInvoker -Name RemoveShare -ScriptBlock { param($n) $script:removed = $true }
        }
        Remove-IdempotentSmbShare -Name 'X' | Out-Null
        (& $script:Smb { $script:removed }) | Should -BeTrue
    }
}
