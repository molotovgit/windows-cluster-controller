#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $script:installPs1 = Join-Path $script:repoRoot 'install.ps1'

    # Dot-source with the auto-run main block disabled.
    $env:CLUSTERCTRL_NOAUTORUN = '1'
    . $script:installPs1
}

AfterAll {
    Remove-Item Env:CLUSTERCTRL_NOAUTORUN -ErrorAction SilentlyContinue
}

Describe 'install.ps1 helpers' {

    It 'Test-IsAdministrator returns a Boolean' {
        $result = Test-IsAdministrator
        $result.GetType().Name | Should -Be 'Boolean'
    }

    It 'Resolve-ZipUrl honors -Override' {
        Resolve-ZipUrl -Override 'https://x/y.zip' | Should -Be 'https://x/y.zip'
    }

    It 'Resolve-ZipUrl returns $null when no source is set' {
        Remove-Item Env:CLUSTERCTRL_REPO_ZIP -ErrorAction SilentlyContinue
        Resolve-ZipUrl -Override '' | Should -BeNullOrEmpty
    }

    It 'Write-StarterConfig writes JSON with the supplied hostname' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("starter-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
        try {
            Write-StarterConfig -Path $tmp -Controller 'ctrl.lan'
            Test-Path -LiteralPath $tmp | Should -BeTrue
            $cfg = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
            $cfg.controller.hostname     | Should -Be 'ctrl.lan'
            $cfg.controller.https_port   | Should -Be 443
            $cfg.tls.self_signed.cn      | Should -Be 'ctrl.lan'
            $cfg.share.name              | Should -Be 'ClusterShare'
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'Copy-RepoTree returns $null when ScriptRoot is not a repo' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("notrepo-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -Path $tmp -ItemType Directory -Force | Out-Null
        try {
            $r = Copy-RepoTree -ScriptRoot $tmp -Destination (Join-Path $tmp 'staging')
            $r | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Copy-RepoTree successfully copies a real repo and drops the staging marker' {
        $dest = Join-Path ([System.IO.Path]::GetTempPath()) ("repo-copy-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            $r = Copy-RepoTree -ScriptRoot $script:repoRoot -Destination $dest
            $r | Should -Be $dest
            Test-Path -LiteralPath (Join-Path $dest 'src\Invoke-ClusterControllerSetup.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $dest 'src\lib\Logging.psm1')                  | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $dest '.clustercontroller-staging')             | Should -BeTrue
        } finally { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'install.ps1 structural checks' {
    It 'parses cleanly under PowerShell' {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:installPs1, [ref]$null, [ref]$errs)
        $errs.Count | Should -Be 0
    }
    It 'has a comment-based help block at the top' {
        $head = Get-Content -LiteralPath $script:installPs1 -TotalCount 5
        ($head -join "`n") | Should -Match '\.SYNOPSIS'
    }
    It 'has a main-block auto-run gate keyed on CLUSTERCTRL_NOAUTORUN' {
        (Get-Content -LiteralPath $script:installPs1 -Raw) | Should -Match 'CLUSTERCTRL_NOAUTORUN'
    }
}
