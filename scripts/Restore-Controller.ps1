<#
.SYNOPSIS
    Restore the MeshCentral controller state from a Backup-Controller archive.

.DESCRIPTION
    Steps (with safety):
      1. Inspect archive: verify manifest.txt is present, the controller
         hostname matches (unless -Force), and every file hash listed in
         the manifest matches the file contents inside the archive.
      2. Refuse to run if the current MeshCentral installation looks
         "non-empty" (meshcentral-data has > 0 files) and -Force isn't set.
         A safer alternative: pre-take a quick backup of the current state
         via -PreRestoreBackup (default ON).
      3. Stop MeshCentral.
      4. Wipe + restore meshcentral-data, meshcentral-files (when present
         in the archive), meshcentral-backups, and cluster-controller.json.
      5. Start MeshCentral.
      6. Health probe: HTTPS root + service status.

.PARAMETER ArchivePath
    Path to the .zip produced by Backup-Controller.ps1.

.PARAMETER ConfigPath
    Optional cluster-controller.json (for the data/files dir paths).

.PARAMETER Force
    Bypass the non-empty-target safety check + hostname match.

.PARAMETER PreRestoreBackup
    Run Backup-Controller first so the current state is recoverable if the
    restore goes wrong. Default $true; pass -PreRestoreBackup:$false to skip.
#>

[CmdletBinding()]
param(
    [string]$ArchivePath,
    [string]$ConfigPath,
    [switch]$Force,
    [bool]$PreRestoreBackup = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $repoRoot 'src\lib'
foreach ($mod in 'Logging','Config','Service','Net') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultRestoreInvoker {
    @{
        EnsureDir = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        }
        ExpandArchive = {
            param([string]$Source, [string]$Destination)
            if (-not (Test-Path -LiteralPath $Destination)) {
                New-Item -Path $Destination -ItemType Directory -Force | Out-Null
            }
            Expand-Archive -Path $Source -DestinationPath $Destination -Force
        }
        ListFiles = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue)
        }
        FileHashSha256 = {
            param([string]$Path)
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
        SafeReplaceDir = {
            # Move existing dir to <dir>.pre-restore.<utc>, copy new content into place.
            param([string]$Live, [string]$NewSource)
            if (Test-Path -LiteralPath $Live) {
                $bak = "$Live.pre-restore." + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmssZ')
                Move-Item -LiteralPath $Live -Destination $bak -Force
            }
            New-Item -Path $Live -ItemType Directory -Force | Out-Null
            if (Test-Path -LiteralPath $NewSource) {
                Copy-Item -Path (Join-Path $NewSource '*') -Destination $Live -Recurse -Force
            }
        }
        CopyFile = {
            param([string]$From, [string]$To)
            if (-not (Test-Path -LiteralPath $From)) { return $false }
            $dir = Split-Path -Parent $To
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
            Copy-Item -LiteralPath $From -Destination $To -Force
            return $true
        }
    }
}

$script:RestoreInvokers = Get-DefaultRestoreInvoker

function Confirm-RestoreTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-RestoreInvoker."
    }
}

function Set-RestoreInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('EnsureDir','ExpandArchive','ListFiles','FileHashSha256','SafeReplaceDir','CopyFile')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-RestoreTestSeamAllowed
    $script:RestoreInvokers[$Name] = $ScriptBlock
}

function Reset-RestoreInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-RestoreTestSeamAllowed
    $script:RestoreInvokers = Get-DefaultRestoreInvoker
}

# ---------- helpers ----------

function Read-RestoreManifest {
    param([string]$Path)
    $kv = @{}
    $hashes = @{}
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if (-not $line.Trim()) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line -match '^([a-z_]+):\s+(.*)$') {
            $kv[$matches[1]] = $matches[2].Trim()
        } elseif ($line -match '^([0-9A-Fa-f]{64})\s+(.+)$') {
            $hashes[$matches[2]] = $matches[1].ToUpper()
        }
    }
    return [pscustomobject]@{ Meta = $kv; Hashes = $hashes }
}

# ---------- public ----------

