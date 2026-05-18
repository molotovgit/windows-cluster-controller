#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Announce.psm1'
    Get-Module Announce | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
}

AfterAll {
    Get-Module Announce | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-AnnouncerPayload' {
    It 'emits the expected JSON-shape fields' {
        $p = New-AnnouncerPayload -Hostname 'controller.lan' -LanIp '192.168.1.7' -HttpsPort 443 -AgentPort 4433 -Version '0.1.0'
        $p.type       | Should -Be 'cluster-controller'
        $p.hostname   | Should -Be 'controller.lan'
        $p.lan_ip     | Should -Be '192.168.1.7'
        $p.https_port | Should -Be 443
        $p.agent_port | Should -Be 4433
        $p.version    | Should -Be '0.1.0'
        $p.emitted_at | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
    }

    It 'leaves lan_ip null if not provided' {
        $p = New-AnnouncerPayload -Hostname 'x.lan'
        $p.lan_ip | Should -BeNullOrEmpty
    }
}

Describe 'Get-AnnouncerScriptContent' {
    It 'emits PowerShell that references the payload file' {
        $payload = 'C:\ProgramData\ClusterController\share\.well-known\cluster-controller.json'
        $text = Get-AnnouncerScriptContent -Port 8765 -PayloadFile $payload
        $text | Should -Match 'HttpListener'
        $text | Should -Match 'http://\+:8765/.well-known/cluster-controller/'
        $text | Should -Match ([regex]::Escape($payload))
    }

    It 'escapes single quotes in the PayloadFile path' {
        $payload = "C:\share\it's-here\cc.json"
        $text = Get-AnnouncerScriptContent -PayloadFile $payload
        $text | Should -Match "it''s-here"
    }
}
