@{
    RootModule        = 'Service.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8a1f3e6c-2d5b-4f7a-9c1d-6e3b8a2f5d1c'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Idempotent Windows-service helpers (state transitions, startup-type, ready-wait, NSSM-based registration of non-native services).'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-ServiceInfo',
        'Set-ServiceStartType',
        'Start-ServiceIdempotent',
        'Stop-ServiceIdempotent',
        'Wait-ServiceReady',
        'Install-NssmService'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','service','nssm')
        }
    }
}
