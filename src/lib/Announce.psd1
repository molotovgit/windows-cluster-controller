@{
    RootModule        = 'Announce.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '4d7f1e8a-2b3c-49d6-87fe-1a5b6c3d8e2f'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Announcer-payload + announcer-script content helpers (HttpListener self-announcer for host discovery).'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'New-AnnouncerPayload',
        'Get-AnnouncerScriptContent'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','announce','discovery')
        }
    }
}
