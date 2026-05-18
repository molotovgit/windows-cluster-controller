#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Pkg','Retry','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mc-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\06-Meshcentral.ps1')
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
}

Describe 'Format-MeshcentralConfig' {
    It 'embeds the controller hostname in cert + domain title' {
        $j = Format-MeshcentralConfig -Hostname 'controller.lan'
        $j | Should -Match '"cert":\s*"controller\.lan"'
        $j | Should -Match '"title2":\s*"controller\.lan"'
    }
    It 'omits mongoDb in NeDB mode (no MongoUrl)' {
        $j = Format-MeshcentralConfig -Hostname 'x.lan'
        $j | Should -Not -Match 'mongoDb'
    }
    It 'includes mongoDb when MongoUrl is set' {
        $j = Format-MeshcentralConfig -Hostname 'x.lan' -MongoUrl 'mongodb://127.0.0.1:27017/meshcentral'
        $j | Should -Match 'mongodb://127\.0\.0\.1:27017/meshcentral'
    }
    It 'sets agentport equal to port when AgentsSameAsHttps=true' {
        $j = Format-MeshcentralConfig -Hostname 'x.lan' -HttpsPort 443 -AgentPort 4433 -AgentsSameAsHttps $true
        $j | Should -Match '"agentport":\s*443'
    }
    It 'sets agentport to AgentPort when AgentsSameAsHttps=false' {
        $j = Format-MeshcentralConfig -Hostname 'x.lan' -HttpsPort 443 -AgentPort 4433 -AgentsSameAsHttps $false
        $j | Should -Match '"agentport":\s*4433'
    }
}

Describe 'Invoke-MeshcentralStage' {

    BeforeEach { Reset-MeshcentralInvoker }

    It 'returns Pass via -DryRun without invoking any seams' {
        Set-MeshcentralInvoker -Name EnsureDir              -ScriptBlock { param($p) throw 'should not be called' }
        Set-MeshcentralInvoker -Name RunNpmInstallMeshcentral -ScriptBlock { param($r,$v) throw 'should not be called' }
        $r = Invoke-MeshcentralStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'short-circuits npm install when meshcentral.js already exists' {
        Set-MeshcentralInvoker -Name EnsureDir              -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name ApplyStrictAcl          -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name TestMeshcentralInstalled -ScriptBlock { param($r) $true }
        Set-MeshcentralInvoker -Name RunNpmInstallMeshcentral -ScriptBlock { param($r,$v) throw 'should not have been called' }
        Set-MeshcentralInvoker -Name WriteConfigJson         -ScriptBlock { param($p,$b) }
        $r = Invoke-MeshcentralStage 6>$null
        $r.Overall | Should -Be 'Pass'
        ($r.Steps | Where-Object Name -eq 'npm install meshcentral').Detail | Should -Match 'already present'
    }

    It 'runs npm install when meshcentral.js is missing' {
        $script:probeCalls = 0
        Set-MeshcentralInvoker -Name EnsureDir              -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name ApplyStrictAcl          -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name TestMeshcentralInstalled -ScriptBlock {
            param($r) $script:probeCalls++; ($script:probeCalls -ge 2)
        }
        Set-MeshcentralInvoker -Name RunNpmInstallMeshcentral -ScriptBlock { param($r,$v) [pscustomobject]@{ ExitCode = 0 } }
        Set-MeshcentralInvoker -Name WriteConfigJson         -ScriptBlock { param($p,$b) }
        $r = Invoke-MeshcentralStage 6>$null
        $r.Overall | Should -Be 'Pass'
    }

    It 'returns Fail when npm exits non-zero' {
        Set-MeshcentralInvoker -Name EnsureDir              -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name ApplyStrictAcl          -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name TestMeshcentralInstalled -ScriptBlock { param($r) $false }
        Set-MeshcentralInvoker -Name RunNpmInstallMeshcentral -ScriptBlock { param($r,$v) [pscustomobject]@{ ExitCode = 1 } }
        $r = Invoke-MeshcentralStage 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Detail  | Should -Match 'npm install meshcentral exited 1'
    }

    It 'writes config.json with a body the test seam can capture' {
        $script:probe = @{ body = $null; path = $null }
        $probe = $script:probe
        Set-MeshcentralInvoker -Name EnsureDir              -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name ApplyStrictAcl          -ScriptBlock { param($p) }
        Set-MeshcentralInvoker -Name TestMeshcentralInstalled -ScriptBlock { param($r) $true }
        Set-MeshcentralInvoker -Name WriteConfigJson         -ScriptBlock { param($p,$b) $probe.path = $p; $probe.body = $b }.GetNewClosure()
        $r = Invoke-MeshcentralStage 6>$null
        ($r.Steps | Where-Object Name -eq 'Write config.json').Status | Should -Be 'Pass'
        $script:probe.body | Should -Not -BeNullOrEmpty
        $script:probe.body | Should -Match '"cert":\s*"controller\.lan"'
        $script:probe.path | Should -Match 'config\.json$'
    }
}
