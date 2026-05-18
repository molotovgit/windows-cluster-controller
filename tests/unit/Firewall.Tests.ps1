#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Firewall.psm1'
    Get-Module Firewall | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:Fw = Get-Module Firewall
}

AfterAll {
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module Firewall | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-IdempotentFirewallRule' {

    BeforeEach { & $script:Fw { Reset-FirewallInvoker } }

    It 'returns Action=created when no prior rule exists' {
        & $script:Fw {
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) $null }
            Set-FirewallInvoker -Name NewRule -ScriptBlock { param($s) }
        }
        $r = New-IdempotentFirewallRule -Name 'MeshCentral 443' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443
        $r.Ok     | Should -BeTrue
        $r.Action | Should -Be 'created'
    }

    It 'returns Action=unchanged when an identical rule exists' {
        & $script:Fw {
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n)
                [pscustomobject]@{ Name=$n; Enabled='True'; Direction='Inbound'; Action='Allow'; Profile='Domain,Private'; Protocol='TCP'; LocalPort='443'; LocalAddress=$null }
            }
            Set-FirewallInvoker -Name NewRule    -ScriptBlock { param($s) throw 'should not have been called' }
            Set-FirewallInvoker -Name RemoveRule -ScriptBlock { param($n) throw 'should not have been called' }
        }
        $r = New-IdempotentFirewallRule -Name 'MeshCentral 443' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443
        $r.Action | Should -Be 'unchanged'
    }

    It 'returns Action=replaced when the existing rule has a different port' {
        $script:removed = $false
        & $script:Fw {
            $script:removed = $false
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n)
                [pscustomobject]@{ Name=$n; Enabled='True'; Direction='Inbound'; Action='Allow'; Profile='Domain,Private'; Protocol='TCP'; LocalPort='8443'; LocalAddress=$null }
            }
            Set-FirewallInvoker -Name RemoveRule -ScriptBlock { param($n) $script:removed = $true }
            Set-FirewallInvoker -Name NewRule -ScriptBlock { param($s) }
        }
        $r = New-IdempotentFirewallRule -Name 'MeshCentral 443' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443
        $r.Action | Should -Be 'replaced'
        $removeSeen = & $script:Fw { $script:removed }
        $removeSeen | Should -BeTrue
    }

    It 'honors LocalAddress for the MongoDB-loopback pattern' {
        $script:capturedSpec = $null
        & $script:Fw {
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) $null }
            Set-FirewallInvoker -Name NewRule -ScriptBlock { param($s) $script:capturedSpec = $s }
        }
        New-IdempotentFirewallRule -Name 'mongod-loopback' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 27017 -LocalAddress '127.0.0.1' | Out-Null
        $spec = & $script:Fw { $script:capturedSpec }
        $spec.LocalAddress | Should -Be '127.0.0.1'
    }

    It 'surfaces NewRule failure as Ok=$false' {
        & $script:Fw {
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) $null }
            Set-FirewallInvoker -Name NewRule -ScriptBlock { param($s) throw 'access denied' }
        }
        $r = New-IdempotentFirewallRule -Name 'X' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'access denied'
    }
}

Describe 'Remove-IdempotentFirewallRule' {

    BeforeEach { & $script:Fw { Reset-FirewallInvoker } }

    It 'reports absent when rule is not present' {
        & $script:Fw { Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) $null } }
        $r = Remove-IdempotentFirewallRule -Name 'no-such'
        $r.Ok | Should -BeTrue
        $r.Action | Should -Be 'absent'
    }

    It 'invokes RemoveRule when the rule exists' {
        $script:removed = $false
        & $script:Fw {
            $script:removed = $false
            Set-FirewallInvoker -Name GetRule -ScriptBlock { param($n) [pscustomobject]@{ Name=$n; Enabled='True'; Direction='Inbound'; Action='Allow'; Profile='Domain'; Protocol='TCP'; LocalPort='443'; LocalAddress=$null } }
            Set-FirewallInvoker -Name RemoveRule -ScriptBlock { param($n) $script:removed = $true }
        }
        $r = Remove-IdempotentFirewallRule -Name 'X'
        $r.Action | Should -Be 'removed'
        $removeSeen = & $script:Fw { $script:removed }
        $removeSeen | Should -BeTrue
    }
}
