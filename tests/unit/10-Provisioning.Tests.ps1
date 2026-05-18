#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    foreach ($mod in 'Logging','Config') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERCTRL_ALLOW_TEST_SEAMS = '1'
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("prov-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    $env:CLUSTERCTRL_LOG_DIR   = Join-Path $script:tmp 'logs'
    $env:CLUSTERCTRL_STATE_DIR = Join-Path $script:tmp 'state'

    . (Join-Path $repoRoot 'src\stages\10-Provisioning.ps1')

    # Standard happy-path mocks used across most tests. Tests can override
    # specific invokers after calling this.
    function Set-HappyProvisioningMocks {
        param([hashtable]$Caps)
        # ResolveMeshcentralRoot returns a temp dir that has the expected
        # node_modules\meshcentral\meshcentral.js sub-path (else Stage 10
        # will Fail with "meshcentral.js not found").
        $mcRoot = Join-Path $script:tmp ("mcroot-" + [guid]::NewGuid().ToString('N').Substring(0,6))
        $entryDir = Join-Path $mcRoot 'node_modules\meshcentral'
        New-Item -Path $entryDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $entryDir 'meshcentral.js') -Value '// stub' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $entryDir 'meshctrl.js')   -Value '// stub' -Encoding ascii
        Set-ProvisioningInvoker -Name ResolveMeshcentralRoot -ScriptBlock { $mcRoot }.GetNewClosure()
        Set-ProvisioningInvoker -Name StopService -ScriptBlock { param($n,$w) $Caps.Calls.Add("Stop:$n"); [pscustomobject]@{ Ok=$true; Already=$false; Detail='stopped' } }.GetNewClosure()
        Set-ProvisioningInvoker -Name StartService -ScriptBlock { param($n,$w) $Caps.Calls.Add("Start:$n"); [pscustomobject]@{ Ok=$true; Detail='running' } }.GetNewClosure()
        Set-ProvisioningInvoker -Name CreateAccount -ScriptBlock {
            param($n,$e,$d,$u,$p,$em)
            $Caps.Calls.Add("CreateAccount:$u")
            [pscustomobject]@{ ExitCode = 0; Stdout = 'Done.'; Stderr = '' }
        }.GetNewClosure()
        Set-ProvisioningInvoker -Name PromoteAdmin -ScriptBlock {
            param($n,$e,$d,$u)
            $Caps.Calls.Add("PromoteAdmin:$u")
            [pscustomobject]@{ ExitCode = 0; Stdout = 'Done.'; Stderr = '' }
        }.GetNewClosure()
        # RunMeshctrl: default response is benign success. Tests can override
        # for verb-specific behavior (Set-MeshctrlVerbResponse below).
        $Caps.MeshctrlVerbs = @{}
        Set-ProvisioningInvoker -Name RunMeshctrl -ScriptBlock {
            param($verb, $args, $auth)
            $Caps.Calls.Add("Meshctrl:$verb")
            if ($Caps.MeshctrlVerbs.ContainsKey($verb)) {
                return & $Caps.MeshctrlVerbs[$verb] $args
            }
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }.GetNewClosure()
        Set-ProvisioningInvoker -Name NewSecurePassword   -ScriptBlock { param($l) 'fakepass1234567890' }
        Set-ProvisioningInvoker -Name WriteAdminBootstrap -ScriptBlock { param($p,$b) $Caps.Calls.Add("WriteBootstrap:$p") }.GetNewClosure()
        Set-ProvisioningInvoker -Name EnsureDir           -ScriptBlock { param($p) $Caps.Calls.Add("EnsureDir:$p") }.GetNewClosure()
        Set-ProvisioningInvoker -Name FileExists          -ScriptBlock { param($p) $true }
        return $mcRoot
    }

    function New-Caps {
        # Use a hashtable (mutable, hashtable-typed param-compatible) so
        # closures can append to .Calls and .MeshctrlVerbs.
        $h = @{}
        $h.Calls = New-Object System.Collections.Generic.List[string]
        $h.MeshctrlVerbs = @{}
        return $h
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_LOG_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_STATE_DIR       -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERCTRL_ADMIN_PASS      -ErrorAction SilentlyContinue
}

