#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Config.psm1'
    Get-Module Config | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
}

AfterAll {
    Get-Module Config | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ControllerConfigDefault' {
    It 'returns a fully-populated default tree' {
        $d = Get-ControllerConfigDefault
        $d.controller.hostname | Should -Be 'controller.lan'
        $d.controller.https_port | Should -Be 443
        $d.db.mode | Should -Be 'nedb'
        $d.tls.mode | Should -Be 'self-signed'
        $d.share.name | Should -Be 'ClusterShare'
        $d.admin.username | Should -Be 'clusteradmin'
        $d.firewall.profiles | Should -Contain 'Private'
    }
}

Describe 'Read-ControllerConfig' {
    It 'returns defaults when no path is given' {
        $r = Read-ControllerConfig
        $r.Ok | Should -BeTrue
        $r.Source | Should -Be 'defaults'
        $r.Config.controller.hostname | Should -Be 'controller.lan'
    }

    It 'returns defaults when path does not exist' {
        $r = Read-ControllerConfig -Path 'C:\nope.json'
        $r.Ok | Should -BeTrue
        $r.Source | Should -Be 'defaults'
    }

    It 'merges a partial user config onto defaults' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctrl-cfg-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
        try {
            '{ "controller": { "hostname": "ctrl-2.lan" }, "db": { "mode": "mongodb" } }' | Set-Content -LiteralPath $tmp -Encoding utf8
            $r = Read-ControllerConfig -Path $tmp
            $r.Ok | Should -BeTrue
            $r.Config.controller.hostname | Should -Be 'ctrl-2.lan'
            $r.Config.db.mode | Should -Be 'mongodb'
            # field not overridden stays at default
            $r.Config.tls.mode | Should -Be 'self-signed'
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'reports parse failure as Ok=$false but still returns defaults' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctrl-cfg-bad-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
        try {
            'not-json' | Set-Content -LiteralPath $tmp -Encoding utf8
            $r = Read-ControllerConfig -Path $tmp
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match 'cannot parse'
            $r.Config | Should -Not -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-ControllerConfigValid' {
    It 'accepts the defaults' {
        $v = Test-ControllerConfigValid -Config (Get-ControllerConfigDefault)
        $v.Ok | Should -BeTrue
        $v.Errors.Count | Should -Be 0
    }

    It 'rejects an out-of-range port' {
        $cfg = Get-ControllerConfigDefault
        $cfg.controller.https_port = 99999
        (Test-ControllerConfigValid -Config $cfg).Ok | Should -BeFalse
    }

    It 'rejects tls.mode=import without pfx_path' {
        $cfg = Get-ControllerConfigDefault
        $cfg.tls.mode = 'import'
        $cfg.tls.import.pfx_path = $null
        $v = Test-ControllerConfigValid -Config $cfg
        $v.Ok | Should -BeFalse
        ($v.Errors -join ' ') | Should -Match 'pfx_path'
    }
}

Describe 'Write-ControllerConfig' {
    It 'writes JSON and back-up on overwrite' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ctrl-out-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
        try {
            $d = Get-ControllerConfigDefault
            Write-ControllerConfig -Path $tmp -Config $d | Out-Null
            Test-Path -LiteralPath $tmp | Should -BeTrue
            # Second write triggers backup.
            Write-ControllerConfig -Path $tmp -Config $d | Out-Null
            @(Get-ChildItem -Path (Split-Path -Parent $tmp) -Filter ((Split-Path -Leaf $tmp) + '.bak.*')).Count | Should -BeGreaterOrEqual 1
        } finally {
            Get-ChildItem -Path (Split-Path -Parent $tmp) -Filter ((Split-Path -Leaf $tmp) + '*') | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Expand-ConfigPath' {
    It 'expands %ProgramData% in a string field' {
        $expanded = Expand-ConfigPath -Value '%ProgramData%\ClusterController\share'
        $expanded | Should -Match 'ProgramData'
        $expanded | Should -Not -Match '%'
    }

    It 'is a no-op for empty input' {
        Expand-ConfigPath -Value '' | Should -Be ''
    }
}
