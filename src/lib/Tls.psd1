@{
    RootModule        = 'Tls.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5b9e3c1f-7d8a-4f2c-9e6b-1a3c5d7f8e2b'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'TLS certificate helpers: self-signed cert generation, PFX import, lookup by thumbprint or CN. Mockable invoker seam.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'New-ControllerSelfSignedCert',
        'Import-ControllerPfxCert',
        'Get-ControllerCert'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','tls','certificate')
        }
    }
}
