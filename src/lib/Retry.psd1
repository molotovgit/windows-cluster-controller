@{
    RootModule        = 'Retry.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '9f8b6e74-3d2c-4a1f-8e2d-5b7c1a3f9e6d'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Retry-with-backoff and fallback-chain primitives for the windows-cluster-controller setup script.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Invoke-WithRetry', 'Invoke-WithFallback')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','retry','fallback')
        }
    }
}
