#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Net.psm1'

    Get-Module Net | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:Net = Get-Module Net
}

AfterAll {
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module Net | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-NetPortInUse / Test-NetTcpOpen' {

    BeforeEach {
        & $script:Net { Reset-NetInvoker }
    }

    It 'returns $true when TestTcp seam reports an open port' {
        & $script:Net { Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true } }
        Test-NetPortInUse -Port 443 | Should -BeTrue
    }

    It 'returns $false when TestTcp seam reports closed' {
        & $script:Net { Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $false } }
        Test-NetPortInUse -Port 443 | Should -BeFalse
    }

    It 'passes the right address+port+timeout into the seam' {
        $script:capture = @{}
        $cap = $script:capture
        & $script:Net {
            param($cap)
            Set-NetInvoker -Name TestTcp -ScriptBlock {
                param($a,$p,$t)
                $cap.Address  = $a
                $cap.Port     = $p
                $cap.Timeout  = $t
                $true
            }.GetNewClosure()
        }.GetNewClosure() $cap
        Test-NetTcpOpen -Address '10.0.0.7' -Port 4433 -TimeoutMs 800 | Out-Null
        $script:capture.Address | Should -Be '10.0.0.7'
        $script:capture.Port    | Should -Be 4433
        $script:capture.Timeout | Should -Be 800
    }
}

Describe 'Find-NetFreePort' {

    BeforeEach { & $script:Net { Reset-NetInvoker } }

    It 'returns the first candidate not currently in use' {
        & $script:Net {
            Set-NetInvoker -Name TestTcp -ScriptBlock {
                param($a,$p,$t)
                # 443 + 4433 are "in use"; 8765 is free.
                $p -in 443,4433
            }
        }
        Find-NetFreePort -CandidatePorts @(443,4433,8765,8766) | Should -Be 8765
    }

    It 'returns $null when every candidate is in use' {
        & $script:Net { Set-NetInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) $true } }
        Find-NetFreePort -CandidatePorts @(80,81,82) | Should -BeNullOrEmpty
    }
}

Describe 'Test-NetHttpReachable' {

    BeforeEach { & $script:Net { Reset-NetInvoker } }

    It 'reports Ok=$true when status and body match' {
        & $script:Net {
            Set-NetInvoker -Name HttpProbe -ScriptBlock {
                param($u,$t) [pscustomobject]@{ Status = 200; Body = '<title>MeshCentral</title>' }
            }
        }
        $r = Test-NetHttpReachable -Url 'https://controller.lan/' -ExpectMatch 'MeshCentral'
        $r.Ok     | Should -BeTrue
        $r.Status | Should -Be 200
    }

    It 'reports Ok=$false when the server is unreachable (probe returns $null)' {
        & $script:Net { Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) $null } }
        $r = Test-NetHttpReachable -Url 'https://nope/'
        $r.Ok     | Should -BeFalse
        $r.Status | Should -Be 0
        $r.Reason | Should -Be 'no-response'
    }

    It 'reports Ok=$false when status mismatches' {
        & $script:Net {
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 503; Body = '' } }
        }
        $r = Test-NetHttpReachable -Url 'https://x/'
        $r.Ok     | Should -BeFalse
        $r.Reason | Should -Match '503'
    }

    It 'reports Ok=$false when body does not match expected regex' {
        & $script:Net {
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = 'no mesh here' } }
        }
        $r = Test-NetHttpReachable -Url 'https://x/' -ExpectMatch 'MeshCentral'
        $r.Ok     | Should -BeFalse
        $r.Reason | Should -Match 'body did not match'
    }

    It 'ExpectStatus=0 accepts any 2xx' {
        & $script:Net {
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 204; Body = '' } }
        }
        (Test-NetHttpReachable -Url 'https://x/' -ExpectStatus 0).Ok | Should -BeTrue
    }
}

Describe 'Resolve-NetHostName / Get-NetLocalIPv4 / Get-NetDefaultGateway' {

    BeforeEach { & $script:Net { Reset-NetInvoker } }

    It 'returns the IP that the Resolve seam reports' {
        & $script:Net { Set-NetInvoker -Name Resolve -ScriptBlock { param($n) if ($n -eq 'controller.lan') { '10.0.0.7' } else { $null } } }
        Resolve-NetHostName 'controller.lan' | Should -Be '10.0.0.7'
        Resolve-NetHostName 'no-such.host'   | Should -BeNullOrEmpty
    }

    It 'returns the LocalIPv4 array from the seam' {
        & $script:Net {
            Set-NetInvoker -Name LocalIPv4 -ScriptBlock {
                @([pscustomobject]@{ IPAddress = '192.168.1.5'; PrefixLength = 24; InterfaceAlias = 'Wi-Fi' })
            }
        }
        $r = Get-NetLocalIPv4
        $r.Count | Should -Be 1
        $r[0].IPAddress | Should -Be '192.168.1.5'
    }

    It 'returns the DefaultGateway from the seam' {
        & $script:Net { Set-NetInvoker -Name DefaultGateway -ScriptBlock { '192.168.1.1' } }
        Get-NetDefaultGateway | Should -Be '192.168.1.1'
    }
}

Describe 'Test seam guard' {

    It 'Set-NetInvoker throws when CLUSTERCTRL_ALLOW_TEST_SEAMS is unset' {
        Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { & $script:Net { Set-NetInvoker -Name TestTcp -ScriptBlock {} } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERCTRL_ALLOW_TEST_SEAMS'
        $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'   # restore for subsequent tests
    }
}
