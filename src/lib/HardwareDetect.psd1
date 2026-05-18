@{
    RootModule        = 'HardwareDetect.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '2a8c4f9d-5b1e-4c3a-9f7d-1e6b2a5c9d4f'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Controller hardware and OS-edition detection with multi-strategy fallbacks.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-WindowsSku',
        'Get-PhysicalDriveBest',
        'Get-ActiveWifiAdapter',
        'Get-VirtualizationSupport',
        'ConvertTo-CanonicalSku'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','hardware','detection')
        }
    }
}
