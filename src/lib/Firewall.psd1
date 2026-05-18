@{
    RootModule        = 'Firewall.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '3c7d5a1f-8e2b-4c9d-a3f6-1b5e7d2a8c4f'
    Author            = 'windows-cluster-controller'
    CompanyName       = 'windows-cluster-controller'
    Copyright         = '(c) windows-cluster-controller. Released under repo license.'
    Description       = 'Idempotent Windows Firewall rule helpers (create-or-replace, remove-if-present) with mockable invoker seam.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Test-FirewallRule',
        'New-IdempotentFirewallRule',
        'Remove-IdempotentFirewallRule'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','controller','firewall')
        }
    }
}
