@{
    RootModule        = 'Net.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '6b4d1f72-9e3a-4c8d-b1f6-3e2a7c5d8f4b'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Network helpers (port probes, free-port discovery, DNS, local IPv4, default gateway) with mockable invoker seam.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Test-NetPortInUse',
        'Test-NetTcpOpen',
        'Find-NetFreePort',
        'Test-NetHttpReachable',
        'Resolve-NetHostName',
        'Get-NetLocalIPv4',
        'Get-NetDefaultGateway'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','network')
        }
    }
}
