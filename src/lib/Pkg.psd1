@{
    RootModule        = 'Pkg.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '4f9c2b1d-3e7a-4b6c-8d2f-9e5a1c3b7d4e'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Package install primitives (SHA256-verified download, MSI/winget install, installed-product probe) with mockable invoker seam.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-PkgDownload',
        'Install-PkgMsi',
        'Install-PkgViaWinget',
        'Test-PkgInstalled'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','package','install')
        }
    }
}
