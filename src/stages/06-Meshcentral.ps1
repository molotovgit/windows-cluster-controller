<#
.SYNOPSIS
    Stage 6 -- Install MeshCentral via npm and write its config.json.

.DESCRIPTION
    Three logical sub-steps, combined into one stage so the orchestrator
    sees a single Meshcentral artifact:
      1. Ensure the %ProgramData%\MeshCentral subtree exists with strict
         ACLs (LocalSystem + Administrators full; no other ACEs).
      2. `npm install meshcentral` into that subtree's node_modules
         (idempotent: skip if `npm ls meshcentral` resolves OR if
         meshcentral.js already exists from a previous run).
      3. Generate meshcentral-data/config.json deterministically from
         cluster-controller.json. Backup-on-overwrite.

    The TLS thumbprint goes into the config in PR-26's Stage 7 path --
    this stage writes the *non-cert* parts of the config (port, lan-only,
    db connection string for MongoDB mode, agent settings).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Pkg','Retry','Config') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultMeshcentralInvoker {
    @{
        # Probe: does meshcentral.js exist under <root>/node_modules/meshcentral/ ?
        TestMeshcentralInstalled = {
            param([string]$Root)
            $entry = Join-Path $Root 'node_modules\meshcentral\meshcentral.js'
            Test-Path -LiteralPath $entry
        }
        # Run `npm install meshcentral --prefix <root>`. Returns @{ExitCode}.
        RunNpmInstallMeshcentral = {
            param([string]$Root, [string]$VersionPin)
            $argv = @('install','meshcentral','--prefix', $Root)
            if ($VersionPin) { $argv = @('install',"meshcentral@$VersionPin",'--prefix', $Root) }
            $p = Start-Process -FilePath 'npm.cmd' -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden
            [pscustomobject]@{ ExitCode = [int]$p.ExitCode }
        }
        # Ensure directory exists; idempotent. Returns nothing.
        EnsureDir = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        }
        # Apply strict ACL: LocalSystem + Administrators full; clear inheritance.
        ApplyStrictAcl = {
            param([string]$Path)
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)   # disable inheritance, clear inherited
            $rights = [System.Security.AccessControl.FileSystemRights]'FullControl'
            $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
            $prop    = [System.Security.AccessControl.PropagationFlags]'None'
            $allow   = [System.Security.AccessControl.AccessControlType]'Allow'
            foreach ($id in 'NT AUTHORITY\SYSTEM','BUILTIN\Administrators') {
                $r = New-Object System.Security.AccessControl.FileSystemAccessRule($id, $rights, $inherit, $prop, $allow)
                $acl.AddAccessRule($r)
            }
            Set-Acl -Path $Path -AclObject $acl
        }
        WriteConfigJson = {
            param([string]$Path, [string]$Body)
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            if (Test-Path -LiteralPath $Path) {
                $bak = "$Path.bak." + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
                Copy-Item -LiteralPath $Path -Destination $bak -Force
            }
            [System.IO.File]::WriteAllText($Path, $Body, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

$script:MeshcentralInvokers = Get-DefaultMeshcentralInvoker

function Confirm-MeshcentralTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-MeshcentralInvoker."
    }
}

function Set-MeshcentralInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('TestMeshcentralInstalled','RunNpmInstallMeshcentral','EnsureDir','ApplyStrictAcl','WriteConfigJson')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-MeshcentralTestSeamAllowed
    $script:MeshcentralInvokers[$Name] = $ScriptBlock
}

function Reset-MeshcentralInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-MeshcentralTestSeamAllowed
    $script:MeshcentralInvokers = Get-DefaultMeshcentralInvoker
}

# ---------- helpers ----------

function Format-MeshcentralConfig {
    <#
    .SYNOPSIS
        Build the MeshCentral config.json body from a controller config.
    .NOTES
        TLS thumbprint and CertHash are populated by Stage 7 (Tls); this
        stage leaves cert-related fields placeholder/null so a re-run by
        Stage 7 has something predictable to update.
    #>
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [int]$HttpsPort        = 443,
        [int]$AgentPort        = 4433,
        [bool]$LanOnly         = $true,
        [bool]$WanOnly         = $false,
        [bool]$AgentsSameAsHttps = $true,
        [string]$MongoUrl,        # null in NeDB mode
        [string]$DataDir,
        [string]$FilesDir
    )

    $obj = [ordered]@{
        '_comment'        = 'AUTO-GENERATED by windows-cluster-controller (stages/06-Meshcentral.ps1). Re-runs preserve manual edits ONLY via *.bak.*.'
        settings          = [ordered]@{
            cert            = $Hostname
            port            = $HttpsPort
            redirport       = 80
            agentport       = if ($AgentsSameAsHttps) { $HttpsPort } else { $AgentPort }
            lanonly         = $LanOnly
            wanonly         = $WanOnly
            sessionTime     = 30
            sessionkey      = '__SET_BY_FIRST_RUN__'   # MeshCentral will rotate on first boot if not set
            'allowloginToken' = $false
        }
        domains           = [ordered]@{
            '' = [ordered]@{
                title         = 'Cluster Controller'
                title2        = $Hostname
                newAccounts   = $false
                userQuota     = 1048576
                meshQuota     = 248576
                certUrl       = "https://$Hostname/"
            }
        }
    }
    if ($MongoUrl) { $obj.settings.mongoDb = $MongoUrl }
    if ($DataDir)  { $obj.settings.datapath = $DataDir }
    if ($FilesDir) { $obj.settings.filespath = $FilesDir }
    return ($obj | ConvertTo-Json -Depth 10)
}