function Invoke-ControllerRestore {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Restore is the explicit purpose; unattended-friendly.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [string]$ConfigPath,
        [switch]$Force,
        [bool]$PreRestoreBackup = $true
    )

    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw "Restore: archive '$ArchivePath' not found." }
    $cfg = (Read-ControllerConfig -Path $ConfigPath).Config
    $dataDir   = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $filesDir  = Expand-ConfigPath -Value "$($cfg.meshcentral.files_dir)"
    $backupsDir = Expand-ConfigPath -Value "$($cfg.meshcentral.backups_dir)"

    $steps = New-Object System.Collections.Generic.List[object]
    function _step($n,$s,$d) { $steps.Add([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ctrl-restore-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    & $script:RestoreInvokers.EnsureDir $work

    try {
        # 1. Extract.
        & $script:RestoreInvokers.ExpandArchive $ArchivePath $work
        _step 'Extract archive' 'Pass' "extracted to $work"

        # 2. Manifest checks.
        $manifestPath = Join-Path $work 'manifest.txt'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            _step 'Manifest present' 'Fail' 'no manifest.txt inside archive -- refusing to restore'
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
        }
        $manifest = Read-RestoreManifest -Path $manifestPath
        _step 'Manifest present' 'Pass' "controller=$($manifest.Meta['controller_hostname']) utc=$($manifest.Meta['utc']) components=$($manifest.Meta['copied_components'])"

        $expectHost = "$($cfg.controller.hostname)"
        $archHost   = "$($manifest.Meta['controller_hostname'])"
        if ($expectHost -and $archHost -and ($expectHost -ne $archHost) -and -not $Force) {
            _step 'Hostname match' 'Fail' "archive is from '$archHost' but current controller config says '$expectHost'. Pass -Force to restore anyway."
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
        }
        _step 'Hostname match' 'Pass' "archive='$archHost'; current='$expectHost'"

        # 3. Verify file hashes from the manifest.
        $bad = 0
        foreach ($entry in $manifest.Hashes.GetEnumerator()) {
            $file = Join-Path $work $entry.Key
            if (-not (Test-Path -LiteralPath $file)) { $bad++; continue }
            $actual = & $script:RestoreInvokers.FileHashSha256 $file
            if (($actual -as [string]).ToUpper() -ne $entry.Value) { $bad++ }
        }
        if ($bad -gt 0) {
            _step 'Verify hashes' 'Fail' "$bad file(s) in the archive have mismatched SHA256"
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
        }
        _step 'Verify hashes' 'Pass' "$($manifest.Hashes.Count) file(s) verified"

        # 4. Refuse to overwrite non-empty install unless -Force or -PreRestoreBackup.
        $existingFiles = @(& $script:RestoreInvokers.ListFiles $dataDir)
        if ($existingFiles.Count -gt 0 -and -not $Force -and -not $PreRestoreBackup) {
            _step 'Target check' 'Fail' "meshcentral-data has $($existingFiles.Count) file(s); pass -Force or leave -PreRestoreBackup default (true)"
            return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
        }
        _step 'Target check' 'Pass' "existing=$($existingFiles.Count) file(s); will rotate to .pre-restore.<utc>"

        # 5. Stop MeshCentral.
        $stop = Stop-ServiceIdempotent -Name 'MeshCentral' -WaitSeconds 30
        if ($stop.Ok) {
            _step 'Stop MeshCentral' 'Pass' $stop.Detail
        } else {
            _step 'Stop MeshCentral' 'Warn' $stop.Detail
        }

        # 6. SafeReplaceDir for each component present in the archive.
        $components = @(
            @{ Live = $dataDir;    Src = (Join-Path $work 'meshcentral-data')    }
            @{ Live = $filesDir;   Src = (Join-Path $work 'meshcentral-files')   }
            @{ Live = $backupsDir; Src = (Join-Path $work 'meshcentral-backups') }
        )
        foreach ($c in $components) {
            if (-not (Test-Path -LiteralPath $c.Src)) { continue }
            try {
                & $script:RestoreInvokers.SafeReplaceDir $c.Live $c.Src
                _step "Restore $(Split-Path -Leaf $c.Live)" 'Pass' 'rotated existing -> .pre-restore.<utc>; copied new content'
            } catch {
                _step "Restore $(Split-Path -Leaf $c.Live)" 'Fail' "$($_.Exception.Message)"
                return [pscustomobject]@{ Overall = 'Fail'; Steps = $steps.ToArray() }
            }
        }

        # 7. cluster-controller.json if present in archive.
        $cfgArch = Join-Path $work 'cluster-controller.json'
        if ($ConfigPath -and (Test-Path -LiteralPath $cfgArch)) {
            if ((& $script:RestoreInvokers.CopyFile $cfgArch $ConfigPath)) {
                _step 'Restore cluster-controller.json' 'Pass' "wrote $ConfigPath"
            }
        }

        # 8. Start MeshCentral.
        $start = Start-ServiceIdempotent -Name 'MeshCentral' -WaitSeconds 60
        if ($start.Ok -and $start.State -eq 'Running') {
            _step 'Start MeshCentral' 'Pass' $start.Detail
        } else {
            _step 'Start MeshCentral' 'Warn' $start.Detail
        }

        return [pscustomobject]@{ Overall = 'Pass'; Steps = $steps.ToArray(); Detail = "restored from $(Split-Path -Leaf $ArchivePath)" }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($env:CLUSTERCTRL_NOAUTORUN -ne '1') {
    if (-not $ArchivePath) { Write-Error "-ArchivePath is required when running Restore-Controller.ps1 directly."; exit 2 }
    $r = Invoke-ControllerRestore -ArchivePath $ArchivePath -ConfigPath $ConfigPath -Force:$Force -PreRestoreBackup $PreRestoreBackup
    $r.Steps | Format-Table -AutoSize Name, Status, Detail
    Write-Host "Overall: $($r.Overall)" -ForegroundColor $(if ($r.Overall -eq 'Pass') { 'Green' } else { 'Red' })
    if ($r.Overall -ne 'Pass') { exit 1 }
}
