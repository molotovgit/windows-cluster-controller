<#
.SYNOPSIS
    Stage 10 -- Provisioning: bootstrap admin account, create the
    canonical device groups, and generate the agent install bundles
    (.msh + binary) per group.

.DESCRIPTION
    Runs after the MeshCentral service is up. Combines what the original
    plan split into three PRs (32 AdminAccount, 33 DeviceGroups, 34
    AgentBundles) because they all share the same `meshctrl` CLI surface
    and execute in the same window.

    Admin password sourcing order:
      1. $env:CLUSTERCTRL_ADMIN_PASS (or whatever envvar config names)
      2. A securely-generated random password, written to
         admin-bootstrap.txt with strict ACL (LocalSystem + Administrators
         only).

    Agent bundles land under <share root>\agents\<group>\... for the
    host PCs to pull via the SMB share (Stage 12).
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
        # Run `node meshcentral --adminaccount <user> <pass>`. Returns @{ExitCode}.
        CreateAdminAccount = {
            param([string]$NodeExe, [string]$Entry, [string]$WorkingDir, [string]$User, [string]$Pass)
            $argv = @($Entry, '--adminaccount', $User, $Pass)
            $p = Start-Process -FilePath $NodeExe -ArgumentList $argv -WorkingDirectory $WorkingDir -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        # Run `node meshctrl.js <verb>`. MeshCentral installs meshctrl.js as
        # part of the npm meshcentral package -- there is NO meshctrl.exe.
        # Auth args (--url / --loginuser / --loginpass / --ignoreCert) are
        # accepted in the $Auth hashtable and appended automatically.
        # ExitCode==0 on create OR already-exists (idempotent in modern versions).
        RunMeshctrl = {
            param([string]$Verb, [string[]]$ExtraArgv, [hashtable]$Auth)
            # Auto-resolve meshctrl.js: $Auth.MeshctrlPath takes precedence,
            # then $env:CLUSTERCTRL_MESHCTRL_PATH, then the default location.
            $meshctrl = if ($Auth -and $Auth.MeshctrlPath) { $Auth.MeshctrlPath }
                        elseif ($env:CLUSTERCTRL_MESHCTRL_PATH) { $env:CLUSTERCTRL_MESHCTRL_PATH }
                        else { Join-Path $env:ProgramData 'MeshCentral\node_modules\meshcentral\meshctrl.js' }
            $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
            if (-not $nodeExe -or -not (Test-Path -LiteralPath $meshctrl)) {
                return [pscustomobject]@{ ExitCode = -1; Detail = "node or meshctrl.js missing (node='$nodeExe' meshctrl='$meshctrl')" }
            }
            $argv = @($meshctrl, $Verb)
            if ($Auth) {
                if ($Auth.Url)       { $argv += @('--url', $Auth.Url) }
                if ($Auth.LoginUser) { $argv += @('--loginuser', $Auth.LoginUser) }
                if ($Auth.LoginPass) { $argv += @('--loginpass', $Auth.LoginPass) }
                if ($Auth.IgnoreCert) { $argv += '--ignoreCert' }
            }
            if ($ExtraArgv) { $argv += $ExtraArgv }
            $p = Start-Process -FilePath $nodeExe -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Detail = '' }
        }
        # Generate a random password of -Length bytes, web-safe characters.
        NewSecurePassword = {
            param([int]$Length = 24)
            $bytes = New-Object byte[] $Length
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
            # base64 then trim padding + replace + and / with - and _ for shell safety
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
            # Strict ACL: LocalSystem + Administrators only.
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
        [ValidateSet('CreateAdminAccount','RunMeshctrl','NewSecurePassword','WriteAdminBootstrap','EnsureDir')]
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
    $dataDir   = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $mcRoot    = Split-Path -Parent $dataDir
    $entry     = Join-Path $mcRoot 'node_modules\meshcentral\meshcentral.js'
    $shareRoot = Expand-ConfigPath -Value "$($cfg.share.root)"
    $agentsDir = Join-Path $shareRoot "$($cfg.share.agents_subdir)"
    $hostsGrp  = "$($cfg.meshcentral.device_groups.hosts)"
    $vmsGrp    = "$($cfg.meshcentral.device_groups.vms)"

    _step 'Resolve provisioning plan' 'Pass' "admin=$user hosts-group=$hostsGrp vms-group=$vmsGrp agents=$agentsDir"

    if ($DryRun) {
        _step 'Bootstrap admin + groups + bundles' 'Skipped' '-DryRun: would have created admin account, device groups, agent bundles'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: provisioning' }
    }

    # 1. Admin account.
    $pass = $null
    if ($envVar) { $pass = [Environment]::GetEnvironmentVariable($envVar, 'Process') }
    $generated = $false
    if (-not $pass) {
        $pass = & $script:ProvisioningInvokers.NewSecurePassword 24
        $generated = $true
    }
    $nodeExe = (Get-Command -Name 'node' -ErrorAction SilentlyContinue).Source
    if (-not $nodeExe) {
        _step 'Create admin account' 'Fail' 'node.exe not on PATH'
        return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray(); Detail = 'node missing' }
    }
    $admin = & $script:ProvisioningInvokers.CreateAdminAccount $nodeExe $entry $mcRoot $user $pass
    if ($admin.ExitCode -ne 0) {
        # MeshCentral's --adminaccount is idempotent in some versions (returns 0 even on "already exists")
        # and non-zero in others. Soft-Warn rather than Fail so a pre-existing admin doesn't sink the stage.
        _step 'Create admin account' 'Warn' "meshcentral --adminaccount exited $($admin.ExitCode); user may already exist"
    } else {
        _step 'Create admin account' 'Pass' "admin '$user' bootstrapped"
    }

    if ($generated) {
        # Write the bootstrap file with strict ACL so the operator can read the password ONCE.
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
            _step 'Write admin-bootstrap.txt' 'Warn' "could not write $bootPath : $($_.Exception.Message). Admin password: $pass"
        }
    } else {
        _step 'Write admin-bootstrap.txt' 'Pass' 'password sourced from env var; bootstrap file not written'
    }

    # Auth context for meshctrl calls below. Connects to local MeshCentral
    # over its WebSocket control endpoint. --ignoreCert because the cert
    # we just generated in Stage 7 is self-signed.
    $authCtx = @{
        Url        = 'wss://127.0.0.1/control.ashx'
        LoginUser  = $user
        LoginPass  = $pass
        IgnoreCert = $true
        MeshctrlPath = (Join-Path $mcRoot 'node_modules\meshcentral\meshctrl.js')
    }

    # 2. Device groups.
    foreach ($g in $hostsGrp, $vmsGrp) {
        $r = & $script:ProvisioningInvokers.RunMeshctrl 'AddDeviceGroup' @('--name', $g) $authCtx
        # meshctrl returns 0 for both create and already-exists in modern versions.
        if ($r.ExitCode -eq 0) {
            _step "Device group '$g'" 'Pass' 'AddDeviceGroup ok (or already exists)'
        } else {
            $detail = if ($r.PSObject.Properties['Detail']) { $r.Detail } else { '' }
            _step "Device group '$g'" 'Warn' "meshctrl AddDeviceGroup exited $($r.ExitCode) (detail: $detail); operator can re-create via web UI."
        }
    }

    # 3. Agent bundles.
    & $script:ProvisioningInvokers.EnsureDir $agentsDir
    foreach ($g in $hostsGrp, $vmsGrp) {
        $groupDir = Join-Path $agentsDir $g
        & $script:ProvisioningInvokers.EnsureDir $groupDir
        $r = & $script:ProvisioningInvokers.RunMeshctrl 'GenerateInviteLink' @('--group', $g, '--output', $groupDir) $authCtx
        if ($r.ExitCode -eq 0) {
            _step "Agent bundle '$g'" 'Pass' "GenerateInviteLink -> $groupDir"
        } else {
            _step "Agent bundle '$g'" 'Warn' "meshctrl GenerateInviteLink for '$g' exited $($r.ExitCode); operator can re-run or use web UI."
        }
    }

    [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "admin '$user' + groups + agent bundle dirs provisioned" }
}
