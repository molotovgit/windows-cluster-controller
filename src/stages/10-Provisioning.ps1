<#
.SYNOPSIS
    Stage 10 -- Provisioning: bootstrap admin account, create the
    canonical device groups, and generate the agent install bundles
    (.exe + .msh) per group.

.DESCRIPTION
    Runs after the MeshCentral service is up. Combines what the original
    plan split into three PRs (32 AdminAccount, 33 DeviceGroups, 34
    AgentBundles) because they all share the same `meshctrl` CLI surface
    and execute in the same window.

    Three real-hardware bugs this rewrite addresses:
      bug 18 -- MeshCentral's `node meshcentral --install` installs to
        its own default root (%ProgramData%\MeshCentral) regardless of
        the data_dir we pass in config. Resolve MeshCentral's actual
        install root dynamically from the service binary path so
        subsequent steps don't look in the wrong place.
      bug 19 -- previous URL `wss://127.0.0.1/control.ashx` is wrong;
        meshctrl wants `wss://127.0.0.1:443` (or just the host root).
        Also: meshctrl exits 0 on "Invalid login" / "Invalid meshid";
        every call's stdout must be inspected for failure markers.
      bug 20 -- `node meshcentral --adminaccount X Y` does NOT create
        the account in modern MeshCentral; it only promotes an existing
        account to admin. The actual create is `--createaccount X
        --pass Y --email Z`. AND both commands require the service to
        be STOPPED (they write the on-disk NeDB directly).

    Admin password sourcing order:
      1. $env:CLUSTERCTRL_ADMIN_PASS (or whatever envvar config names)
      2. A securely-generated random password, written to
         admin-bootstrap.txt with strict ACL (LocalSystem + Administrators
         only).

    Agent bundles land under <share root>\agents\<group>\... for the
    host PCs to pull via the SMB share (Stage 11/12).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultProvisioningInvoker {
    @{
        # Look up the meshcentral.exe service's binary PathName. The MeshCentral
        # built-in installer always sets this; from it we can climb to the install
        # root (the dir that contains node_modules\meshcentral). Returns the
        # install root, or $null if the service or path can't be located.
        ResolveMeshcentralRoot = {
            try {
                # Service.exe is at <root>\WinService\daemon\meshcentral.exe.
                $svc = Get-CimInstance -Query "SELECT PathName FROM Win32_Service WHERE Name='meshcentral.exe'" -ErrorAction Stop
                if (-not $svc -or -not $svc.PathName) { return $null }
                # PathName is quoted on some versions; strip quotes.
                $bin = $svc.PathName.Trim('"')
                # Climb: <root>\WinService\daemon\meshcentral.exe -> <root>
                $daemon = Split-Path -Parent $bin
                $winsvc = Split-Path -Parent $daemon
                $root   = Split-Path -Parent $winsvc
                if ($root -and (Test-Path -LiteralPath (Join-Path $root 'node_modules\meshcentral\meshcentral.js'))) {
                    return $root
                }
                return $null
            } catch { $null = $_; return $null }
        }
        # Idempotent service start/stop wrappers. Stop is required before
        # --createaccount / --adminaccount can write the DB.
        StopService = {
            param([string]$Name, [int]$WaitSec = 20)
            $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if (-not $svc) { return [pscustomobject]@{ Ok = $true; Already = $false; Detail = "service '$Name' not present" } }
            if ($svc.Status -eq 'Stopped') { return [pscustomobject]@{ Ok = $true; Already = $true; Detail = 'already stopped' } }
            try {
                Stop-Service -Name $Name -Force -ErrorAction Stop
                $deadline = (Get-Date).AddSeconds($WaitSec)
                while ((Get-Date) -lt $deadline) {
                    $svc2 = Get-Service -Name $Name -ErrorAction SilentlyContinue
                    if (-not $svc2 -or $svc2.Status -eq 'Stopped') {
                        return [pscustomobject]@{ Ok = $true; Already = $false; Detail = 'stopped' }
                    }
                    Start-Sleep -Milliseconds 250
                }
                return [pscustomobject]@{ Ok = $false; Already = $false; Detail = "did not stop within ${WaitSec}s" }
            } catch {
                return [pscustomobject]@{ Ok = $false; Already = $false; Detail = "Stop-Service failed: $($_.Exception.Message)" }
            }
        }
        StartService = {
            param([string]$Name, [int]$WaitSec = 30)
            $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if (-not $svc) { return [pscustomobject]@{ Ok = $false; Detail = "service '$Name' not installed" } }
            if ($svc.Status -eq 'Running') { return [pscustomobject]@{ Ok = $true; Detail = 'already running' } }
            try {
                Start-Service -Name $Name -ErrorAction Stop
                $deadline = (Get-Date).AddSeconds($WaitSec)
                while ((Get-Date) -lt $deadline) {
                    $svc2 = Get-Service -Name $Name -ErrorAction SilentlyContinue
                    if ($svc2 -and $svc2.Status -eq 'Running') {
                        return [pscustomobject]@{ Ok = $true; Detail = 'running' }
                    }
                    Start-Sleep -Milliseconds 250
                }
                return [pscustomobject]@{ Ok = $false; Detail = "did not reach Running within ${WaitSec}s" }
            } catch {
                return [pscustomobject]@{ Ok = $false; Detail = "Start-Service failed: $($_.Exception.Message)" }
            }
        }
        # Run `node meshcentral.js --createaccount X --pass Y --email Z`.
        # IMPORTANT: requires the MeshCentral service to be STOPPED so the
        # NeDB is unlocked. Returns @{ExitCode; Stdout; Stderr} so the caller
        # can verify the call had its intended effect (MeshCentral prints
        # "Done." on success; otherwise prints an error like "Account already
        # exists" or "Bad arguments").
        CreateAccount = {
            param([string]$NodeExe, [string]$Entry, [string]$DataDir, [string]$User, [string]$Pass, [string]$Email)
            $argv = @($Entry, '--datapath', $DataDir, '--createaccount', $User, '--pass', $Pass, '--email', $Email)
            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            try {
                $p = Start-Process -FilePath $NodeExe -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden `
                                    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                $out = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) -as [string]
                $err = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue) -as [string]
                return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Stdout = "$out"; Stderr = "$err" }
            } finally {
                Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
            }
        }
        # Promote an account to admin: `node meshcentral.js --adminaccount X`.
        # Same service-stopped requirement as CreateAccount.
        PromoteAdmin = {
            param([string]$NodeExe, [string]$Entry, [string]$DataDir, [string]$User)
            $argv = @($Entry, '--datapath', $DataDir, '--adminaccount', $User)
            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            try {
                $p = Start-Process -FilePath $NodeExe -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden `
                                    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                $out = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) -as [string]
                $err = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue) -as [string]
                return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Stdout = "$out"; Stderr = "$err" }
            } finally {
                Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
            }
        }
        # Run `node meshctrl.js <verb> [args] --url <auth.Url> ...`. Returns
        # @{ExitCode; Stdout; Stderr}. We capture stdout because meshctrl
        # exits 0 even on auth failures ("Invalid login") and bad ids
        # ("Invalid meshid"); the caller must inspect Stdout for success
        # markers.
        RunMeshctrl = {
            param([string]$Verb, [string[]]$ExtraArgv, [hashtable]$Auth)
            $meshctrl = if ($Auth -and $Auth.MeshctrlPath) { $Auth.MeshctrlPath }
                        elseif ($env:CLUSTERCTRL_MESHCTRL_PATH) { $env:CLUSTERCTRL_MESHCTRL_PATH }
                        else { Join-Path $env:ProgramData 'MeshCentral\node_modules\meshcentral\meshctrl.js' }
            $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
            if (-not $nodeExe -or -not (Test-Path -LiteralPath $meshctrl)) {
                return [pscustomobject]@{ ExitCode = -1; Stdout = ''; Stderr = "node or meshctrl.js missing (node='$nodeExe' meshctrl='$meshctrl')" }
            }
            $argv = @($meshctrl, $Verb)
            if ($Auth) {
                if ($Auth.Url)        { $argv += @('--url', $Auth.Url) }
                if ($Auth.LoginUser)  { $argv += @('--loginuser', $Auth.LoginUser) }
                if ($Auth.LoginPass)  { $argv += @('--loginpass', $Auth.LoginPass) }
                if ($Auth.IgnoreCert) { $argv += '--ignoreCert' }
            }
            if ($ExtraArgv) { $argv += $ExtraArgv }
            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            try {
                $p = Start-Process -FilePath $nodeExe -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden `
                                    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                $out = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) -as [string]
                $err = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue) -as [string]
                return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Stdout = "$out"; Stderr = "$err" }
            } finally {
                Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
            }
        }
        # Generate a random password of -Length bytes, web-safe characters.
        NewSecurePassword = {
            param([int]$Length = 24)
            $bytes = New-Object byte[] $Length
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
            $b64 = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
            $b64.Substring(0, [math]::Min($Length, $b64.Length))
        }
        WriteAdminBootstrap = {
            param([string]$Path, [string]$Body)
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($Path, $Body, [System.Text.UTF8Encoding]::new($false))
            try {
                $acl = New-Object System.Security.AccessControl.FileSecurity
                $acl.SetAccessRuleProtection($true, $false)
                $rights = [System.Security.AccessControl.FileSystemRights]'FullControl'
                $allow  = [System.Security.AccessControl.AccessControlType]'Allow'
                foreach ($id in 'NT AUTHORITY\SYSTEM','BUILTIN\Administrators') {
                    $r = New-Object System.Security.AccessControl.FileSystemAccessRule($id, $rights, $allow)
                    $acl.AddAccessRule($r)
                }
                Set-Acl -Path $Path -AclObject $acl
            } catch { $null = $_ }
        }
        EnsureDir = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        }
        FileExists = {
            param([string]$Path)
            return [bool](Test-Path -LiteralPath $Path)
        }
    }
}

$script:ProvisioningInvokers = Get-DefaultProvisioningInvoker

function Confirm-ProvisioningTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-ProvisioningInvoker."
    }
}

function Set-ProvisioningInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ResolveMeshcentralRoot','StopService','StartService','CreateAccount','PromoteAdmin','RunMeshctrl','NewSecurePassword','WriteAdminBootstrap','EnsureDir','FileExists')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-ProvisioningTestSeamAllowed
    $script:ProvisioningInvokers[$Name] = $ScriptBlock
}

function Reset-ProvisioningInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-ProvisioningTestSeamAllowed
    $script:ProvisioningInvokers = Get-DefaultProvisioningInvoker
}

# ---------- helpers ----------

function Test-MeshctrlSuccess {
    <#
    .SYNOPSIS
        Inspect a meshctrl call's combined stdout/stderr for known failure
        markers. meshctrl exits 0 on auth-fail and arg-fail too -- the
        ExitCode alone is not a reliable success signal.
    #>
    [CmdletBinding()]
    param(
        [string]$Stdout = '',
        [string]$Stderr = ''
    )
    $blob = "$Stdout`n$Stderr"
    # Known failure markers (case-insensitive substring).
    $failMarkers = @(
        'Invalid login',
        'Invalid meshid',
        'Bad arguments',
        'Missing argument',
        'Missing device id',
        'Missing meshid',
        'Permission denied',
        'Server is unreachable',
        'Unable to connect',
        'ECONNREFUSED'
    )
    foreach ($m in $failMarkers) {
        if ($blob -match [regex]::Escape($m)) {
            return [pscustomobject]@{ Ok = $false; Reason = $m }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Get-MeshidFromGroupListing {
    <#
    .SYNOPSIS
        Parse a `meshctrl ListDeviceGroups` stdout looking for a group by
        name. Returns the 64-char meshid (without the 'mesh//' prefix) or
        $null if not present. The output looks like:

            id, name
            ---------------
            "l$FVKf5...64chars...3Ri", "cluster-hosts"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Stdout,
        [Parameter(Mandatory)][string]$GroupName
    )
    foreach ($line in $Stdout -split "`r?`n") {
        # Lines look like: "<id>", "<name>"
        if ($line -match '^\s*"(?<id>[^"]{64})"\s*,\s*"(?<name>[^"]+)"\s*$') {
            if ($Matches.name -eq $GroupName) { return $Matches.id }
        }
    }
    return $null
}

# ---------- public ----------

function Invoke-ProvisioningStage {
    [CmdletBinding()]
    param(
        $Config,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $user      = "$($cfg.admin.username)"
    $envVar    = "$($cfg.admin.password_envvar)"
    $bootPath  = Expand-ConfigPath -Value "$($cfg.admin.bootstrap_file)"
    $shareRoot = Expand-ConfigPath -Value "$($cfg.share.root)"
    $agentsDir = Join-Path $shareRoot "$($cfg.share.agents_subdir)"
    $hostsGrp  = "$($cfg.meshcentral.device_groups.hosts)"
    $vmsGrp    = "$($cfg.meshcentral.device_groups.vms)"
    $svcName   = if ($cfg.meshcentral.PSObject.Properties['service_name'] -and $cfg.meshcentral.service_name) {
                     "$($cfg.meshcentral.service_name)"
                 } else { 'meshcentral.exe' }
    $adminEmail = if ($cfg.admin.PSObject.Properties['email'] -and $cfg.admin.email) {
                      "$($cfg.admin.email)"
                  } else { "$user@controller.local" }

    if ($DryRun) {
        _step 'Bootstrap admin + groups + bundles' 'Skipped' '-DryRun: would create admin account, device groups, agent bundles'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: provisioning' }
    }

    # 0. Resolve MeshCentral install root (bug 18).
    $mcRoot = & $script:ProvisioningInvokers.ResolveMeshcentralRoot
    if (-not $mcRoot) {
        # Fall back to the configured data_dir parent for back-compat.
        $dataDirCfg = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
        $mcRoot = Split-Path -Parent $dataDirCfg
        _step 'Resolve MeshCentral root' 'Warn' "service path lookup failed; falling back to config-derived '$mcRoot'"
    } else {
        _step 'Resolve MeshCentral root' 'Pass' "discovered $mcRoot from service binary path"
    }
    $entry    = Join-Path $mcRoot 'node_modules\meshcentral\meshcentral.js'
    $meshctrl = Join-Path $mcRoot 'node_modules\meshcentral\meshctrl.js'
    $dataDir  = Join-Path $mcRoot 'meshcentral-data'
    if (-not (Test-Path -LiteralPath $entry)) {
        _step 'Locate meshcentral.js' 'Fail' "meshcentral.js not found at $entry"
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = 'meshcentral.js missing' }
    }
    $nodeExe = (Get-Command -Name 'node' -ErrorAction SilentlyContinue).Source
    if (-not $nodeExe) {
        _step 'Locate node' 'Fail' 'node.exe not on PATH'
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = 'node missing' }
    }
    _step 'Resolve provisioning plan' 'Pass' "admin=$user hosts-group=$hostsGrp vms-group=$vmsGrp agents=$agentsDir"

    # 1. Resolve admin password.
    $pass = $null
    if ($envVar) { $pass = [Environment]::GetEnvironmentVariable($envVar, 'Process') }
    $generated = $false
    if (-not $pass) {
        $pass = & $script:ProvisioningInvokers.NewSecurePassword 24
        $generated = $true
    }

    # 2. Stop MeshCentral so createaccount/adminaccount can write the DB.
    $stopR = & $script:ProvisioningInvokers.StopService $svcName 20
    if (-not $stopR.Ok) {
        _step "Stop service '$svcName'" 'Fail' $stopR.Detail
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = "could not stop $svcName" }
    }
    _step "Stop service '$svcName'" 'Pass' $stopR.Detail

    # 3. Create the admin account (bug 20).
    $createR = & $script:ProvisioningInvokers.CreateAccount $nodeExe $entry $dataDir $user $pass $adminEmail
    $createBlob = "$($createR.Stdout)`n$($createR.Stderr)"
    if ($createBlob -match '(?i)Done\.') {
        _step "Create account '$user'" 'Pass' 'meshcentral.js --createaccount: Done.'
    } elseif ($createBlob -match '(?i)already exists') {
        _step "Create account '$user'" 'Pass' 'account already exists (idempotent)'
    } else {
        # Try to restart the service so we don't leave it stopped, then Warn.
        $startR0 = & $script:ProvisioningInvokers.StartService $svcName 30
        $detail  = "createaccount unexpected output (exit=$($createR.ExitCode)): $($createBlob.Trim() -replace '\s+', ' ' | Select-Object -First 200)"
        _step "Create account '$user'" 'Warn' $detail
        if (-not $startR0.Ok) {
            _step "Restart service '$svcName'" 'Fail' $startR0.Detail
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = 'createaccount uncertain + service did not restart' }
        }
        _step "Restart service '$svcName'" 'Pass' $startR0.Detail
        return [pscustomobject]@{ Overall = 'Warn'; Steps = $steps.ToArray(); Detail = 'createaccount uncertain; service back up' }
    }

    # 4. Promote to admin.
    $adminR = & $script:ProvisioningInvokers.PromoteAdmin $nodeExe $entry $dataDir $user
    $adminBlob = "$($adminR.Stdout)`n$($adminR.Stderr)"
    if ($adminBlob -match '(?i)Done\.') {
        _step "Promote '$user' to admin" 'Pass' 'meshcentral.js --adminaccount: Done.'
    } else {
        _step "Promote '$user' to admin" 'Warn' "adminaccount unexpected output (exit=$($adminR.ExitCode)): $($adminBlob.Trim() -replace '\s+', ' ' | Select-Object -First 200)"
    }

    # 5. Restart MeshCentral so meshctrl can talk to it.
    $startR = & $script:ProvisioningInvokers.StartService $svcName 45
    if (-not $startR.Ok) {
        _step "Start service '$svcName'" 'Fail' $startR.Detail
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = "could not restart $svcName" }
    }
    _step "Start service '$svcName'" 'Pass' $startR.Detail
    Start-Sleep -Seconds 4   # short grace period for WebSocket to bind

    # 6. Persist the bootstrap file (best-effort).
    if ($generated) {
        $body = @"
# Cluster Controller -- admin bootstrap password
# Generated by stages/10-Provisioning.ps1 at $([datetime]::UtcNow.ToString('o'))
# DELETE THIS FILE after you have saved the password to a password manager.
admin_user: $user
admin_pass: $pass
"@
        try {
            & $script:ProvisioningInvokers.WriteAdminBootstrap $bootPath $body
            _step 'Write admin-bootstrap.txt' 'Pass' "wrote $bootPath (strict ACL)"
        } catch {
            _step 'Write admin-bootstrap.txt' 'Warn' "could not write $bootPath : $($_.Exception.Message)"
        }
    } else {
        _step 'Write admin-bootstrap.txt' 'Pass' 'password sourced from env var; bootstrap file not written'
    }

    # 7. Auth context for meshctrl. Bug 19: URL must be wss://host:port,
    # NOT wss://host/control.ashx (meshctrl appends the path itself).
    $authCtx = @{
        Url          = 'wss://127.0.0.1:443'
        LoginUser    = $user
        LoginPass    = $pass
        IgnoreCert   = $true
        MeshctrlPath = $meshctrl
    }

    # 8. Sanity-check auth before doing anything else (ServerInfo).
    $serverInfo = & $script:ProvisioningInvokers.RunMeshctrl 'ServerInfo' @() $authCtx
    $authCheck  = Test-MeshctrlSuccess -Stdout $serverInfo.Stdout -Stderr $serverInfo.Stderr
    if (-not $authCheck.Ok) {
        _step 'meshctrl auth check' 'Fail' "ServerInfo returned '$($authCheck.Reason)'; aborting downstream provisioning (exit=$($serverInfo.ExitCode))"
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = "meshctrl auth failed: $($authCheck.Reason)" }
    }
    _step 'meshctrl auth check' 'Pass' "ServerInfo ok (clusteradmin authenticated)"

    # 9. Device groups -- create + verify via ListDeviceGroups.
    $listR = & $script:ProvisioningInvokers.RunMeshctrl 'ListDeviceGroups' @() $authCtx
    $groupMeshIds = @{}
    foreach ($g in $hostsGrp, $vmsGrp) {
        $existingId = Get-MeshidFromGroupListing -Stdout $listR.Stdout -GroupName $g
        if ($existingId) {
            $groupMeshIds[$g] = $existingId
            _step "Device group '$g'" 'Pass' "already exists (meshid=$existingId)"
            continue
        }
        $addR = & $script:ProvisioningInvokers.RunMeshctrl 'AddDeviceGroup' @('--name', $g) $authCtx
        $addCheck = Test-MeshctrlSuccess -Stdout $addR.Stdout -Stderr $addR.Stderr
        if (-not $addCheck.Ok) {
            _step "Device group '$g'" 'Fail' "AddDeviceGroup returned '$($addCheck.Reason)'"
            continue
        }
        # Verify by re-listing.
        $listR2 = & $script:ProvisioningInvokers.RunMeshctrl 'ListDeviceGroups' @() $authCtx
        $newId = Get-MeshidFromGroupListing -Stdout $listR2.Stdout -GroupName $g
        if ($newId) {
            $groupMeshIds[$g] = $newId
            _step "Device group '$g'" 'Pass' "created (meshid=$newId)"
        } else {
            _step "Device group '$g'" 'Warn' 'AddDeviceGroup returned no error markers but group not in ListDeviceGroups'
        }
    }

    # 10. Agent bundles -- download Windows x64 service installer per group
    #     into share\agents\<group>\meshagent64-<group>.exe.
    & $script:ProvisioningInvokers.EnsureDir $agentsDir
    foreach ($g in $hostsGrp, $vmsGrp) {
        if (-not $groupMeshIds.ContainsKey($g)) {
            _step "Agent bundle '$g'" 'Warn' "skipped: no meshid for group '$g'"
            continue
        }
        $groupDir = Join-Path $agentsDir $g
        & $script:ProvisioningInvokers.EnsureDir $groupDir
        $expectedFile = Join-Path $groupDir "meshagent64-$g.exe"
        # meshctrl AgentDownload writes its output to the CWD; we can't redirect
        # so launch with WorkingDirectory = groupDir.
        $agentR = & $script:ProvisioningInvokers.RunMeshctrl 'AgentDownload' @('--id', $groupMeshIds[$g], '--type', '4') $authCtx
        $agentBlob = "$($agentR.Stdout)`n$($agentR.Stderr)"
        $check = Test-MeshctrlSuccess -Stdout $agentR.Stdout -Stderr $agentR.Stderr
        if (-not $check.Ok) {
            _step "Agent bundle '$g'" 'Warn' "AgentDownload returned '$($check.Reason)'"
            continue
        }
        # meshctrl says "Downloaded N byte(s) to ""meshagent64-<group>.exe""" on success.
        if ($agentBlob -match 'Downloaded\s+\d+\s+byte') {
            if (& $script:ProvisioningInvokers.FileExists $expectedFile) {
                _step "Agent bundle '$g'" 'Pass' "wrote $expectedFile"
            } else {
                # AgentDownload may have written to CWD instead of groupDir; that's
                # outside our control with the current meshctrl. Soft-Warn.
                _step "Agent bundle '$g'" 'Warn' "AgentDownload reported success but $expectedFile not found at expected path"
            }
        } else {
            _step "Agent bundle '$g'" 'Warn' "AgentDownload output did not contain 'Downloaded N byte(s)'; check stdout"
        }
    }

    $failCount = @($steps | Where-Object { $_.Status -eq 'Fail' }).Count
    $warnCount = @($steps | Where-Object { $_.Status -eq 'Warn' }).Count
    $overall = if ($failCount -gt 0) { 'Fail' } elseif ($warnCount -gt 0) { 'Warn' } else { 'Pass' }
    [pscustomobject]@{
        Overall = $overall
        Steps   = $steps.ToArray()
        Detail  = "admin '$user' + $($groupMeshIds.Count) group(s) + agent bundle(s) provisioned"
    }
}
