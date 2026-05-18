<#
.SYNOPSIS
    Stage 12 -- Cluster Announcer. Writes the announcer payload JSON
    + the HttpListener PowerShell script, registers them as the
    'ClusterAnnouncer' Windows service via NSSM, starts it.

.DESCRIPTION
    The Announcer is a tiny HTTP responder that serves /.well-known/
    cluster-controller -> JSON describing this controller. Hosts'
    Discovery module hits this endpoint to auto-find the controller.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Announce','Service','Net','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

function Get-DefaultAnnouncerStageInvoker {
    @{
        WriteFile = {
            param([string]$Path, [string]$Body)
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($Path, $Body, [System.Text.UTF8Encoding]::new($false))
        }
        ResolvePwshExe = {
            $c = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
            if ($c) { return $c.Source }
            $c2 = Get-Command -Name 'powershell' -ErrorAction SilentlyContinue
            if ($c2) { return $c2.Source }
            return $null
        }
    }
}

$script:AnnouncerStageInvokers = Get-DefaultAnnouncerStageInvoker

function Confirm-AnnouncerStageTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-AnnouncerStageInvoker."
    }
}

function Set-AnnouncerStageInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('WriteFile','ResolvePwshExe')][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-AnnouncerStageTestSeamAllowed
    $script:AnnouncerStageInvokers[$Name] = $ScriptBlock
}

function Reset-AnnouncerStageInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-AnnouncerStageTestSeamAllowed
    $script:AnnouncerStageInvokers = Get-DefaultAnnouncerStageInvoker
}

