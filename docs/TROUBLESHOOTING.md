# Troubleshooting — windows-cluster-controller

> All paths assume defaults from `cluster-controller.example.json`. Adjust if your config overrides them.

## Where to look first

| Symptom | First thing to check |
|---|---|
| Setup didn't reach the dashboard URL | `%ProgramData%\ClusterController\logs\setup-*.log` — last few lines name the failed stage + remediation |
| Setup said `Pass` but I can't browse the dashboard | `%ProgramData%\ClusterController\setup-summary.txt` for the resolved URL; then the troubleshoot rows below |
| Service-related weirdness | `services.msc` (or `Get-Service MeshCentral, ClusterAnnouncer, MongoDB`) — all three must be `Running` |
| Recent change broke things | `%ProgramData%\ClusterController\backups\*.zip` is the most recent automatic backup — restore with `scripts\Restore-Controller.ps1` |

## "MeshCentral service won't start"

1. **Check the service log** at `%ProgramData%\MeshCentral\meshcentral-data\mesherrors.log`. Common causes:
   - TLS cert thumbprint mismatch → re-run stage 7 (Tls): `pwsh -File src\Invoke-ClusterControllerSetup.ps1 -StartFromStage 7`
   - Port 443 in use by another listener → `Get-NetTCPConnection -LocalPort 443` to identify; relocate or stop it
   - Node version mismatch → `node -v`; if absent, re-run stage 4: `pwsh -File src\Invoke-ClusterControllerSetup.ps1 -StartFromStage 4`

2. **MeshCentral built-in service installer failed** → orchestrator falls back to NSSM-wrapped node. Check `Get-Service MeshCentral` exists. If not, manually:
   ```powershell
   cd %ProgramData%\MeshCentral
   node node_modules\meshcentral\meshcentral.js --install
   ```

## "Port 443 was already in use" at Stage 1

Some other service on the controller is bound to TCP 443 — typically IIS, an old MeshCentral install, or a development web server.

```powershell
Get-NetTCPConnection -LocalPort 443 | Select-Object OwningProcess
Get-Process -Id <pid>
```

Stop the conflicting service (`Stop-Service`, or via Services.msc), then re-run `install.ps1`. If you'd rather move MeshCentral to a different port, edit `cluster-controller.json` (`controller.https_port`) and re-run from Stage 6.

## "npm install meshcentral takes forever / fails"

- Network: the controller needs HTTPS reach to `registry.npmjs.org`. Try `iwr -useb https://registry.npmjs.org/meshcentral`.
- Corporate proxy: set `$env:HTTP_PROXY` and `$env:HTTPS_PROXY` BEFORE running `install.ps1`, or `npm config set proxy` once.
- Disk full: stage 10 caches files under `%ProgramData%\MeshCentral`. Need ≥ 50 GB free on the system drive (preflight checks this).

## "Self-signed cert -- browser shows scary warning"

Expected. The controller's cert IS installed into `LocalMachine\Root` ON THE CONTROLLER, so a browser on the controller itself should trust it. From other machines, either:

- **Distribute the cert** to host PCs (the `windows-cluster-host` Agents stage does this automatically when it pulls the agent bundle).
- **Buy / import a real cert**: switch `tls.mode` to `import`, set `tls.import.pfx_path` and `$env:CLUSTERCTRL_TLS_PFX_PASS`, re-run from Stage 7.

## "Host PCs can't find the controller"

The host's `Discovery` module probes:

1. `config.controller.address` from the host's own config (if set)
2. DNS resolution of `controller.lan`
3. mDNS-style `_meshcentral._tcp` (deferred)
4. The Announcer endpoint at `http://<candidate>:8765/.well-known/cluster-controller`

Verify the Announcer service:

```powershell
Get-Service ClusterAnnouncer            # must be Running
Invoke-WebRequest http://127.0.0.1:8765/.well-known/cluster-controller
# Expected: JSON with type=cluster-controller, hostname, lan_ip, https_port
```

If the announcer is Running locally but hosts can't reach 8765 on the LAN, check the firewall rule:

```powershell
Get-NetFirewallRule -DisplayName 'ClusterController: Announcer'
```

## "I need to start completely over"

```powershell
.\scripts\Uninstall-Controller.ps1 -Yes -PurgeData
# Reboot recommended.
.\install.ps1 -ControllerHostname controller.lan -WriteConfig
```

`-PurgeData` also wipes `%ProgramData%\ClusterController` and `%ProgramData%\MeshCentral`. **Take a backup first** (`scripts\Backup-Controller.ps1`) if there's anything in MeshCentral you can't lose.

## "I made a config change and want to apply just the affected stages"

```powershell
pwsh -File src\Invoke-ClusterControllerSetup.ps1 -StartFromStage 7   # e.g. re-do TLS + Firewall + MeshCentral service + onwards
```

`-StartFromStage` only re-runs stages ≥ the number; earlier ones are marked Skipped in the result.

## "An update broke MeshCentral"

The `scripts\Update-MeshCentral.ps1` auto-rollback path means a failed health check after `npm install` restores the previous version from the auto-backup. If you bypassed it with `-NoRollback` or `-NoBackup`:

```powershell
.\scripts\Restore-Controller.ps1 -ArchivePath <path-to-pre-update.zip> -Force
```

The pre-update archive is at `%ProgramData%\ClusterController\backups\controller-<hostname>-<utc>.zip`.

## Stuck? Read the log first.

`%ProgramData%\ClusterController\logs\setup-*.log` has every step + timing + remediation hint. The reboot-continuity pointer means one setup run = one log file (not one log file per reboot). Most issues are diagnosable from the log alone.
