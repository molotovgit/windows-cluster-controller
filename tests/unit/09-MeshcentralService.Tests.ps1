#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Service','Net','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mc-svc-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\09-MeshcentralService.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Invoke-MeshcentralServiceStage' {

    BeforeEach {
        Reset-MeshcentralServiceInvoker
        & (Get-Module Service) { Reset-ServiceInvoker }
        & (Get-Module Net)     { Reset-NetInvoker }
    }

    It 'returns Pass via -DryRun without calling install seams' {
        Set-MeshcentralServiceInvoker -Name TestNodeOnPath -ScriptBlock { throw 'should not be called' }
        $r = Invoke-MeshcentralServiceStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'returns Fail when node is not on PATH' {
        Set-MeshcentralServiceInvoker -Name TestNodeOnPath -ScriptBlock { $null }
        $r = Invoke-MeshcentralServiceStage 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail | Should -Match 'node missing'
    }

    It 'happy path: built-in installer succeeds + service starts + HTTPS probe ok' {
        Set-MeshcentralServiceInvoker -Name TestNodeOnPath        -ScriptBlock { 'C:\Program Files\nodejs\node.exe' }
        Set-MeshcentralServiceInvoker -Name RunMeshcentralInstall -ScriptBlock { param($n,$e,$w) [pscustomobject]@{ ExitCode = 0 } }
        # Make the entrypoint exist so the built-in path is attempted.
        $cfg = Get-ControllerConfigDefault
        $entry = Join-Path (Expand-ConfigPath -Value $cfg.meshcentral.data_dir) '..\node_modules\meshcentral\meshcentral.js'
        $entryDir = Split-Path -Parent $entry
        if (-not (Test-Path -LiteralPath $entryDir)) { New-Item -Path $entryDir -ItemType Directory -Force | Out-Null }
        'js' | Set-Content -LiteralPath $entry -Encoding ascii
        try {
            & (Get-Module Service) {
                $script:state = 'NotInstalled'
                Set-ServiceInvoker -Name GetService -ScriptBlock {
                    param($n)
                    if ($script:state -eq 'NotInstalled') { [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } }
                    elseif ($script:state -eq 'Stopped')  { [pscustomobject]@{ Found=$true; Status='Stopped'; StartType='Automatic' } }
                    else { [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
                }
                Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) $script:state = 'Running' }
                Set-ServiceInvoker -Name SetStartType -ScriptBlock { param($n,$t) }
                # Built-in install path doesn't go through NSSM, but if it would,
                # also make NSSM succeed to register the post-install probe.
                Set-ServiceInvoker -Name RunNssm -ScriptBlock { param($a) $script:state = 'Stopped'; [pscustomobject]@{ ExitCode = 0 } }
            }
            & (Get-Module Net) {
                Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = '<title>MeshCentral</title>' } }
            }
            # Simulate the post-install GetService returning Found=true after RunMeshcentralInstall.
            & (Get-Module Service) {
                $script:installCallCount = 0
                Set-ServiceInvoker -Name GetService -ScriptBlock {
                    param($n)
                    $script:installCallCount++
                    if ($script:installCallCount -le 1) { [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } }
                    elseif ($script:installCallCount -eq 2) { [pscustomobject]@{ Found=$true; Status='Stopped'; StartType='Automatic' } }
                    else { [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
                }
                Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) }
            }
            $r = Invoke-MeshcentralServiceStage -Config $cfg -ReadyWaitSeconds 2 6>$null
            $r.Overall | Should -BeIn 'Pass','Warn'
            ($r.Steps | Where-Object Name -eq 'Install MeshCentral service (built-in)').Status | Should -Be 'Pass'
        } finally {
            Remove-Item -LiteralPath $entryDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to NSSM when built-in installer exits non-zero' {
        Set-MeshcentralServiceInvoker -Name TestNodeOnPath        -ScriptBlock { 'C:\node.exe' }
        Set-MeshcentralServiceInvoker -Name RunMeshcentralInstall -ScriptBlock { param($n,$e,$w) [pscustomobject]@{ ExitCode = 7 } }
        # Make entry exist so primary is attempted.
        $cfg = Get-ControllerConfigDefault
        $entry = Join-Path (Expand-ConfigPath -Value $cfg.meshcentral.data_dir) '..\node_modules\meshcentral\meshcentral.js'
        $entryDir = Split-Path -Parent $entry
        if (-not (Test-Path -LiteralPath $entryDir)) { New-Item -Path $entryDir -ItemType Directory -Force | Out-Null }
        'js' | Set-Content -LiteralPath $entry -Encoding ascii
        try {
            & (Get-Module Service) {
                $script:installCallCount = 0
                Set-ServiceInvoker -Name GetService -ScriptBlock {
                    param($n)
                    $script:installCallCount++
                    if ($script:installCallCount -le 1) { [pscustomobject]@{ Found=$false; Status='NotInstalled'; StartType=$null } }
                    else { [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
                }
                Set-ServiceInvoker -Name StartService -ScriptBlock { param($n) }
                Set-ServiceInvoker -Name SetStartType -ScriptBlock { param($n,$t) }
                Set-ServiceInvoker -Name RunNssm -ScriptBlock { param($a) [pscustomobject]@{ ExitCode = 0 } }
            }
            & (Get-Module Net) {
                Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) [pscustomobject]@{ Status = 200; Body = '' } }
            }
            $r = Invoke-MeshcentralServiceStage -Config $cfg -ReadyWaitSeconds 2 6>$null
            $r.Overall | Should -BeIn 'Pass','Warn'
            ($r.Steps | Where-Object Name -eq 'Install MeshCentral service (NSSM)').Status | Should -Be 'Pass'
        } finally {
            Remove-Item -LiteralPath $entryDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns Warn (not Fail) when service is Running but HTTPS does not respond yet' {
        Set-MeshcentralServiceInvoker -Name TestNodeOnPath -ScriptBlock { 'C:\node.exe' }
        & (Get-Module Service) {
            Set-ServiceInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found=$true; Status='Running'; StartType='Automatic' } }
            Set-ServiceInvoker -Name SetStartType -ScriptBlock { param($n,$t) }
        }
        & (Get-Module Net) {
            Set-NetInvoker -Name HttpProbe -ScriptBlock { param($u,$t) $null }
        }
        $r = Invoke-MeshcentralServiceStage -ReadyWaitSeconds 2 6>$null
        $r.Overall | Should -Be 'Warn'
    }
}
