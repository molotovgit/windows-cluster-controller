<#
.SYNOPSIS
    TLS certificate helpers: generate self-signed cert with a SAN list,
    import an operator-supplied PFX, look up certs in the LocalMachine store
    by thumbprint or CN.

.DESCRIPTION
    The controller's HTTPS listener (MeshCentral on 443) needs a server cert.
    Default mode is "self-signed": this module generates one with a SAN list
    that includes the hostname, optional LAN IP, and any extras from config.

    Alternative modes:
      * import  -- operator supplies a real CA-signed PFX
      * letsencrypt -- ACME (deferred to Stage 14 stub)

    Both modes funnel into the same downstream Stage 11 / 16 logic via the
    cert thumbprint.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultTlsInvoker {
    @{
        NewSelfSignedCert = {
            param($Spec)
            New-SelfSignedCertificate `
                -DnsName       $Spec.DnsNames `
                -CertStoreLocation 'Cert:\LocalMachine\My' `
                -KeyExportPolicy ExportableEncrypted `
                -KeyAlgorithm    'RSA' `
                -KeyLength       2048 `
                -HashAlgorithm   'SHA256' `
                -NotAfter        (Get-Date).AddDays($Spec.ValidDays) `
                -Subject         ("CN=" + $Spec.Cn)
        }
        ImportPfx = {
            param($PfxPath, [System.Security.SecureString]$Password, [string]$Store = 'Cert:\LocalMachine\My')
            Import-PfxCertificate -FilePath $PfxPath -Password $Password -CertStoreLocation $Store
        }
        GetByThumbprint = {
            param($Thumbprint, [string]$Store = 'Cert:\LocalMachine\My')
            $p = Join-Path $Store $Thumbprint
            if (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p } else { $null }
        }
        GetByCn = {
            param($Cn, [string]$Store = 'Cert:\LocalMachine\My')
            Get-ChildItem -LiteralPath $Store -ErrorAction SilentlyContinue |
                Where-Object { "$($_.Subject)" -match ("CN=" + [regex]::Escape($Cn) + '\b') } |
                Select-Object -First 1
        }
        ExportToRoot = {
            param($Thumbprint, [string]$FromStore = 'Cert:\LocalMachine\My')
            $src = Get-Item -LiteralPath (Join-Path $FromStore $Thumbprint) -ErrorAction Stop
            $bytes = $src.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "cluster-cert-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.cer')
            [System.IO.File]::WriteAllBytes($tmp, $bytes)
            try {
                Import-Certificate -FilePath $tmp -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$script:TlsInvokers = Get-DefaultTlsInvoker

function Confirm-TlsTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-TlsInvoker / Reset-TlsInvoker."
    }
}

function Set-TlsInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('NewSelfSignedCert','ImportPfx','GetByThumbprint','GetByCn','ExportToRoot')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-TlsTestSeamAllowed
    $script:TlsInvokers[$Name] = $ScriptBlock
}

function Reset-TlsInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TlsTestSeamAllowed
    $script:TlsInvokers = Get-DefaultTlsInvoker
}

function New-ControllerSelfSignedCert {
    <#
    .SYNOPSIS
        Generate a self-signed server cert for the controller. Idempotent:
        if a cert with the desired CN already exists in LocalMachine\My,
        re-use it instead of generating a fresh one (so the thumbprint
        stays stable across re-runs).

    .PARAMETER Cn             Common Name (controller hostname, e.g. controller.lan).
    .PARAMETER AdditionalSans Extra SAN entries (hostnames or IPs).
    .PARAMETER ValidDays      Cert lifetime (default 825 -- max for many browsers).
    .PARAMETER InstallToRoot  Also import into LocalMachine\Root so the same
                              machine trusts it (operators avoid the cert
                              warning when browsing the UI locally).

    Returns @{Ok; Thumbprint; Subject; NotAfter; Reused; Detail}.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent cert generation; ShouldProcess would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cn,
        [string[]]$AdditionalSans = @(),
        [int]$ValidDays = 825,
        [switch]$InstallToRoot
    )

    $existing = & $script:TlsInvokers.GetByCn $Cn 'Cert:\LocalMachine\My'
    if ($existing) {
        if ($InstallToRoot) {
            try { & $script:TlsInvokers.ExportToRoot $existing.Thumbprint 'Cert:\LocalMachine\My' }
            catch { $null = $_ }
        }
        return [pscustomobject]@{
            Ok         = $true
            Thumbprint = "$($existing.Thumbprint)"
            Subject    = "$($existing.Subject)"
            NotAfter   = $existing.NotAfter
            Reused     = $true
            Detail     = "reused existing cert (CN=$Cn)"
        }
    }

    $dns = @($Cn) + @($AdditionalSans | Where-Object { $_ -and $_ -ne $Cn })
    $spec = [pscustomobject]@{ Cn = $Cn; DnsNames = $dns; ValidDays = $ValidDays }
    try {
        $cert = & $script:TlsInvokers.NewSelfSignedCert $spec
    } catch {
        return [pscustomobject]@{ Ok = $false; Thumbprint = $null; Subject = $null; NotAfter = $null; Reused = $false; Detail = "New-SelfSignedCertificate failed: $($_.Exception.Message)" }
    }

    if ($InstallToRoot -and $cert) {
        try { & $script:TlsInvokers.ExportToRoot $cert.Thumbprint 'Cert:\LocalMachine\My' }
        catch { $null = $_ }
    }
    [pscustomobject]@{
        Ok         = $true
        Thumbprint = "$($cert.Thumbprint)"
        Subject    = "$($cert.Subject)"
        NotAfter   = $cert.NotAfter
        Reused     = $false
        Detail     = "generated new cert ($($dns.Count) SAN entries)"
    }
}

