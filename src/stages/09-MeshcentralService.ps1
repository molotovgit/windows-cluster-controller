<#
.SYNOPSIS
    Stage 9 -- Install MeshCentral as a Windows service, start it, and
    wait for its HTTPS endpoint to respond. Combines the planned
    MeshcentralService + MeshcentralStart stages.

.DESCRIPTION
    Two paths to install the service:
      1. Primary: `node meshcentral --install` (MeshCentral's built-in
         service installer; creates the 'MeshCentral' Windows service).
      2. Fallback: NSSM-wrapped `node meshcentral.js` via lib/Service
         Install-NssmService.

    Once installed:
      - Set startup type Automatic.
      - Start the service (idempotent; bounded wait for Running state).
      - Probe https://localhost:<port>/ via lib/Net Test-NetHttpReachable
        (any 2xx, body contains "MeshCentral" or similar branding). Soft
        Warn instead of Fail if probe fails -- service may still be
        initialising; an operator can re-run.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Service','Net','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultMeshcentralServiceInvoker {
    @{
        # Run `node <meshcentralEntry> --install`. Returns @{ExitCode}.
        RunMeshcentralInstall = {
            param([string]$NodeExe, [string]$MeshcentralEntry, [string]$WorkingDir)
            $argv = @($MeshcentralEntry, '--install')
            $p = Start-Process -FilePath $NodeExe -ArgumentList $argv -WorkingDirectory $WorkingDir -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        TestNodeOnPath = {
            $cmd = Get-Command -Name 'node' -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
            return $null
        }
    }
}

$script:MeshcentralServiceInvokers = Get-DefaultMeshcentralServiceInvoker

function Confirm-MeshcentralServiceTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-MeshcentralServiceInvoker."
    }
}

function Set-MeshcentralServiceInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RunMeshcentralInstall','TestNodeOnPath')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-MeshcentralServiceTestSeamAllowed
    $script:MeshcentralServiceInvokers[$Name] = $ScriptBlock
}

function Reset-MeshcentralServiceInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-MeshcentralServiceTestSeamAllowed
    $script:MeshcentralServiceInvokers = Get-DefaultMeshcentralServiceInvoker
}

# ---------- public ----------

function Invoke-MeshcentralServiceStage {
    [CmdletBinding()]
    param(
        $Config,
        [int]$ReadyWaitSeconds = 60,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $hostname  = "$($cfg.controller.hostname)"
    $httpsPort = [int]$cfg.controller.https_port
    $dataDir   = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $mcRoot    = Split-Path -Parent $dataDir
    $entry     = Join-Path $mcRoot 'node_modules\meshcentral\meshcentral.js'
    $svcName   = 'MeshCentral'

    _step 'Resolve service plan' 'Pass' "root=$mcRoot entry=$entry port=$httpsPort"

    if ($DryRun) {
        _step 'Install + start MeshCentral service' 'Skipped' '-DryRun: would have installed + started the service'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: MeshCentral service' }
    }

    # 1. Locate node.
    $nodeExe = & $script:MeshcentralServiceInvokers.TestNodeOnPath
    if (-not $nodeExe) {
        _step 'Locate node' 'Fail' 'node.exe not on PATH'
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = 'node missing'; Remediation = 'Re-run Stage 4 (Node) to install Node.js LTS and re-open the shell so PATH is refreshed.' }
    }
    _step 'Locate node' 'Pass' "node=$nodeExe"

    # 2. Is the service already installed?
    $svc = Get-ServiceInfo -Name $svcName
    $installPath = $null
    if (-not $svc.Found) {
        # Primary: node meshcentral --install
        if (Test-Path -LiteralPath $entry) {
            $r = & $script:MeshcentralServiceInvokers.RunMeshcentralInstall $nodeExe $entry $mcRoot
            if ($r.ExitCode -eq 0) {
                _step 'Install MeshCentral service (built-in)' 'Pass' "node meshcentral --install exited 0"
                $installPath = 'meshcentral --install'
            } else {
                _step 'Install MeshCentral service (built-in)' 'Warn' "node meshcentral --install exited $($r.ExitCode); falling back to NSSM"
            }
        } else {
            _step 'Install MeshCentral service (built-in)' 'Warn' "meshcentral.js not found at $entry; falling back to NSSM"
        }

        if (-not $installPath) {
            $nssmArgs = "`"$entry`""
            $nssm = Install-NssmService -Name $svcName -Executable $nodeExe -Arguments $nssmArgs `
                       -DisplayName 'MeshCentral (windows-cluster-controller)' `
                       -Description 'MeshCentral server for the Windows cluster controller' `
                       -StartType 'Automatic' -LogonAs 'LocalSystem'
            if (-not $nssm.Ok) {
                _step 'Install MeshCentral service (NSSM)' 'Fail' $nssm.Detail
                return [pscustomobject]@{
                    Overall     = 'Fail'
                    Steps       = $steps.ToArray()
                    Detail      = "MeshCentral service install failed via both built-in and NSSM"
                    Remediation = "Manually run 'node $entry --install' from $mcRoot as Administrator and inspect the error."
                }
            }
            _step 'Install MeshCentral service (NSSM)' 'Pass' "NSSM-registered service '$svcName'"
            $installPath = 'NSSM'
        }
    } else {
        _step 'Install MeshCentral service' 'Pass' "service '$svcName' already installed; state=$($svc.Status)"
    }

    # 3. Set startup type Automatic.
    $st = Set-ServiceStartType -Name $svcName -StartType 'Automatic'
    if ($st.Ok) { _step 'StartType=Automatic' 'Pass' $st.Detail } else { _step 'StartType=Automatic' 'Warn' $st.Detail }

    # 4. Start.
    $start = Start-ServiceIdempotent -Name $svcName -WaitSeconds $ReadyWaitSeconds
    if (-not $start.Ok -or $start.State -ne 'Running') {
        _step 'Start MeshCentral service' 'Fail' $start.Detail
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = "MeshCentral service did not start: $($start.Detail)"
            Remediation = "Inspect $mcRoot\meshcentral-data\mesherrors.log and Event Viewer (Application log); resolve and re-run."
        }
    }
    _step 'Start MeshCentral service' 'Pass' $start.Detail

    # 5. HTTPS probe.
    $probeUrl = "https://localhost:$httpsPort/"
    $http = Test-NetHttpReachable -Url $probeUrl -TimeoutMs ([math]::Min(15000, [int]($ReadyWaitSeconds * 1000))) -ExpectStatus 0
    if ($http.Ok) {
        _step 'HTTPS probe' 'Pass' "$probeUrl responded $($http.Status)"
        [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "MeshCentral service Running and serving on $probeUrl" }
    } else {
        _step 'HTTPS probe' 'Warn' "$probeUrl did not respond: $($http.Reason). Service is Running -- may still be initialising."
        [pscustomobject]@{
            Overall    = 'Warn'
            Steps      = $steps.ToArray()
            Detail     = 'MeshCentral service Running but HTTPS endpoint not yet responding'
            Remediation = "Wait ~30s and re-probe $probeUrl. If still failing, check $mcRoot\meshcentral-data\mesherrors.log."
        }
    }
}
