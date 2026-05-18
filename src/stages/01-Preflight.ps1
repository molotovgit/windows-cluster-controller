<#
.SYNOPSIS
    Stage 1 -- Preflight. Verify the controller PC can run the rest of
    the setup script.

.DESCRIPTION
    Read-only checks; no system mutation. Returns:
        @{
            Overall  = 'Pass' | 'Warn' | 'Fail'
            Checks   = @( @{Name; Status; Detail; Remediation} ... )
            PassCount; WarnCount; FailCount
        }

    Checks performed (controller-specific -- no Hyper-V / VT / SLAT
    requirements since the controller runs no VMs of its own):

       1. Administrator             must be elevated (services, firewall, SMB)
       2. Windows SKU               Pro / Enterprise / Education (Home rejected)
       3. RAM                       >= -MinRamGb (default 8 GB)
       4. Free disk space           >= -MinFreeDiskGb on system drive (default 50 GB)
       5. Network adapter           at least one Up adapter
       6. Task Scheduler service    Running (for reboot-resume task)
       7. Execution policy          not Restricted in the effective scope
       8. PowerShell version        >= 7.0 (warns instead of fails -- Stage 2 installs it)
       9. HTTPS port (443)          not already in use by another service
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Soft-load sibling lib modules in case the stage is dot-sourced outside
# the orchestrator. Orchestrator imports them first; this is belt-and-braces.
$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','HardwareDetect','Net') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

function Add-PreflightCheck {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Warn','Fail')][string]$Status,
        [string]$Detail,
        [string]$Remediation
    )
    $Checks.Add([pscustomobject]@{
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
    })
}

function Test-IsAdministrator {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch { $null = $_; return $false }
}

function Get-PreflightRamGb {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.TotalPhysicalMemory) { return [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1) }
    } catch { $null = $_ }
    try {
        $sum = (Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop |
            Measure-Object -Property Capacity -Sum).Sum
        if ($sum) { return [math]::Round([double]$sum / 1GB, 1) }
    } catch { $null = $_ }
    return $null
}