function Import-ControllerPfxCert {
    <#
    .SYNOPSIS
        Import an operator-supplied PFX into LocalMachine\My. Idempotent:
        if a cert with the same Subject is already installed, skip the import.

    .PARAMETER PfxPath  Filesystem path to the PFX.
    .PARAMETER Password SecureString password for the PFX.
    .PARAMETER ExpectedCn Optional: validate the imported cert's Subject CN.

    Returns @{Ok; Thumbprint; Subject; NotAfter; Reused; Detail}.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent cert import.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PfxPath,
        [Parameter(Mandatory)][System.Security.SecureString]$Password,
        [string]$ExpectedCn
    )
    if (-not (Test-Path -LiteralPath $PfxPath)) {
        return [pscustomobject]@{ Ok = $false; Thumbprint = $null; Subject = $null; NotAfter = $null; Reused = $false; Detail = "PFX not found at $PfxPath" }
    }

    if ($ExpectedCn) {
        $existing = & $script:TlsInvokers.GetByCn $ExpectedCn 'Cert:\LocalMachine\My'
        if ($existing) {
            return [pscustomobject]@{
                Ok         = $true
                Thumbprint = "$($existing.Thumbprint)"
                Subject    = "$($existing.Subject)"
                NotAfter   = $existing.NotAfter
                Reused     = $true
                Detail     = "cert with CN=$ExpectedCn already imported"
            }
        }
    }

    try {
        $cert = & $script:TlsInvokers.ImportPfx $PfxPath $Password 'Cert:\LocalMachine\My'
    } catch {
        return [pscustomobject]@{ Ok = $false; Thumbprint = $null; Subject = $null; NotAfter = $null; Reused = $false; Detail = "Import-PfxCertificate failed: $($_.Exception.Message)" }
    }
    if (-not $cert) {
        return [pscustomobject]@{ Ok = $false; Thumbprint = $null; Subject = $null; NotAfter = $null; Reused = $false; Detail = 'PFX imported but no cert returned' }
    }
    [pscustomobject]@{
        Ok         = $true
        Thumbprint = "$($cert.Thumbprint)"
        Subject    = "$($cert.Subject)"
        NotAfter   = $cert.NotAfter
        Reused     = $false
        Detail     = 'imported from PFX'
    }
}

function Get-ControllerCert {
    <#
    .SYNOPSIS
        Look up a cert by thumbprint (preferred) or CN. Returns
        @{Found; Thumbprint; Subject; NotAfter} or Found=$false.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Thumbprint')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Thumbprint')]
        [string]$Thumbprint,
        [Parameter(Mandatory, ParameterSetName = 'Cn')]
        [string]$Cn,
        [string]$Store = 'Cert:\LocalMachine\My'
    )
    $cert = if ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
        & $script:TlsInvokers.GetByThumbprint $Thumbprint $Store
    } else {
        & $script:TlsInvokers.GetByCn $Cn $Store
    }
    if (-not $cert) { return [pscustomobject]@{ Found = $false; Thumbprint = $null; Subject = $null; NotAfter = $null } }
    [pscustomobject]@{
        Found      = $true
        Thumbprint = "$($cert.Thumbprint)"
        Subject    = "$($cert.Subject)"
        NotAfter   = $cert.NotAfter
    }
}

Export-ModuleMember -Function `
    New-ControllerSelfSignedCert, Import-ControllerPfxCert, Get-ControllerCert
