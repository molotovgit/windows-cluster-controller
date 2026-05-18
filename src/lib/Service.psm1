<#
.SYNOPSIS
    Windows-service helpers for the controller setup: idempotent state
    transitions, startup-type configuration, ready-wait, NSSM wrapping
    for services that aren't natively a Windows service (the Announcer
    is a Node.js / PowerShell script, for example).

.DESCRIPTION
    Every public function is idempotent and returns @{Ok; State; StartType;
    Detail} so callers can log without re-querying. The invoker seam covers
    Get-Service / Set-Service / Start/Stop and NSSM exec.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- invoker seam ----------

function ConvertTo-NssmArgList {
    <#
    .SYNOPSIS
        Quote argv elements that contain whitespace so Start-Process'
        -ArgumentList serialisation does not split them across argv slots.

    .DESCRIPTION
        Start-Process -ArgumentList joins its elements with spaces but does
        NOT auto-quote elements that themselves contain spaces. Passing
        @('install','Svc','C:\Program Files\PS\7\pwsh.exe') ends up on the
        child's command line as `install Svc C:\Program Files\PS\7\pwsh.exe`
        -- four argv slots, not three. Result: NSSM registers the service
        with Application='C:\Program' and AppParameters starts with
        'Files\PS\7\pwsh.exe ...', which fails at start-time with
        "system cannot find the file specified".

        Wrap each whitespace-bearing element in double quotes (idempotent --
        already-quoted elements are left as-is).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv)
    return @($Argv | ForEach-Object {
        if ($null -eq $_) { return '""' }
        if ($_ -match '\s' -and -not ($_ -match '^".*"$')) { return ('"' + $_ + '"') }
        return $_
    })
}

function Get-DefaultServiceInvoker {
    @{
        GetService = {
            param([string]$Name)
            try {
                $s = Get-Service -Name $Name -ErrorAction Stop
                [pscustomobject]@{
                    Found     = $true
                    Status    = "$($s.Status)"
                    StartType = "$($s.StartType)"
                }
            } catch {
                $null = $_
                [pscustomobject]@{ Found = $false; Status = 'NotInstalled'; StartType = $null }
            }
        }
        SetStartType = {
            param([string]$Name, [string]$StartType)
            Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
        }
        StartService = {
            param([string]$Name)
            Start-Service -Name $Name -ErrorAction Stop
        }
        StopService = {
            param([string]$Name)
            Stop-Service -Name $Name -Force -ErrorAction Stop
        }
        RunNssm = {
            param([string[]]$Argv)
            # Quote space-bearing args (paths under "Program Files", multi-word
            # display names, etc.). See ConvertTo-NssmArgList for the why.
            $quoted = ConvertTo-NssmArgList -Argv $Argv
            $p = Start-Process -FilePath 'nssm.exe' -ArgumentList $quoted -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput ([System.IO.Path]::GetTempFileName())
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
    }
}

$script:ServiceInvokers = Get-DefaultServiceInvoker

function Confirm-ServiceTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-ServiceInvoker / Reset-ServiceInvoker."
    }
}

function Set-ServiceInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GetService','SetStartType','StartService','StopService','RunNssm')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-ServiceTestSeamAllowed
    $script:ServiceInvokers[$Name] = $ScriptBlock
}

function Reset-ServiceInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-ServiceTestSeamAllowed
    $script:ServiceInvokers = Get-DefaultServiceInvoker
}

# ---------- public ----------

function Get-ServiceInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return & $script:ServiceInvokers.GetService $Name
}

function Set-ServiceStartType {
    <#
    .SYNOPSIS Idempotent: set StartType only if it differs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent: skips when StartType already matches.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Automatic','AutomaticDelayedStart','Manual','Disabled')]
        [string]$StartType
    )
    $info = & $script:ServiceInvokers.GetService $Name
    if (-not $info.Found) {
        return [pscustomobject]@{ Ok = $false; State = 'NotInstalled'; StartType = $null; Detail = "service '$Name' not installed" }
    }
    if ($info.StartType -eq $StartType) {
        return [pscustomobject]@{ Ok = $true; State = $info.Status; StartType = $info.StartType; Detail = 'already correct' }
    }
    try {
        & $script:ServiceInvokers.SetStartType $Name $StartType
        $after = & $script:ServiceInvokers.GetService $Name
        return [pscustomobject]@{ Ok = $true; State = $after.Status; StartType = $after.StartType; Detail = "changed $($info.StartType) -> $StartType" }
    } catch {
        return [pscustomobject]@{ Ok = $false; State = $info.Status; StartType = $info.StartType; Detail = "Set-Service failed: $($_.Exception.Message)" }
    }
}

function Start-ServiceIdempotent {
    <#
    .SYNOPSIS
        Start a service if it's not already Running. Optionally wait for the
        Running state with a timeout.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent start with bounded wait; ShouldProcess would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$WaitSeconds = 30
    )
    $info = & $script:ServiceInvokers.GetService $Name
    if (-not $info.Found) {
        return [pscustomobject]@{ Ok = $false; State = 'NotInstalled'; StartType = $null; Detail = "service '$Name' not installed" }
    }
    if ($info.Status -eq 'Running') {
        return [pscustomobject]@{ Ok = $true; State = 'Running'; StartType = $info.StartType; Detail = 'already running' }
    }
    try { & $script:ServiceInvokers.StartService $Name }
    catch {
        return [pscustomobject]@{ Ok = $false; State = $info.Status; StartType = $info.StartType; Detail = "Start-Service failed: $($_.Exception.Message)" }
    }
    Wait-ServiceReady -Name $Name -DesiredState 'Running' -TimeoutSeconds $WaitSeconds
}

