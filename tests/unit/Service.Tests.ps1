#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Service.psm1'
    Get-Module Service | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:Svc = Get-Module Service
}

AfterAll {
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module Service | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ServiceStartType' {

    BeforeEach { & $script:Svc { Reset-ServiceInvoker } }

    It 'short-circuits when the current StartType already matches' {
        & $script:Svc {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
            Set-ServiceInvoker -Name SetStartType -ScriptBlock { param($n,$t) throw 'should not have been called' }
        }
        $r = Set-ServiceStartType -Name 'meshcentral' -StartType 'Automatic'
        $r.Ok | Should -BeTrue
        $r.Detail | Should -Match 'already correct'
    }

    It 'changes the StartType when it differs' {
        $script:cap = @{}
        $cap = $script:cap
        & $script:Svc {
            param($cap)
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Stopped'; StartType='Manual' } }
            Set-ServiceInvoker -Name SetStartType -ScriptBlock { param($n,$t) $cap.Name=$n; $cap.Type=$t }.GetNewClosure()
        }.GetNewClosure() $cap
        Set-ServiceStartType -Name 'mongod' -StartType 'Automatic' | Out-Null
        $script:cap.Name | Should -Be 'mongod'
        $script:cap.Type | Should -Be 'Automatic'
    }

    It 'reports Ok=$false when the service does not exist' {
        & $script:Svc { Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } } }
        $r = Set-ServiceStartType -Name 'no-such-svc' -StartType 'Manual'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'not installed'
    }
}

Describe 'Start-ServiceIdempotent / Stop-ServiceIdempotent' {

    BeforeEach { & $script:Svc { Reset-ServiceInvoker } }

    It 'returns "already running" when Status is already Running' {
        & $script:Svc {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
            Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) throw 'should not have been called' }
        }
        $r = Start-ServiceIdempotent -Name 'meshcentral' -WaitSeconds 1
        $r.Ok | Should -BeTrue
        $r.Detail | Should -Match 'already running'
    }

    It 'calls StartService and then waits for Running' {
        & $script:Svc {
            $script:probeState = 'Stopped'
            Set-ServiceInvoker -Name GetService -ScriptBlock {
                param($n) [pscustomobject]@{ Found=$true; Status=$script:probeState; StartType='Automatic' }
            }
            Set-ServiceInvoker -Name StartService -ScriptBlock {
                param($n) $script:probeState = 'Running'
            }
        }
        $r = Start-ServiceIdempotent -Name 'mongod' -WaitSeconds 2
        $r.Ok | Should -BeTrue
        $r.State | Should -Be 'Running'
    }

    It 'returns Ok=true on Stop when service is already Stopped' {
        & $script:Svc { Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Stopped'; StartType='Manual' } } }
        $r = Stop-ServiceIdempotent -Name 'mongod' -WaitSeconds 1
        $r.Ok | Should -BeTrue
        $r.Detail | Should -Match 'already stopped'
    }

    It 'Stop on a NotInstalled service is a no-op success' {
        & $script:Svc { Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } } }
        $r = Stop-ServiceIdempotent -Name 'no-such' -WaitSeconds 1
        $r.Ok | Should -BeTrue
        $r.Detail | Should -Match 'nothing to stop'
    }
}

Describe 'Wait-ServiceReady' {

    BeforeEach { & $script:Svc { Reset-ServiceInvoker } }

    It 'returns Ok=true once the desired state is observed' {
        & $script:Svc {
            $script:n = 0
            Set-ServiceInvoker -Name GetService -ScriptBlock {
                param($name)
                $script:n++
                if ($script:n -ge 2) { [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
                else { [pscustomobject]@{ Found=$true; Status='StartPending'; StartType='Automatic' } }
            }
        }
        $r = Wait-ServiceReady -Name 'x' -DesiredState Running -TimeoutSeconds 2 -PollMs 50
        $r.Ok | Should -BeTrue
        $r.State | Should -Be 'Running'
    }

    It 'reports a timeout when the state never converges' {
        & $script:Svc { Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='StartPending'; StartType='Automatic' } } }
        $r = Wait-ServiceReady -Name 'x' -DesiredState Running -TimeoutSeconds 1 -PollMs 50
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'timeout'
    }
}