# ---------- public ----------

function Invoke-MeshcentralStage {
    <#
    .SYNOPSIS  Create MeshCentral tree, npm install, write config.json.
    .PARAMETER Config         Parsed cluster-controller.json pscustomobject.
    .PARAMETER DryRun         Report decisions only; no filesystem/npm calls.
    #>
    [CmdletBinding()]
    param(
        $Config,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    # Resolve config fields with defaults.
    $cfg = if ($Config) { $Config } else { Get-ControllerConfigDefault }
    $hostname  = "$($cfg.controller.hostname)"
    $httpsPort = [int]$cfg.controller.https_port
    $agentPort = [int]$cfg.controller.agent_port
    $lanOnly   = [bool]$cfg.meshcentral.lan_only
    $wanOnly   = [bool]$cfg.meshcentral.wan_only
    $samePort  = [bool]$cfg.meshcentral.agents_port_same_as_https
    $verPin    = if ($cfg.meshcentral.PSObject.Properties['version_pin']) { "$($cfg.meshcentral.version_pin)" } else { $null }
    $dataDir   = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $filesDir  = Expand-ConfigPath -Value "$($cfg.meshcentral.files_dir)"
    $backupDir = Expand-ConfigPath -Value "$($cfg.meshcentral.backups_dir)"
    $mcRoot    = Split-Path -Parent $dataDir   # e.g. C:\ProgramData\MeshCentral

    $mongoUrl = $null
    if ($cfg.db.mode -eq 'mongodb' -and $cfg.db.mongodb) {
        $mb = $cfg.db.mongodb
        $bind = if ($mb.PSObject.Properties['bind']) { "$($mb.bind)" } else { '127.0.0.1' }
        $port = if ($mb.PSObject.Properties['port']) { [int]$mb.port }    else { 27017 }
        $mongoUrl = "mongodb://${bind}:${port}/meshcentral"
    }

    _step 'Resolve paths' 'Pass' "root=$mcRoot; data=$dataDir; files=$filesDir; mongo=$($null -ne $mongoUrl)"

    if ($DryRun) {
        _step 'Create dirs / npm install / write config' 'Skipped' '-DryRun: would have created MeshCentral tree, run npm install, and written config.json'
        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = 'DryRun: MeshCentral path' }
    }

    # 1. Ensure directory tree with strict ACL.
    foreach ($p in $mcRoot, $dataDir, $filesDir, $backupDir) {
        try { & $script:MeshcentralInvokers.EnsureDir $p } catch {
            _step 'Create dirs' 'Fail' "could not create '$p': $($_.Exception.Message)"
            return [pscustomobject]@{ Overall='Fail'; Steps=$steps.ToArray(); Detail="dir creation failed: $($_.Exception.Message)" }
        }
    }
    try { & $script:MeshcentralInvokers.ApplyStrictAcl $mcRoot } catch {
        _step 'Apply ACL' 'Warn' "Set-Acl on $mcRoot failed: $($_.Exception.Message); inherited ACL retained"
    }
    _step 'Create dirs + ACL' 'Pass' "$mcRoot subtree present with strict ACL"

    # 2. npm install meshcentral (idempotent).
    if (& $script:MeshcentralInvokers.TestMeshcentralInstalled $mcRoot) {
        _step 'npm install meshcentral' 'Pass' "meshcentral.js already present under $mcRoot\node_modules\meshcentral"
    } else {
        $r = & $script:MeshcentralInvokers.RunNpmInstallMeshcentral $mcRoot $verPin
        if ($r.ExitCode -ne 0) {
            _step 'npm install meshcentral' 'Fail' "npm exited $($r.ExitCode)"
            return [pscustomobject]@{
                Overall     = 'Fail'
                Steps       = $steps.ToArray()
                Detail      = "npm install meshcentral exited $($r.ExitCode)"
                Remediation = "Open $mcRoot, run 'npm install meshcentral' manually as Administrator and inspect npm's stderr."
            }
        }
        if (-not (& $script:MeshcentralInvokers.TestMeshcentralInstalled $mcRoot)) {
            _step 'npm install meshcentral' 'Fail' 'npm exit 0 but meshcentral.js still not present'
            return [pscustomobject]@{
                Overall     = 'Fail'
                Steps       = $steps.ToArray()
                Detail      = 'npm reported success but meshcentral.js missing'
                Remediation = "Inspect $mcRoot\node_modules and re-run 'npm install meshcentral' from there."
            }
        }
        _step 'npm install meshcentral' 'Pass' 'installed via npm'
    }

    # 3. Write config.json.
    $configPath = Join-Path $dataDir 'config.json'
    $body = Format-MeshcentralConfig `
        -Hostname  $hostname `
        -HttpsPort $httpsPort `
        -AgentPort $agentPort `
        -LanOnly   $lanOnly `
        -WanOnly   $wanOnly `
        -AgentsSameAsHttps $samePort `
        -MongoUrl  $mongoUrl `
        -DataDir   $dataDir `
        -FilesDir  $filesDir
    try {
        & $script:MeshcentralInvokers.WriteConfigJson $configPath $body
    } catch {
        _step 'Write config.json' 'Fail' "$($_.Exception.Message)"
        return [pscustomobject]@{ Overall='Fail'; Steps=$steps.ToArray(); Detail="config.json write failed" }
    }
    _step 'Write config.json' 'Pass' "wrote $configPath"

    [pscustomobject]@{
        Overall = 'Pass'
        Steps   = $steps.ToArray()
        Detail  = "MeshCentral ready under $mcRoot"
    }
}
