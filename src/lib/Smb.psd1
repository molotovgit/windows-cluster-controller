@{
    RootModule        = 'Smb.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd2e8f4a1-6b3c-4e9d-87a2-9f5c1d3a8b6e'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Idempotent SMB-share helpers (create-or-update, remove-if-present, path-conflict guard).'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'New-IdempotentSmbShare',
        'Remove-IdempotentSmbShare'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','smb','share')
        }
    }
}
