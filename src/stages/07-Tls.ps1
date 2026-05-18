<#
.SYNOPSIS
    Stage 7 -- TLS. Dispatch on config.tls.mode:
      self-signed (default) -> generate via lib/Tls (idempotent CN reuse)
      import                -> import operator-supplied PFX
      letsencrypt           -> stub: requires controller to be internet-
                              reachable on TCP 80, deferred to a future PR

    Writes the resulting cert thumbprint + a stub fullchain.pem path into
    MeshCentral's config.json so Stage 8 (MeshCentralService) can launch
    against a working cert.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'GetPfxPassword reads the PFX password from an operator-set process env var (named in tls.import.pfx_password_envvar) and converts it to a SecureString. The plaintext lives in the env var, never in source.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Tls','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultTlsStageInvoker {
    @{
        # Read MeshCentral config.json, update settings.tlsoffload (or similar)
        # to record the thumbprint, write back.
        RecordThumbprintInMeshcentralConfig = {
            param([string]$ConfigPath, [string]$Thumbprint)
            if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            if (-not $obj.PSObject.Properties['settings']) {
                $obj | Add-Member -NotePropertyName 'settings' -NotePropertyValue ([pscustomobject]@{})
            }
            $obj.settings | Add-Member -NotePropertyName 'cert_thumbprint' -NotePropertyValue $Thumbprint -Force
            $bak = "$ConfigPath.bak." + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $ConfigPath -Destination $bak -Force
            [System.IO.File]::WriteAllText($ConfigPath, ($obj | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        }
        # Build a SecureString from the env-var named in tls.import.pfx_password_envvar.
        GetPfxPassword = {
            param([string]$EnvVar)
            if (-not $EnvVar) { return $null }
            $val = [Environment]::GetEnvironmentVariable($EnvVar, 'Process')
            if (-not $val) { return $null }
            ConvertTo-SecureString -String $val -AsPlainText -Force
        }
    }
}

$script:TlsStageInvokers = Get-DefaultTlsStageInvoker

function Confirm-TlsStageTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-TlsStageInvoker."
    }
}

function Set-TlsStageInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Reads operator-supplied PFX password from an env var as a SecureString; the plaintext lives in the env var, not the source.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RecordThumbprintInMeshcentralConfig','GetPfxPassword')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-TlsStageTestSeamAllowed
    $script:TlsStageInvokers[$Name] = $ScriptBlock
}

function Reset-TlsStageInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TlsStageTestSeamAllowed
    $script:TlsStageInvokers = Get-DefaultTlsStageInvoker
}

# ---------- public ----------

function Invoke-TlsStage {
    [CmdletBinding()]
    param(
        $Config,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $mode      = "$($cfg.tls.mode)"
    $hostname  = "$($cfg.controller.hostname)"
    $dataDir   = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $configJson = Join-Path $dataDir 'config.json'

    _step 'Resolve tls.mode' 'Pass' "mode=$mode hostname=$hostname"

    if ($DryRun) {
        _step 'TLS path' 'Skipped' "-DryRun: would have ensured cert via mode '$mode'"
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "DryRun: tls.mode=$mode" }
    }

    $thumbprint = $null
    switch ($mode) {
        'self-signed' {
            $extras = if ($cfg.tls.self_signed.PSObject.Properties['additional_sans']) { @($cfg.tls.self_signed.additional_sans) } else { @() }
            $days   = if ($cfg.tls.self_signed.PSObject.Properties['valid_for_days'])  { [int]$cfg.tls.self_signed.valid_for_days } else { 825 }
            $r = New-ControllerSelfSignedCert -Cn $hostname -AdditionalSans $extras -ValidDays $days -InstallToRoot
            if (-not $r.Ok) {
                _step 'Generate self-signed cert' 'Fail' $r.Detail
                return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = $r.Detail; Remediation = 'Verify New-SelfSignedCertificate works as Administrator.' }
            }
            $thumbprint = $r.Thumbprint
            _step 'Generate self-signed cert' 'Pass' "thumbprint=$thumbprint (reused=$($r.Reused))"
        }
        'import' {
            $pfxPath = "$($cfg.tls.import.pfx_path)"
            if (-not $pfxPath) {
                _step 'Import PFX' 'Fail' 'tls.mode=import but tls.import.pfx_path is empty'
                return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = 'no pfx_path'; Remediation = 'Set tls.import.pfx_path in cluster-controller.json to a .pfx file readable by Administrators.' }
            }
            $envVar = "$($cfg.tls.import.pfx_password_envvar)"
            $pwd    = & $script:TlsStageInvokers.GetPfxPassword $envVar
            if (-not $pwd) {
                _step 'Import PFX' 'Fail' "tls.import.pfx_password_envvar '$envVar' is empty in this process"
                return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = "PFX password env-var '$envVar' missing"; Remediation = "Set `$env:$envVar to the PFX password and re-run." }
            }
            $r = Import-ControllerPfxCert -PfxPath $pfxPath -Password $pwd -ExpectedCn $hostname
            if (-not $r.Ok) {
                _step 'Import PFX' 'Fail' $r.Detail
                return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = $r.Detail; Remediation = 'Verify the PFX path + password and that the file is readable.' }
            }
            $thumbprint = $r.Thumbprint
            _step 'Import PFX' 'Pass' "thumbprint=$thumbprint (reused=$($r.Reused))"
        }
        'letsencrypt' {
            # Stub. Implementing ACME is a non-trivial separate workstream.
            _step 'Let''s Encrypt' 'Warn' 'tls.mode=letsencrypt is a stub in this release; falling back to existing cert if one is present.'
            $existing = Get-ControllerCert -Cn $hostname
            if ($existing.Found) {
                $thumbprint = $existing.Thumbprint
                _step 'Reuse existing cert' 'Pass' "thumbprint=$thumbprint (subject=$($existing.Subject))"
            } else {
                _step 'Reuse existing cert' 'Fail' "tls.mode=letsencrypt selected and no existing cert with CN=$hostname found"
                return [pscustomobject]@{
                    Overall     = 'Fail'
                    Steps       = $steps.ToArray()
                    Detail      = 'letsencrypt stub: no fallback cert available'
                    Remediation = "Either switch tls.mode to 'self-signed' for LAN-only deployments, or install an ACME-issued cert manually and switch to tls.mode=import."
                }
            }
        }
        default {
            _step 'Resolve tls.mode' 'Fail' "unsupported tls.mode '$mode'"
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = "unsupported tls.mode '$mode'"; Remediation = "Use one of: self-signed | import | letsencrypt." }
        }
    }

    # Write thumbprint into MeshCentral config (best effort -- earlier stages
    # may not have produced config.json yet on a partial run; a warning is fine).
    if (Test-Path -LiteralPath $configJson) {
        try {
            & $script:TlsStageInvokers.RecordThumbprintInMeshcentralConfig $configJson $thumbprint
            _step 'Update MeshCentral config' 'Pass' "wrote cert_thumbprint into $configJson"
        } catch {
            _step 'Update MeshCentral config' 'Warn' "could not update $configJson : $($_.Exception.Message)"
        }
    } else {
        _step 'Update MeshCentral config' 'Warn' "$configJson not present -- Stage 6 should have created it; thumbprint=$thumbprint is in LocalMachine\My"
    }

    [pscustomobject]@{
        Overall    = 'Pass'
        Steps      = $steps.ToArray()
        Detail     = "TLS ready; thumbprint=$thumbprint mode=$mode"
        Thumbprint = $thumbprint
    }
}