Describe 'Invoke-ProvisioningStage' {

    BeforeEach { Reset-ProvisioningInvoker }

    It 'returns Pass via -DryRun without touching any service' {
        $caps = New-Caps
        Set-HappyProvisioningMocks -Caps $caps | Out-Null
        $r = Invoke-ProvisioningStage -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
        # No real work touched.
        @($caps.Calls | Where-Object { $_ -like 'Stop:*' -or $_ -like 'CreateAccount:*' }).Count | Should -Be 0
    }

    It 'happy path: stops MC, creates account, promotes admin, restarts, runs ServerInfo + group create' {
        $caps = New-Caps
        Set-HappyProvisioningMocks -Caps $caps | Out-Null
        # ServerInfo + ListDeviceGroups return realistic stdout so verification short-circuits add path.
        $caps.MeshctrlVerbs['ServerInfo'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='name: controller.lan'; Stderr='' } }
        $caps.MeshctrlVerbs['ListDeviceGroups'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout=@"
id, name
---------------
"$(('a' * 64))", "cluster-hosts"
"$(('b' * 64))", "cluster-vms"
"@; Stderr='' } }
        $caps.MeshctrlVerbs['AgentDownload'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='Downloaded 3484256 byte(s) to "meshagent64-X.exe"'; Stderr='' } }
        $r = Invoke-ProvisioningStage 6>$null
        $r.Overall | Should -BeIn 'Pass','Warn'
        # Service stop/start + account create + promote all ran in order.
        $callOrder = $caps.Calls -join '|'
        $callOrder | Should -Match 'Stop:meshcentral\.exe'
        $callOrder | Should -Match 'CreateAccount:clusteradmin'
        $callOrder | Should -Match 'PromoteAdmin:clusteradmin'
        $callOrder | Should -Match 'Start:meshcentral\.exe'
        # Should NOT call AddDeviceGroup because both groups already in ListDeviceGroups stdout.
        @($caps.Calls | Where-Object { $_ -eq 'Meshctrl:AddDeviceGroup' }).Count | Should -Be 0
    }

    It 'creates a missing device group then verifies via ListDeviceGroups (bug 19 regression)' {
        $caps = New-Caps
        Set-HappyProvisioningMocks -Caps $caps | Out-Null
        $caps.MeshctrlVerbs['ServerInfo'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='name: controller.lan'; Stderr='' } }
        # First list call: empty. After AddDeviceGroup: group present.
        $script:listCallCount = 0
        $caps.MeshctrlVerbs['ListDeviceGroups'] = { param($a)
            $script:listCallCount++
            if ($script:listCallCount -le 1) {
                [pscustomobject]@{ ExitCode=0; Stdout='id, name`n---------------'; Stderr='' }
            } else {
                [pscustomobject]@{ ExitCode=0; Stdout=@"
id, name
---------------
"$(('c' * 64))", "cluster-hosts"
"$(('d' * 64))", "cluster-vms"
"@; Stderr='' }
            }
        }.GetNewClosure()
        $caps.MeshctrlVerbs['AddDeviceGroup'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='ok mesh//deadbeef'; Stderr='' } }
        $caps.MeshctrlVerbs['AgentDownload'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='Downloaded 100 byte(s)'; Stderr='' } }
        $r = Invoke-ProvisioningStage 6>$null
        @($caps.Calls | Where-Object { $_ -eq 'Meshctrl:AddDeviceGroup' }).Count | Should -Be 2
        ($r.Steps | Where-Object { $_.Name -like "Device group 'cluster-hosts'" }).Status | Should -Be 'Pass'
    }

    It 'detects meshctrl auth failure and aborts (bug 19 regression: silent exit 0 on Invalid login)' {
        $caps = New-Caps
        Set-HappyProvisioningMocks -Caps $caps | Out-Null
        $caps.MeshctrlVerbs['ServerInfo'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='Invalid login.'; Stderr='' } }
        $r = Invoke-ProvisioningStage 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'meshctrl auth check').Status | Should -Be 'Fail'
        # Must NOT have proceeded to group creation.
        @($caps.Calls | Where-Object { $_ -eq 'Meshctrl:AddDeviceGroup' -or $_ -eq 'Meshctrl:ListDeviceGroups' }).Count | Should -BeLessOrEqual 0
    }

    It 'fails when CreateAccount returns unexpected stdout (bug 20 regression)' {
        $caps = New-Caps
        Set-HappyProvisioningMocks -Caps $caps | Out-Null
        Set-ProvisioningInvoker -Name CreateAccount -ScriptBlock {
            param($n,$e,$d,$u,$p,$em)
            $caps.Calls.Add("CreateAccount:$u")
            [pscustomobject]@{ ExitCode = 0; Stdout = 'Bad arguments'; Stderr = '' }
        }.GetNewClosure()
        $r = Invoke-ProvisioningStage 6>$null
        $r.Overall | Should -BeIn 'Warn','Fail'
        ($r.Steps | Where-Object { $_.Name -like 'Create account*' }).Status | Should -BeIn 'Warn','Fail'
        # Service must be restored even on the warn path.
        @($caps.Calls | Where-Object { $_ -like 'Start:meshcentral.exe' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'treats "already exists" CreateAccount output as Pass (idempotent re-run)' {
        $caps = New-Caps
        Set-HappyProvisioningMocks -Caps $caps | Out-Null
        Set-ProvisioningInvoker -Name CreateAccount -ScriptBlock {
            param($n,$e,$d,$u,$p,$em)
            [pscustomobject]@{ ExitCode = 0; Stdout = 'Account already exists.'; Stderr = '' }
        }.GetNewClosure()
        $caps.MeshctrlVerbs['ServerInfo'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='name: controller.lan'; Stderr='' } }
        $caps.MeshctrlVerbs['ListDeviceGroups'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout=@"
id, name
---------------
"$(('a' * 64))", "cluster-hosts"
"$(('b' * 64))", "cluster-vms"
"@; Stderr='' } }
        $r = Invoke-ProvisioningStage 6>$null
        ($r.Steps | Where-Object { $_.Name -like 'Create account*' }).Status | Should -Be 'Pass'
    }

    It 'falls back to config-derived data_dir when ResolveMeshcentralRoot returns null' {
        $caps = New-Caps
        Set-HappyProvisioningMocks -Caps $caps | Out-Null
        Set-ProvisioningInvoker -Name ResolveMeshcentralRoot -ScriptBlock { $null }
        # Will Fail at the "Locate meshcentral.js" step because config-derived
        # fallback isn't a real install, but the step ordering proves the
        # fallback fired.
        $r = Invoke-ProvisioningStage 6>$null
        ($r.Steps | Where-Object Name -eq 'Resolve MeshCentral root').Status | Should -Be 'Warn'
    }

    It 'does NOT write admin-bootstrap.txt when password sourced from env var' {
        $env:CLUSTERCTRL_ADMIN_PASS = 'OperatorChose-AStrong-Pass'
        try {
            $caps = New-Caps
            Set-HappyProvisioningMocks -Caps $caps | Out-Null
            $caps.MeshctrlVerbs['ServerInfo'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout='name: controller.lan'; Stderr='' } }
            $caps.MeshctrlVerbs['ListDeviceGroups'] = { param($a) [pscustomobject]@{ ExitCode=0; Stdout=@"
id, name
---------------
"$(('e' * 64))", "cluster-hosts"
"$(('f' * 64))", "cluster-vms"
"@; Stderr='' } }
            Invoke-ProvisioningStage 6>$null | Out-Null
            @($caps.Calls | Where-Object { $_ -like 'WriteBootstrap:*' }).Count | Should -Be 0
        } finally {
            Remove-Item Env:CLUSTERCTRL_ADMIN_PASS -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-MeshctrlSuccess (bug 19 regression)' {
    It 'detects Invalid login' {
        $r = Test-MeshctrlSuccess -Stdout 'Invalid login.'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'Invalid login'
    }
    It 'detects Invalid meshid' {
        (Test-MeshctrlSuccess -Stdout 'Invalid meshid.').Ok | Should -BeFalse
    }
    It 'detects ECONNREFUSED from stderr' {
        (Test-MeshctrlSuccess -Stdout '' -Stderr 'Error: connect ECONNREFUSED 127.0.0.1:443').Ok | Should -BeFalse
    }
    It 'returns Ok on benign output' {
        (Test-MeshctrlSuccess -Stdout 'name: foo').Ok | Should -BeTrue
    }
}

Describe 'Get-MeshidFromGroupListing' {
    It 'extracts the 64-char meshid for a named group' {
        $id = 'x' * 64
        $listing = @"
id, name
---------------
"$id", "cluster-hosts"
"$('y' * 64)", "cluster-vms"
"@
        (Get-MeshidFromGroupListing -Stdout $listing -GroupName 'cluster-hosts') | Should -Be $id
    }
    It 'returns null when the group is not present' {
        $listing = 'id, name`n---------------'
        Get-MeshidFromGroupListing -Stdout $listing -GroupName 'cluster-hosts' | Should -BeNullOrEmpty
    }
    It 'ignores 65-char ids (defensive against malformed output)' {
        $listing = @"
id, name
"$('z' * 65)", "cluster-hosts"
"@
        Get-MeshidFromGroupListing -Stdout $listing -GroupName 'cluster-hosts' | Should -BeNullOrEmpty
    }
}