function Invoke-AnnouncerStage {
    [CmdletBinding()]
    param(
        $Config,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $hostname  = "$($cfg.controller.hostname)"
    $lanIp     = if ($cfg.controller.PSObject.Properties['lan_ip']) { "$($cfg.controller.lan_ip)" } else { $null }
    $httpsPort = [int]$cfg.controller.https_port
    $agentPort = [int]$cfg.controller.agent_port
    $annPort   = [int]$cfg.controller.announcer_port

    $progData  = $env:ProgramData
    if (-not $progData) { $progData = 'C:\ProgramData' }
    $ctrlRoot  = Join-Path $progData 'ClusterController'
    $binDir    = Join-Path $ctrlRoot 'bin'
    $scriptPath  = Join-Path $binDir 'announcer.ps1'
    $payloadPath = Join-Path $binDir 'announcer-payload.json'

    _step 'Resolve announcer plan' 'Pass' "port=$annPort script=$scriptPath payload=$payloadPath"

    if ($DryRun) {
        _step 'Install announcer service' 'Skipped' '-DryRun: would have written files + registered service'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: announcer' }
    }

    # 1. Build payload JSON and announcer script.
    $payload = New-AnnouncerPayload -Hostname $hostname -LanIp $lanIp `
                                     -HttpsPort $httpsPort -AgentPort $agentPort -Version '0.1.0'
    $payloadBody = $payload | ConvertTo-Json -Depth 4

    try { & $script:AnnouncerStageInvokers.WriteFile $payloadPath $payloadBody }
    catch {
        _step 'Write payload' 'Fail' "$($_.Exception.Message)"
        return [pscustomobject]@{ Overall='Fail'; Steps=$steps.ToArray(); Detail='payload write failed' }
    }
    _step 'Write payload' 'Pass' "$payloadPath"

    $scriptBody = Get-AnnouncerScriptContent -Port $annPort -PayloadFile $payloadPath
    try { & $script:AnnouncerStageInvokers.WriteFile $scriptPath $scriptBody }
    catch {
        _step 'Write announcer script' 'Fail' "$($_.Exception.Message)"
        return [pscustomobject]@{ Overall='Fail'; Steps=$steps.ToArray(); Detail='script write failed' }
    }
    _step 'Write announcer script' 'Pass' "$scriptPath"

    # 2. Ensure NSSM is reachable before calling Install-NssmService. NSSM
    # isn't part of Windows; we have to source it from one of:
    #   a) Already on PATH (operator pre-installed, or a previous run).
    #   b) A previous run staged it at %ProgramData%\ClusterController\bin\.
    #   c) winget install NSSM.NSSM (preferred -- uses the same nssm.cc/ci
    #      CDN path which is more reliable than nssm.cc/release/*).
    #   d) Direct download from nssm.cc/release/nssm-2.24.zip (last resort;
    #      observed to 503 in 2026-05, so kept only as a safety net).
    # lib/Service's invoker calls 'nssm.exe' by name -- so whichever path we
    # take, we end by ensuring nssm.exe is resolvable via Get-Command.
    function _RefreshPathFromRegistry {
        # winget installs may modify the system PATH but the change is not
        # visible to processes that started before the install. Pull both
        # Machine and User PATH and merge into the current process env so
        # Get-Command picks up the freshly-installed nssm.
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $merged  = ($machine, $user) | Where-Object { $_ } | ForEach-Object { $_ }
        if ($merged) { $env:Path = ($merged -join ';') }
    }
    function _TryWingetInstallNssm {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) { return $false }
        try {
            $p = Start-Process -FilePath $winget.Source `
                -ArgumentList @('install','-e','--id','NSSM.NSSM','--silent','--accept-source-agreements','--accept-package-agreements') `
                -PassThru -Wait -WindowStyle Hidden
            # winget returns 0 on success and on "already installed".
            if ($p.ExitCode -in 0, -1978335189) {
                _RefreshPathFromRegistry
                return [bool](Get-Command nssm -ErrorAction SilentlyContinue)
            }
        } catch { $null = $_ }
        return $false
    }
    function _TryDirectDownloadNssm([string]$NssmDir, [string]$NssmExe) {
        if (-not (Test-Path -LiteralPath $NssmDir)) {
            New-Item -Path $NssmDir -ItemType Directory -Force | Out-Null
        }
        # nssm.cc/release/* has been observed to return 503 Service
        # Temporarily Unavailable; the /ci/* CDN that winget uses is more
        # reliable, but we don't know the version-stamped URL outside winget.
        # Try /release/ once, then bail with a clear error pointing the
        # operator at the winget alternative.
        $zipUrl = 'https://nssm.cc/release/nssm-2.24.zip'
        $zip = Join-Path $env:TEMP ("nssm-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.zip')
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
            $extractDir = Join-Path $env:TEMP ("nssm-extract-" + [guid]::NewGuid().ToString('N').Substring(0,8))
            Expand-Archive -Path $zip -DestinationPath $extractDir -Force
            $arch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
            $src = Get-ChildItem -Path $extractDir -Recurse -File -Filter nssm.exe |
                   Where-Object { $_.DirectoryName -like "*\$arch" } |
                   Select-Object -First 1
            if (-not $src) { throw "nssm.exe ($arch) not found in extracted archive" }
            Copy-Item -LiteralPath $src.FullName -Destination $NssmExe -Force
            Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        } finally {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $NssmExe)) {
            throw "NSSM download from $zipUrl completed but nssm.exe not at $NssmExe"
        }
    }
    function _EnsureNssm {
        # (a) Already on PATH?
        $existing = Get-Command nssm -ErrorAction SilentlyContinue
        if ($existing) { return $existing.Source }

        # (b) Staged by a previous run?
        $nssmDir = Join-Path $env:ProgramData 'ClusterController\bin'
        $nssmExe = Join-Path $nssmDir 'nssm.exe'
        if (Test-Path -LiteralPath $nssmExe) {
            if (-not ($env:Path -split ';' | Where-Object { $_ -eq $nssmDir })) {
                $env:Path = "$nssmDir;$env:Path"
            }
            return $nssmExe
        }

        # (c) winget -- preferred over direct download (observed reliable
        # when nssm.cc/release/* returns 503).
        Write-Host 'Installing NSSM via winget ...' -ForegroundColor Yellow
        if (_TryWingetInstallNssm) {
            $cmd = Get-Command nssm -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
        }

        # (d) Direct download from nssm.cc -- last resort.
        Write-Host 'winget unavailable or did not yield nssm; falling back to direct download from nssm.cc ...' -ForegroundColor Yellow
        _TryDirectDownloadNssm -NssmDir $nssmDir -NssmExe $nssmExe
        # Prepend to PATH for this process so lib/Service's `Start-Process nssm.exe` finds it.
        $env:Path = "$nssmDir;$env:Path"
        return $nssmExe
    }

    try {
        $nssmExe = _EnsureNssm
        _step 'Ensure NSSM' 'Pass' "nssm=$nssmExe"
    } catch {
        _step 'Ensure NSSM' 'Fail' "could not provision nssm.exe: $($_.Exception.Message)"
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = "NSSM is required for the Announcer service and could not be downloaded: $($_.Exception.Message)"
            Remediation = "Download NSSM from https://nssm.cc/download manually and place nssm.exe under %ProgramData%\ClusterController\bin\, then re-run from -StartFromStage 12."
        }
    }

    # 3. Install as NSSM service.
    $pwshExe = & $script:AnnouncerStageInvokers.ResolvePwshExe
    if (-not $pwshExe) {
        _step 'Install announcer service' 'Fail' 'no pwsh.exe or powershell.exe on PATH'
        return [pscustomobject]@{ Overall='Fail'; Steps=$steps.ToArray(); Detail='no PowerShell exe' }
    }
    $svcName = 'ClusterAnnouncer'
    $args    = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $nssm = Install-NssmService -Name $svcName -Executable $pwshExe -Arguments $args `
                                 -DisplayName 'Cluster Controller Announcer' `
                                 -Description 'Serves /.well-known/cluster-controller JSON for host discovery' `
                                 -StartType 'Automatic' -LogonAs 'LocalSystem'
    if (-not $nssm.Ok) {
        _step 'Install announcer service' 'Fail' $nssm.Detail
        return [pscustomobject]@{
            Overall     = 'Fail'
            Steps       = $steps.ToArray()
            Detail      = "NSSM registration failed: $($nssm.Detail)"
            Remediation = 'Verify NSSM is installed (Stage 4 dependency) and re-run.'
        }
    }
    _step 'Install announcer service' 'Pass' $nssm.Detail

    # 3. Start + verify port listening.
    $start = Start-ServiceIdempotent -Name $svcName -WaitSeconds 15
    if ($start.Ok -and $start.State -eq 'Running') {
        _step 'Start announcer service' 'Pass' $start.Detail
    } else {
        _step 'Start announcer service' 'Warn' $start.Detail
    }
    Start-Sleep -Milliseconds 250
    if (Test-NetPortInUse -Port $annPort -Address '127.0.0.1' -TimeoutMs 1000) {
        _step 'Verify announcer listening' 'Pass' "127.0.0.1:$annPort accepting connections"
    } else {
        _step 'Verify announcer listening' 'Warn' "127.0.0.1:$annPort did not respond yet"
    }

    [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "announcer service '$svcName' Running on $annPort" }
}