function Stop-ServiceIdempotent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Idempotent stop with bounded wait.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$WaitSeconds = 30
    )
    $info = & $script:ServiceInvokers.GetService $Name
    if (-not $info.Found) {
        return [pscustomobject]@{ Ok = $true; State = 'NotInstalled'; StartType = $null; Detail = "service '$Name' not installed -- nothing to stop" }
    }
    if ($info.Status -eq 'Stopped') {
        return [pscustomobject]@{ Ok = $true; State = 'Stopped'; StartType = $info.StartType; Detail = 'already stopped' }
    }
    try { & $script:ServiceInvokers.StopService $Name }
    catch {
        return [pscustomobject]@{ Ok = $false; State = $info.Status; StartType = $info.StartType; Detail = "Stop-Service failed: $($_.Exception.Message)" }
    }
    Wait-ServiceReady -Name $Name -DesiredState 'Stopped' -TimeoutSeconds $WaitSeconds
}

function Wait-ServiceReady {
    <#
    .SYNOPSIS
        Poll until the service reaches -DesiredState or the timeout elapses.
        Returns @{Ok; State; StartType; Detail} with Ok reflecting the final
        comparison.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Running','Stopped')][string]$DesiredState,
        [int]$TimeoutSeconds = 30,
        [int]$PollMs = 250
    )
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $info = $null
    while ([datetime]::UtcNow -lt $deadline) {
        $info = & $script:ServiceInvokers.GetService $Name
        if ($info.Found -and $info.Status -eq $DesiredState) {
            return [pscustomobject]@{ Ok = $true; State = $info.Status; StartType = $info.StartType; Detail = "reached $DesiredState" }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    if (-not $info) { $info = & $script:ServiceInvokers.GetService $Name }
    return [pscustomobject]@{
        Ok        = ($info.Found -and $info.Status -eq $DesiredState)
        State     = if ($info.Found) { $info.Status } else { 'NotInstalled' }
        StartType = if ($info.Found) { $info.StartType } else { $null }
        Detail    = "timeout after ${TimeoutSeconds}s; last state $($info.Status)"
    }
}

function Install-NssmService {
    <#
    .SYNOPSIS
        Register a non-native service via NSSM. Idempotent: if the service
        already exists it is updated to match Spec, not duplicated.

    .PARAMETER Name        Service name (must be unique).
    .PARAMETER Executable  Path to the .exe to run as the service body.
    .PARAMETER Arguments   Command-line arguments to pass to Executable.
    .PARAMETER DisplayName Friendly name in services.msc.
    .PARAMETER Description Sentence shown under the service.
    .PARAMETER StartType   Automatic | Manual | Disabled.
    .PARAMETER LogonAs     LocalSystem (default) | LocalService | NetworkService.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Service registration is the explicit purpose; ShouldProcess would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Executable,
        [string]$Arguments = '',
        [string]$DisplayName,
        [string]$Description,
        [ValidateSet('Automatic','Manual','Disabled')]
        [string]$StartType = 'Automatic',
        [ValidateSet('LocalSystem','LocalService','NetworkService')]
        [string]$LogonAs = 'LocalSystem'
    )

    # Translate StartType -> nssm's "Start" value (SERVICE_AUTO_START, etc.)
    $nssmStart = switch ($StartType) {
        'Automatic' { 'SERVICE_AUTO_START' }
        'Manual'    { 'SERVICE_DEMAND_START' }
        'Disabled'  { 'SERVICE_DISABLED' }
    }

    $exists = (& $script:ServiceInvokers.GetService $Name).Found
    $verb   = if ($exists) { 'set' } else { 'install' }

    # NSSM 'install' or 'set' commands. We always call install for new services;
    # for existing ones we call 'set' for each tunable.
    if (-not $exists) {
        $installArgv = @('install', $Name, $Executable)
        if ($Arguments) { $installArgv += $Arguments }
        $r = & $script:ServiceInvokers.RunNssm $installArgv
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Ok = $false; State = 'Unknown'; StartType = $null; Detail = "nssm install exited $($r.ExitCode)" }
        }
    } else {
        $r = & $script:ServiceInvokers.RunNssm @('set', $Name, 'Application', $Executable)
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Ok = $false; State = 'Unknown'; StartType = $null; Detail = "nssm set Application exited $($r.ExitCode)" }
        }
        if ($Arguments) {
            $r2 = & $script:ServiceInvokers.RunNssm @('set', $Name, 'AppParameters', $Arguments)
            if ($r2.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; State = 'Unknown'; StartType = $null; Detail = "nssm set AppParameters exited $($r2.ExitCode)" } }
        }
    }

    # Common tunables (run for both install and set paths).
    foreach ($kv in @(
        @{ Key = 'Start';        Val = $nssmStart },
        @{ Key = 'DisplayName';  Val = $DisplayName },
        @{ Key = 'Description';  Val = $Description },
        @{ Key = 'ObjectName';   Val = $LogonAs }
    )) {
        if (-not $kv.Val) { continue }
        $r = & $script:ServiceInvokers.RunNssm @('set', $Name, $kv.Key, $kv.Val)
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Ok = $false; State = 'Unknown'; StartType = $null; Detail = "nssm set $($kv.Key) exited $($r.ExitCode)" }
        }
    }

    $after = & $script:ServiceInvokers.GetService $Name
    [pscustomobject]@{
        Ok        = $after.Found
        State     = if ($after.Found) { $after.Status }    else { 'Unknown' }
        StartType = if ($after.Found) { $after.StartType } else { $null }
        Detail    = "nssm $verb completed"
    }
}

Export-ModuleMember -Function `
    Get-ServiceInfo, Set-ServiceStartType, `
    Start-ServiceIdempotent, Stop-ServiceIdempotent, `
    Wait-ServiceReady, Install-NssmService, `
    ConvertTo-NssmArgList
