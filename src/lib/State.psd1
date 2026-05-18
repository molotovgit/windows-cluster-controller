@{
    RootModule        = 'State.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7c3d8a52-1e9f-4d3b-a8e6-2c5f7b9d4e1a'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Resume markers, run status, and reboot-resume scheduled-task helpers for the windows-cluster-controller orchestrator.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Save-StageMarker', 'Get-StageMarker', 'Clear-StageMarker',
        'Set-ClusterRunStatus', 'Get-ClusterRunStatus',
        'Set-ClusterRunVersion', 'Reset-ClusterRunState',
        'Complete-ClusterRun',
        'Get-ResumeTaskInfo', 'Test-ResumeTask',
        'Register-ResumeTask', 'Unregister-ResumeTask',
        'New-ResumeTaskSpec'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','state','resume')
        }
    }
}