function Get-PreflightFreeDiskGb {
    param([string]$DriveLetter)
    if (-not $DriveLetter) {
        $sd = $env:SystemDrive
        if (-not $sd) { $sd = 'C:' }
        $DriveLetter = $sd.TrimEnd(':\').Substring(0,1)
    }
    try {
        $v = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        return [pscustomobject]@{
            DriveLetter = $DriveLetter
            FreeGb      = [math]::Round([double]$v.SizeRemaining / 1GB, 1)
            SizeGb      = [math]::Round([double]$v.Size          / 1GB, 1)
        }
    } catch {
        $null = $_
        return $null
    }
}

function Test-AnyNetworkAdapterUp {
    try {
        $up = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        return [bool]$up
    } catch { $null = $_; return $false }
}

function Get-TaskSchedulerStatus {
    try { (Get-Service -Name 'Schedule' -ErrorAction Stop).Status } catch { $null = $_; 'Missing' }
}

function Get-EffectiveExecutionPolicy {
    try {
        $effective = Get-ExecutionPolicy -ErrorAction SilentlyContinue
        if ($effective -and $effective -ne 'Undefined') { return $effective }
        return $null
    } catch { $null = $_; return $null }
}

function Invoke-PreflightStage {
    <#
    .SYNOPSIS
        Run all controller preflight checks and return the structured report.

    .PARAMETER Config
        Parsed cluster-controller.json (any pscustomobject). Optional.

    .PARAMETER MinRamGb           Default 8 (vs the host's 16).
    .PARAMETER MinFreeDiskGb      Default 50.
    .PARAMETER MinPwshVersion     Default 7.0.
    .PARAMETER HttpsPort          Default 443 (config-derived in orchestrator).
    .PARAMETER IgnoreFailures     Caller sets when in -DryRun -- Fail still
                                  appears in the report but does not raise Overall.
    #>
    [CmdletBinding()]
    param(
        $Config,
        [int]$MinRamGb       = 8,
        [int]$MinFreeDiskGb  = 50,
        [version]$MinPwshVersion = '7.0',
        [int]$HttpsPort      = 443,
        [switch]$IgnoreFailures
    )

    $checks = New-Object System.Collections.Generic.List[object]

    # ---------- 1. Administrator ----------
    if (Test-IsAdministrator) {
        Add-PreflightCheck -Checks $checks -Name 'Administrator' -Status Pass -Detail 'Running elevated.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Administrator' -Status Fail `
            -Detail 'Not running as Administrator.' `
            -Remediation 'Right-click PowerShell and Run as Administrator, then re-run the setup script.'
    }

    # ---------- 2. Windows SKU ----------
    $sku = Get-WindowsSku
    if ($sku.Sku -in 'Pro','Enterprise','Education') {
        Add-PreflightCheck -Checks $checks -Name 'Windows SKU' -Status Pass -Detail "$($sku.Sku) (source: $($sku.Source))"
    } elseif ($sku.Sku -eq 'Home') {
        Add-PreflightCheck -Checks $checks -Name 'Windows SKU' -Status Fail `
            -Detail 'Windows Home -- SMB share + service management features are limited.' `
            -Remediation 'Upgrade to Windows 11 Pro / Enterprise / Education via Settings -> System -> Activation.'
    } elseif ($env:CLUSTERCTRL_ALLOW_UNKNOWN_SKU) {
        Add-PreflightCheck -Checks $checks -Name 'Windows SKU' -Status Pass `
            -Detail "Unknown SKU accepted via CLUSTERCTRL_ALLOW_UNKNOWN_SKU. Raw: '$($sku.Raw)' source: $($sku.Source)"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Windows SKU' -Status Warn `
            -Detail "Could not determine SKU. Raw: '$($sku.Raw)' source: $($sku.Source)" `
            -Remediation 'Set $env:CLUSTERCTRL_ALLOW_UNKNOWN_SKU=1 (or pass -IgnoreFailures) after manual verification.'
    }

    # ---------- 3. RAM ----------
    $ram = Get-PreflightRamGb
    if ($null -eq $ram) {
        Add-PreflightCheck -Checks $checks -Name 'RAM' -Status Warn `
            -Detail 'Could not query physical memory.' `
            -Remediation 'Verify Get-CimInstance Win32_ComputerSystem works.'
    } elseif ($ram -ge $MinRamGb) {
        Add-PreflightCheck -Checks $checks -Name 'RAM' -Status Pass -Detail "${ram} GB (>= ${MinRamGb} GB)"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'RAM' -Status Fail `
            -Detail "Only ${ram} GB installed; controller needs >= ${MinRamGb} GB." `
            -Remediation 'Install more RAM, or switch to db.mode=nedb in cluster-controller.json to skip MongoDB memory overhead.'
    }

    # ---------- 4. Free disk space ----------
    $disk = Get-PreflightFreeDiskGb
    if (-not $disk) {
        Add-PreflightCheck -Checks $checks -Name 'Free disk space' -Status Warn `
            -Detail 'Could not query the system drive volume.' `
            -Remediation 'Verify Get-Volume works on the system drive.'
    } elseif ($disk.FreeGb -ge $MinFreeDiskGb) {
        Add-PreflightCheck -Checks $checks -Name 'Free disk space' -Status Pass `
            -Detail "$($disk.DriveLetter): has $($disk.FreeGb) GB free (need >= ${MinFreeDiskGb})"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Free disk space' -Status Fail `
            -Detail "$($disk.DriveLetter): has only $($disk.FreeGb) GB free; need >= ${MinFreeDiskGb} GB." `
            -Remediation 'Free disk space or relocate %ProgramData% to a larger volume.'
    }

    # ---------- 5. Network adapter ----------
    if (Test-AnyNetworkAdapterUp) {
        Add-PreflightCheck -Checks $checks -Name 'Network adapter' -Status Pass -Detail 'At least one adapter is Up.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Network adapter' -Status Fail `
            -Detail 'No network adapter is in Up state.' `
            -Remediation 'Connect to the cluster network and verify ipconfig shows a usable address before re-running.'
    }

    # ---------- 6. Task Scheduler service ----------
    $svc = Get-TaskSchedulerStatus
    if ($svc -eq 'Running') {
        Add-PreflightCheck -Checks $checks -Name 'Task Scheduler service' -Status Pass -Detail 'Schedule service is Running.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Task Scheduler service' -Status Fail `
            -Detail "Schedule service is '$svc'." `
            -Remediation 'Run: Set-Service Schedule -StartupType Automatic; Start-Service Schedule'
    }

    # ---------- 7. Execution policy ----------
    $ep = Get-EffectiveExecutionPolicy
    if (-not $ep) {
        Add-PreflightCheck -Checks $checks -Name 'Execution policy' -Status Warn `
            -Detail 'Could not read the execution policy.' `
            -Remediation 'Verify Get-ExecutionPolicy works as Administrator.'
    } elseif ($ep -in 'Bypass','Unrestricted','RemoteSigned','AllSigned') {
        Add-PreflightCheck -Checks $checks -Name 'Execution policy' -Status Pass -Detail "Effective policy: $ep"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Execution policy' -Status Fail `
            -Detail "Effective policy '$ep' blocks script execution." `
            -Remediation 'Run as Admin: Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force'
    }

    # ---------- 8. PowerShell version (warn, not fail -- Stage 2 installs it) ----------
    $ver = $PSVersionTable.PSVersion
    if ($ver -ge $MinPwshVersion) {
        Add-PreflightCheck -Checks $checks -Name 'PowerShell version' -Status Pass -Detail "PowerShell $ver (>= $MinPwshVersion)"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'PowerShell version' -Status Warn `
            -Detail "PowerShell $ver is below $MinPwshVersion; Stage 2 will attempt to install pwsh 7." `
            -Remediation 'Stage 2 (PowerShell7) installs PowerShell 7 LTS. Setup will resume under pwsh after install.'
    }

    # ---------- 9. HTTPS port free ----------
    if (Get-Command -Name 'Test-NetPortInUse' -ErrorAction SilentlyContinue) {
        if (Test-NetPortInUse -Port $HttpsPort -Address '127.0.0.1' -TimeoutMs 400) {
            Add-PreflightCheck -Checks $checks -Name "TCP $HttpsPort free" -Status Fail `
                -Detail "Something is already listening on 127.0.0.1:$HttpsPort." `
                -Remediation "Identify the listener via 'Get-NetTCPConnection -LocalPort $HttpsPort' and stop/relocate it before re-running."
        } else {
            Add-PreflightCheck -Checks $checks -Name "TCP $HttpsPort free" -Status Pass -Detail "No listener on 127.0.0.1:$HttpsPort."
        }
    } else {
        Add-PreflightCheck -Checks $checks -Name "TCP $HttpsPort free" -Status Warn `
            -Detail 'lib/Net.psm1 not loaded; cannot probe the HTTPS port.'
    }

    # ---------- summary ----------
    $passCount = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
    $warnCount = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
    $failCount = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count

    $overall = if ($failCount -gt 0 -and -not $IgnoreFailures) { 'Fail' }
               elseif ($warnCount -gt 0) { 'Warn' }
               else { 'Pass' }

    if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
        foreach ($c in $checks) {
            $lvl = switch ($c.Status) { 'Pass' { 'Info' } 'Warn' { 'Warn' } 'Fail' { 'Error' } }
            Write-ClusterLog -Level $lvl -Stage 'preflight' `
                -Message "$($c.Name): $($c.Status)" -Data @{ detail = $c.Detail }
        }
        Write-ClusterLog -Level Info -Stage 'preflight' `
            -Message "Preflight complete: $overall (pass=$passCount warn=$warnCount fail=$failCount)"
    }

    return [pscustomobject]@{
        Overall    = $overall
        Checks     = $checks.ToArray()
        PassCount  = $passCount
        WarnCount  = $warnCount
        FailCount  = $failCount
    }
}
