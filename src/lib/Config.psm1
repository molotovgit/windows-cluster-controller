<#
.SYNOPSIS
    Configuration helpers for the controller: read cluster-controller.json
    with timestamped backups, merge with defaults, light schema validation,
    and expand %ProgramData% / env-var references inside string fields.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- defaults ----------

function Get-ControllerConfigDefault {
    <#
    .SYNOPSIS Return the canonical default config (matches cluster-controller.example.json).
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        controller = [pscustomobject]@{
            hostname        = 'controller.lan'
            lan_ip          = $null
            https_port      = 443
            agent_port      = 4433
            announcer_port  = 8765
        }
        db = [pscustomobject]@{
            mode = 'nedb'
            mongodb = [pscustomobject]@{
                bind     = '127.0.0.1'
                port     = 27017
                data_dir = '%ProgramData%\ClusterController\mongo\data'
                log_dir  = '%ProgramData%\ClusterController\mongo\log'
            }
        }
        tls = [pscustomobject]@{
            mode = 'self-signed'
            self_signed = [pscustomobject]@{
                cn                = 'controller.lan'
                additional_sans   = @('controller','localhost')
                valid_for_days    = 825
            }
            import = [pscustomobject]@{
                pfx_path             = $null
                pfx_password_envvar  = 'CLUSTERCTRL_TLS_PFX_PASS'
            }
        }
        meshcentral = [pscustomobject]@{
            version_pin = $null
            lan_only    = $true
            wan_only    = $false
            agents_port_same_as_https = $true
            data_dir    = '%ProgramData%\MeshCentral\meshcentral-data'
            files_dir   = '%ProgramData%\MeshCentral\meshcentral-files'
            backups_dir = '%ProgramData%\MeshCentral\meshcentral-backups'
            device_groups = [pscustomobject]@{
                hosts = 'cluster-hosts'
                vms   = 'cluster-vms'
            }
        }
        share = [pscustomobject]@{
            name           = 'ClusterShare'
            root           = '%ProgramData%\ClusterController\share'
            vhdx_subdir    = 'vhdx'
            agents_subdir  = 'agents'
        }
        admin = [pscustomobject]@{
            username        = 'clusteradmin'
            password_envvar = 'CLUSTERCTRL_ADMIN_PASS'
            bootstrap_file  = '%ProgramData%\ClusterController\admin-bootstrap.txt'
        }
        firewall = [pscustomobject]@{
            profiles = @('Domain','Private')
        }
        logging = [pscustomobject]@{
            log_dir          = '%ProgramData%\ClusterController\logs'
            console_level    = 'Info'
            file_level       = 'Debug'
            max_log_size_mb  = 50
            max_log_files    = 10
        }
    }
}

# ---------- public ----------

function Expand-ConfigPath {
    <#
    .SYNOPSIS
        Expand env-vars and %VAR% style references inside a string. Used to
        resolve '%ProgramData%\ClusterController\share' to the real path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if (-not $Value) { return $Value }
    return [System.Environment]::ExpandEnvironmentVariables($Value)
}

function Read-ControllerConfig {
    <#
    .SYNOPSIS
        Read cluster-controller.json. Missing file is NOT an error: returns
        the defaults. Returns @{Ok; Config; Source; Detail}.

    .PARAMETER Path  Optional explicit path. Defaults to the repo's
                     config\cluster-controller.json or the example file.
    #>
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) {
        return [pscustomobject]@{ Ok = $true; Config = (Get-ControllerConfigDefault); Source = 'defaults'; Detail = 'no path provided -- returning defaults' }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Ok = $true; Config = (Get-ControllerConfigDefault); Source = 'defaults'; Detail = "config file '$Path' not found -- returning defaults" }
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Config = (Get-ControllerConfigDefault); Source = 'defaults'; Detail = "cannot parse '$Path' as JSON: $($_.Exception.Message)" }
    }
    $merged = Merge-ControllerConfigWithDefault -User $json
    [pscustomobject]@{ Ok = $true; Config = $merged; Source = $Path; Detail = 'parsed and merged with defaults' }
}

function Merge-ControllerConfigWithDefault {
    <#
    .SYNOPSIS
        Take a user-provided config (potentially partial) and overlay it
        onto Get-ControllerConfigDefault so every field is present downstream.
        Shallow merge per top-level section.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$User)
    $defaults = Get-ControllerConfigDefault
    $result = $defaults
    foreach ($section in 'controller','db','tls','meshcentral','share','admin','firewall','logging') {
        if (-not ($User.PSObject.Properties[$section])) { continue }
        $userSection = $User.$section
        if ($null -eq $userSection) { continue }
        $defSection = $defaults.$section
        # Build a new pscustomobject by overlaying user's properties onto defaults.
        $merged = [ordered]@{}
        foreach ($p in $defSection.PSObject.Properties) {
            $merged[$p.Name] = $p.Value
        }
        foreach ($p in $userSection.PSObject.Properties) {
            $merged[$p.Name] = $p.Value
        }
        $result.$section = [pscustomobject]$merged
    }
    return $result
}

function Test-ControllerConfigValid {
    <#
    .SYNOPSIS
        Light schema check. Returns @{Ok; Errors[]}. Validates only the
        cross-section invariants the orchestrator needs to be safe.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $errors = New-Object System.Collections.Generic.List[string]

    if (-not $Config.controller.hostname) { $errors.Add('controller.hostname is required') }
    if ($Config.controller.https_port -lt 1 -or $Config.controller.https_port -gt 65535) {
        $errors.Add("controller.https_port out of range: $($Config.controller.https_port)")
    }
    if ($Config.db.mode -notin 'nedb','mongodb') { $errors.Add("db.mode must be nedb or mongodb (got '$($Config.db.mode)')") }
    if ($Config.tls.mode -notin 'self-signed','import','letsencrypt') { $errors.Add("tls.mode must be self-signed | import | letsencrypt (got '$($Config.tls.mode)')") }
    if ($Config.tls.mode -eq 'import') {
        if (-not $Config.tls.import.pfx_path) { $errors.Add('tls.mode=import requires tls.import.pfx_path') }
    }
    if (-not $Config.share.name) { $errors.Add('share.name is required') }
    if (-not $Config.admin.username) { $errors.Add('admin.username is required') }
    [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Write-ControllerConfig {
    <#
    .SYNOPSIS
        Write a config object to disk as JSON. If the destination exists,
        copy it to <path>.bak.<timestamp> before overwriting.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Backup-then-overwrite is the documented behaviour; ShouldProcess would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path) {
        $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $bak = "$Path.bak.$stamp"
        Copy-Item -LiteralPath $Path -Destination $bak -Force
    }
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Ok = $true; Path = $Path }
}

Export-ModuleMember -Function `
    Get-ControllerConfigDefault, `
    Expand-ConfigPath, `
    Read-ControllerConfig, `
    Merge-ControllerConfigWithDefault, `
    Test-ControllerConfigValid, `
    Write-ControllerConfig
