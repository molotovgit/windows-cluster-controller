<#
.SYNOPSIS
    Idempotent SMB-share helpers for the controller setup. Used by
    Stage 22 to expose %ProgramData%\ClusterController\share to host PCs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultSmbInvoker {
    @{
        GetShare = {
            param([string]$Name)
            try {
                $s = Get-SmbShare -Name $Name -ErrorAction Stop
                [pscustomobject]@{
                    Found       = $true
                    Path        = "$($s.Path)"
                    Description = "$($s.Description)"
                }
            } catch {
                $null = $_
                [pscustomobject]@{ Found = $false; Path = $null; Description = $null }
            }
        }
        NewShare = {
            param($Spec)
            $p = @{
                Name        = $Spec.Name
                Path        = $Spec.Path
                Description = $Spec.Description
            }
            if ($Spec.PSObject.Properties['ReadAccess']  -and $Spec.ReadAccess)  { $p['ReadAccess']  = $Spec.ReadAccess }
            if ($Spec.PSObject.Properties['FullAccess']  -and $Spec.FullAccess)  { $p['FullAccess']  = $Spec.FullAccess }
            if ($Spec.PSObject.Properties['ChangeAccess'] -and $Spec.ChangeAccess){ $p['ChangeAccess']= $Spec.ChangeAccess }
            New-SmbShare @p | Out-Null
        }
        RemoveShare = {
            param([string]$Name)
            Remove-SmbShare -Name $Name -Force -ErrorAction Stop
        }
        SetShareDescription = {
            param([string]$Name, [string]$Description)
            Set-SmbShare -Name $Name -Description $Description -Force -ErrorAction Stop
        }
    }
}

$script:SmbInvokers = Get-DefaultSmbInvoker

function Confirm-SmbTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-SmbInvoker / Reset-SmbInvoker."
    }
}

function Set-SmbInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GetShare','NewShare','RemoveShare','SetShareDescription')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-SmbTestSeamAllowed
    $script:SmbInvokers[$Name] = $ScriptBlock
}

function Reset-SmbInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-SmbTestSeamAllowed
    $script:SmbInvokers = Get-DefaultSmbInvoker
}

function New-IdempotentSmbShare {
    <#
    .SYNOPSIS
        Create an SMB share or update its description; refuse to silently
        change the backing Path (operator confusion risk).

    .PARAMETER Name        Share name (e.g. ClusterShare).
    .PARAMETER Path        Filesystem path on the controller.
    .PARAMETER Description Free-text shown in net view.
    .PARAMETER ReadAccess  Identity strings granted read access.
    .PARAMETER FullAccess  Identity strings granted full access.

    Returns @{Ok; Action; Detail}. Action in 'created' | 'unchanged' |
    'description-updated' | 'path-conflict'.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent share creation; ShouldProcess would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = '',
        [string[]]$ReadAccess = @('Authenticated Users'),
        [string[]]$FullAccess = @('Administrators')
    )

    # Resolve well-known account names to LOCALIZED forms via SID round-trip.
    # On non-English Windows ('Authenticated Users' / 'Administrators' literal
    # strings don't resolve -- the OS expects the localized name like Russian
    # 'NT AUTHORITY\Прошедшие проверку'). SIDs are language-independent; we
    # ask Windows what the local-language name for the well-known SID is,
    # then pass THAT to New-SmbShare.
    function _ResolveSid([string]$SidString, [string]$EnglishFallback) {
        try {
            return (New-Object System.Security.Principal.SecurityIdentifier($SidString)).Translate([System.Security.Principal.NTAccount]).Value
        } catch {
            $null = $_
            return $EnglishFallback
        }
    }
    $resolvedRead = $ReadAccess | ForEach-Object {
        switch ($_) {
            'Authenticated Users' { _ResolveSid 'S-1-5-11'     'Authenticated Users' }
            'Everyone'            { _ResolveSid 'S-1-1-0'      'Everyone' }
            'Users'               { _ResolveSid 'S-1-5-32-545' 'Users' }
            default               { $_ }
        }
    }
    $resolvedFull = $FullAccess | ForEach-Object {
        switch ($_) {
            'Administrators'      { _ResolveSid 'S-1-5-32-544' 'Administrators' }
            'SYSTEM'              { _ResolveSid 'S-1-5-18'     'SYSTEM' }
            default               { $_ }
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Ok = $false; Action = 'path-missing'; Detail = "share path '$Path' does not exist" }
    }

    $existing = & $script:SmbInvokers.GetShare $Name
    if ($existing.Found) {
        $existingPath = (Resolve-Path -LiteralPath $existing.Path -ErrorAction SilentlyContinue).Path
        $wantPath     = (Resolve-Path -LiteralPath $Path           -ErrorAction SilentlyContinue).Path
        if ($existingPath -and $wantPath -and ($existingPath -ne $wantPath)) {
            return [pscustomobject]@{ Ok = $false; Action = 'path-conflict'; Detail = "share '$Name' already exists pointing at '$existingPath'; refuse to silently re-point to '$wantPath'" }
        }
        if ($existing.Description -ne $Description) {
            try {
                & $script:SmbInvokers.SetShareDescription $Name $Description
                return [pscustomobject]@{ Ok = $true; Action = 'description-updated'; Detail = "share '$Name' description updated" }
            } catch {
                return [pscustomobject]@{ Ok = $false; Action = 'update-failed'; Detail = "$($_.Exception.Message)" }
            }
        }
        return [pscustomobject]@{ Ok = $true; Action = 'unchanged'; Detail = "share '$Name' already exists with the same path" }
    }

    $spec = [pscustomobject]@{
        Name = $Name; Path = $Path; Description = $Description
        ReadAccess = $resolvedRead; FullAccess = $resolvedFull
    }
    try {
        & $script:SmbInvokers.NewShare $spec
    } catch {
        return [pscustomobject]@{ Ok = $false; Action = 'create-failed'; Detail = "New-SmbShare failed: $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Ok = $true; Action = 'created'; Detail = "share '$Name' -> '$Path' (read=$($ReadAccess -join ','); full=$($FullAccess -join ','))" }
}

function Remove-IdempotentSmbShare {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent share removal; ShouldProcess would break unattended teardown.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $existing = & $script:SmbInvokers.GetShare $Name
    if (-not $existing.Found) {
        return [pscustomobject]@{ Ok = $true; Action = 'absent'; Detail = "share '$Name' was not present" }
    }
    try {
        & $script:SmbInvokers.RemoveShare $Name
        [pscustomobject]@{ Ok = $true; Action = 'removed'; Detail = "share '$Name' removed" }
    } catch {
        [pscustomobject]@{ Ok = $false; Action = 'remove-failed'; Detail = "$($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function `
    New-IdempotentSmbShare, Remove-IdempotentSmbShare