Describe 'Install-NssmService' {

    BeforeEach { & $script:Svc { Reset-ServiceInvoker } }

    It 'invokes nssm install on a fresh service' {
        & $script:Svc {
            $script:probeAfter = $false
            $script:calls = New-Object System.Collections.Generic.List[object]
            Set-ServiceInvoker -Name GetService -ScriptBlock {
                param($n)
                if ($script:probeAfter) { [pscustomobject]@{ Found=$true; Status='Stopped'; StartType='Automatic' } }
                else { [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } }
            }
            Set-ServiceInvoker -Name RunNssm -ScriptBlock {
                param($argv) $script:calls.Add(@($argv)); $script:probeAfter = $true; [pscustomobject]@{ ExitCode = 0 }
            }
        }
        $r = Install-NssmService -Name 'cluster-announcer' -Executable 'C:\node\node.exe' -Arguments 'announcer.js' -DisplayName 'Cluster Announcer' -StartType Automatic
        $r.Ok | Should -BeTrue
        # First call should be 'install'.
        $firstCall = & $script:Svc { $script:calls[0] }
        $firstCall[0] | Should -Be 'install'
        $firstCall[1] | Should -Be 'cluster-announcer'
    }

    It 'invokes nssm set on an existing service (no duplicate install)' {
        $script:installSeen = $false
        & $script:Svc {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
            Set-ServiceInvoker -Name RunNssm -ScriptBlock {
                param($argv)
                if ($argv[0] -eq 'install') { $script:installSeen = $true }
                [pscustomobject]@{ ExitCode = 0 }
            }
        }
        Install-NssmService -Name 'cluster-announcer' -Executable 'C:\node\node.exe' | Out-Null
        $script:installSeen | Should -BeFalse
    }

    It 'reports Ok=$false when nssm exits non-zero' {
        & $script:Svc {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } }
            Set-ServiceInvoker -Name RunNssm -ScriptBlock { param($argv) [pscustomobject]@{ ExitCode = 1 } }
        }
        $r = Install-NssmService -Name 'x' -Executable 'C:\foo.exe'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'nssm install exited 1'
    }
}

Describe 'ConvertTo-NssmArgList (path-with-space quoting)' {
    # Regression test for bug 13: Start-Process -ArgumentList does not
    # auto-quote elements containing whitespace, which led to NSSM
    # registering Application='C:\Program' instead of the full pwsh path.

    It 'wraps space-bearing args in double quotes' {
        $out = ConvertTo-NssmArgList -Argv @('install','ClusterAnnouncer','C:\Program Files\PowerShell\7\pwsh.exe')
        $out[0] | Should -Be 'install'
        $out[1] | Should -Be 'ClusterAnnouncer'
        $out[2] | Should -Be '"C:\Program Files\PowerShell\7\pwsh.exe"'
    }

    It 'leaves args without whitespace untouched' {
        $out = ConvertTo-NssmArgList -Argv @('set','ClusterAnnouncer','Start','SERVICE_AUTO_START')
        $out | Should -Be @('set','ClusterAnnouncer','Start','SERVICE_AUTO_START')
    }

    It 'is idempotent on already-quoted values' {
        $out = ConvertTo-NssmArgList -Argv @('"already quoted"','plain')
        $out[0] | Should -Be '"already quoted"'
        $out[1] | Should -Be 'plain'
    }

    It 'preserves the inner-content even when AppParameters has nested quotes' {
        # AppParameters often contains -File "C:\foo bar\x.ps1" with spaces.
        $appParams = '-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ClusterController\bin\announcer.ps1"'
        $out = ConvertTo-NssmArgList -Argv @('set','ClusterAnnouncer','AppParameters',$appParams)
        # Outer quoting wraps the whole AppParameters string because it has whitespace.
        $out[3] | Should -Be ('"' + $appParams + '"')
    }
}
