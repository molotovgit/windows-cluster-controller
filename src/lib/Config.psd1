@{
    RootModule        = 'Config.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e7a2c5d8-3f6b-4d1c-9a8e-5b2f1c7d4e9a'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'cluster-controller.json defaults, merge, validation, backup-on-write, env-var expansion in path fields.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-ControllerConfigDefault',
        'Expand-ConfigPath',
        'Read-ControllerConfig',
        'Merge-ControllerConfigWithDefault',
        'Test-ControllerConfigValid',
        'Write-ControllerConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','config')
        }
    }
}
