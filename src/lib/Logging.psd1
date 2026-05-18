@{
    RootModule        = 'Logging.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5e2f4d8c-7b3a-4c1e-9d6f-8a4b2c1e3d7f'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Structured, level-filtered, stage-aware logging for the windows-cluster-controller setup script.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Initialize-ClusterLog',
        'Get-ClusterLogPath',
        'Write-ClusterLog',
        'Start-StageLog',
        'Stop-StageLog',
        'Get-OpenStageName',
        'Set-ClusterLogRedaction',
        'Get-ClusterLogRedaction',
        'Reset-ClusterLogState'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','logging')
        }
    }
}
