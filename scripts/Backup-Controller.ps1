<#
.SYNOPSIS
    Back up the MeshCentral controller state to a single archive.

.DESCRIPTION
    Copies the following into a timestamped staging dir and then zips it:
      * meshcentral-data\           (DB, certs, config.json, users)
      * meshcentral-files\          (user-uploaded files; can be large)
      * meshcentral-backups\        (MeshCentral's own internal backups dir)
      * config\cluster-controller.json    (when present)
      * %ProgramData%\ClusterController\admin-bootstrap.txt (if it still
        exists -- operator should usually delete after first read)

    Honors -StopService to flush the running MeshCentral cleanly before
    backup; default behaviour leaves the service Running (consistent with
    MongoDB's own --pause-on-backup semantics in NeDB mode).

    Writes a manifest.txt inside the archive with:
      - controller hostname
      - utc timestamp
      - sha256 of every file copied
      - tool versions (node, npm, pwsh)

.PARAMETER OutputDir
    Directory to write the .zip into. Default
    %ProgramData%\ClusterController\backups.

.PARAMETER ConfigPath
    Optional explicit cluster-controller.json path.

.PARAMETER StopService
    Stop MeshCentral before copying, start it again after. Recommended for
    consistent backups when MeshCentral has active sessions.

.PARAMETER IncludeFiles
    Also include meshcentral-files\. Default: included; pass
    -IncludeFiles:$false to skip (much smaller archive).

.PARAMETER Force
    Overwrite an existing same-named archive in OutputDir.

.OUTPUTS
    Path to the created .zip.
#>

[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ConfigPath,
    [switch]$StopService,
    [bool]$IncludeFiles = $true,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $repoRoot 'src\lib'
foreach ($mod in 'Logging','Config','Service') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultBackupInvoker {
    @{
        EnsureDir = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        }
        CopyTree = {
            param([string]$From, [string]$To)
            if (-not (Test-Path -LiteralPath $From)) { return $false }
            Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force -ErrorAction SilentlyContinue
            return $true
        }
        CopyFile = {
            param([string]$From, [string]$To)
            if (-not (Test-Path -LiteralPath $From)) { return $false }
            Copy-Item -LiteralPath $From -Destination $To -Force
            return $true
        }
        Compress = {
            param([string]$Source, [string]$Destination)
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
            Compress-Archive -Path (Join-Path $Source '*') -DestinationPath $Destination -CompressionLevel Optimal -Force
        }
        FileHashSha256 = {
            param([string]$Path)
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
        GetToolVersion = {
            param([string]$Tool)
            $c = Get-Command -Name $Tool -ErrorAction SilentlyContinue
            if (-not $c) { return $null }
            try {
                $v = & $c.Source --version 2>$null
                return ($v -as [string]).Trim()
            } catch { $null = $_; return $null }
        }
    }
}

$script:BackupInvokers = Get-DefaultBackupInvoker

function Confirm-BackupTestSeamAllowed {
    if (-not $env:CLUSTERCTRL_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERCTRL_ALLOW_TEST_SEAMS=1 to enable Set-BackupInvoker."
    }
}

function Set-BackupInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('EnsureDir','CopyTree','CopyFile','Compress','FileHashSha256','GetToolVersion')]
        [string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-BackupTestSeamAllowed
    $script:BackupInvokers[$Name] = $ScriptBlock
}

function Reset-BackupInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-BackupTestSeamAllowed
    $script:BackupInvokers = Get-DefaultBackupInvoker
}

# ---------- public ----------

function Invoke-ControllerBackup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Unattended-friendly backup; ShouldProcess would block automation.')]
    [CmdletBinding()]
    param(
        [string]$OutputDir,
        [string]$ConfigPath,
        [switch]$StopService,
        [bool]$IncludeFiles = $true,
        [switch]$Force
    )

    $cfg = (Read-ControllerConfig -Path $ConfigPath).Config
    $hostname = "$($cfg.controller.hostname)"
    $dataDir  = Expand-ConfigPath -Value "$($cfg.meshcentral.data_dir)"
    $filesDir = Expand-ConfigPath -Value "$($cfg.meshcentral.files_dir)"
    $backupSubdir = Expand-ConfigPath -Value "$($cfg.meshcentral.backups_dir)"

    if (-not $OutputDir) {
        $progData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
        $OutputDir = Join-Path $progData 'ClusterController\backups'
    }
    & $script:BackupInvokers.EnsureDir $OutputDir

    $stamp     = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmssZ')
    $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ctrl-backup-" + $stamp)
    $archive   = Join-Path $OutputDir ("controller-$hostname-$stamp.zip")

    if (Test-Path -LiteralPath $archive) {
        if (-not $Force) {
            throw "Output archive '$archive' already exists. Pass -Force to overwrite or change -OutputDir."
        }
    }

    & $script:BackupInvokers.EnsureDir $stageRoot

    # Optionally stop the service for a consistent snapshot.
    $stopped = $false
    if ($StopService) {
        Write-ClusterLog -Level Info -Stage 'backup' -Message 'Stopping MeshCentral service for consistent backup...'
        $r = Stop-ServiceIdempotent -Name 'MeshCentral' -WaitSeconds 30
        if ($r.Ok) { $stopped = $true }
        else { Write-ClusterLog -Level Warn -Stage 'backup' -Message "Could not stop MeshCentral cleanly: $($r.Detail). Proceeding with hot copy." }
    }

    try {
        $copied = New-Object System.Collections.Generic.List[object]
        # data
        $dataStage = Join-Path $stageRoot 'meshcentral-data'
        & $script:BackupInvokers.EnsureDir $dataStage
        if ((& $script:BackupInvokers.CopyTree $dataDir $dataStage)) { $copied.Add('meshcentral-data') }
        # files (optional)
        if ($IncludeFiles) {
            $filesStage = Join-Path $stageRoot 'meshcentral-files'
            & $script:BackupInvokers.EnsureDir $filesStage
            if ((& $script:BackupInvokers.CopyTree $filesDir $filesStage)) { $copied.Add('meshcentral-files') }
        }
        # internal backups subtree
        $backupsStage = Join-Path $stageRoot 'meshcentral-backups'
        & $script:BackupInvokers.EnsureDir $backupsStage
        if ((& $script:BackupInvokers.CopyTree $backupSubdir $backupsStage)) { $copied.Add('meshcentral-backups') }
        # cluster-controller.json
        if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
            if ((& $script:BackupInvokers.CopyFile $ConfigPath (Join-Path $stageRoot 'cluster-controller.json'))) {
                $copied.Add('cluster-controller.json')
            }
        }
        # admin-bootstrap.txt (if still around)
        $boot = Expand-ConfigPath -Value "$($cfg.admin.bootstrap_file)"
        if ($boot -and (Test-Path -LiteralPath $boot)) {
            if ((& $script:BackupInvokers.CopyFile $boot (Join-Path $stageRoot 'admin-bootstrap.txt'))) {
                $copied.Add('admin-bootstrap.txt')
            }
        }

        # manifest
        $manifestLines = New-Object System.Collections.Generic.List[string]
        $manifestLines.Add("# windows-cluster-controller backup manifest")
        $manifestLines.Add("controller_hostname: $hostname")
        $manifestLines.Add("utc:                 $([datetime]::UtcNow.ToString('o'))")
        $manifestLines.Add("backup_archive:      $(Split-Path -Leaf $archive)")
        $manifestLines.Add("stopped_service:     $stopped")
        $manifestLines.Add("include_files:       $IncludeFiles")
        $manifestLines.Add("copied_components:   $($copied -join ', ')")
        foreach ($tool in 'node','npm','pwsh') {
            $v = & $script:BackupInvokers.GetToolVersion $tool
            $manifestLines.Add(("tool_{0,-4}        {1}" -f $tool, ($v -as [string])))
        }
        $manifestLines.Add('')
        $manifestLines.Add('# SHA256 of every file in the backup:')
        Get-ChildItem -LiteralPath $stageRoot -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($stageRoot.Length).TrimStart('\','/')
            $h   = & $script:BackupInvokers.FileHashSha256 $_.FullName
            $manifestLines.Add(("{0}  {1}" -f $h, $rel))
        }
        Set-Content -LiteralPath (Join-Path $stageRoot 'manifest.txt') -Value $manifestLines -Encoding utf8

        # Compress
        & $script:BackupInvokers.Compress $stageRoot $archive

    } finally {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        if ($stopped) {
            Write-ClusterLog -Level Info -Stage 'backup' -Message 'Restarting MeshCentral service after backup...'
            Start-ServiceIdempotent -Name 'MeshCentral' -WaitSeconds 30 | Out-Null
        }
    }

    Write-ClusterLog -Level Info -Stage 'backup' -Message "Backup archive: $archive"
    return $archive
}

# Run from command line:
if ($env:CLUSTERCTRL_NOAUTORUN -ne '1') {
    $archive = Invoke-ControllerBackup -OutputDir $OutputDir -ConfigPath $ConfigPath `
                                        -StopService:$StopService -IncludeFiles $IncludeFiles -Force:$Force
    Write-Host ""
    Write-Host "Backup written:" -ForegroundColor Cyan
    Write-Host "  $archive"
}
