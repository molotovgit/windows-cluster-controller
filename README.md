# windows-cluster-controller

Automated setup script for the **controller PC** of a 30-node self-healing Windows cluster.

## What this installs on the controller PC

| Component | Role |
|---|---|
| **Node.js LTS** | Runtime for MeshCentral |
| **MongoDB Community** (optional) | Persistent state for MeshCentral; built-in NeDB is the default for small deployments |
| **MeshCentral** | Orchestration brain — agent registration, HTML5 remote desktop, group script execution, Wake-on-LAN, audit log |
| **PowerShell 7** | Secondary automation channel (heavy / pipeline automation) |
| **OpenSSH client** | For `Invoke-Command -HostName` against the fleet |
| **Cluster Announcer** | Tiny service so host PCs can auto-discover this controller |
| **SMB share** | Distributes the golden VHDX + agent .msh bundles to host PCs |

After running, you have a working `https://controller.lan` dashboard that all host PCs and VMs can phone home to.

## Architecture context

This repo is **half of a pair**. The companion repo, [`windows-cluster-host`](https://github.com/molotovgit/windows-cluster-host), automates the setup of the 10 host PCs (each with 2 Hyper-V VMs).

| Repo | Runs on | Sets up |
|---|---|---|
| `windows-cluster-controller` (this one) | 1× controller PC | MeshCentral server stack + share + announcer |
| `windows-cluster-host` | 10× host PCs | Hyper-V + 2 VMs per host + MeshAgent |

## Requirements

- Windows 11 Pro / Enterprise / Education on the controller PC (Home is NOT supported)
- Administrator rights (service install, firewall, SMB share)
- ≥ 8 GB RAM, ≥ 50 GB free on the system drive
- Network reachability to every host PC (LAN, same broadcast domain ideally)

## Status

✅ All 13 stages implemented and unit + integration tested. End-to-end orchestrator
dry-run passes **Overall=Pass** on a fully-stubbed Win11 Pro sandbox — the PRIMARY
GOAL acceptance test is green.

**One-liner install** (run as Administrator under **pwsh 7**):

```powershell
iwr -useb https://raw.githubusercontent.com/molotovgit/windows-cluster-controller/main/install.ps1 -OutFile install.ps1
.\install.ps1 -FromGitHub -ControllerHostname controller.lan -WriteConfig
```

`-FromGitHub` makes `install.ps1` fetch the rest of the repo from the
GitHub archive zip when no other source is given (`-ZipUrl`,
`$env:CLUSTERCTRL_REPO_ZIP`, or a local checkout).

**Local checkout install** (run as Administrator):

```powershell
git clone https://github.com/molotovgit/windows-cluster-controller
cd windows-cluster-controller
.\install.ps1 -ControllerHostname controller.lan -WriteConfig
```

For a no-mutation preview:

```powershell
.\install.ps1 -ControllerHostname controller.lan -DryRun -NoRestart
```

⚠️ **Caveat (same as the host repo):** all testing here is **mocked**. The 13 stages
have never been run against real `msiexec`, real `New-SelfSignedCertificate`, real
`Get-NetFirewallRule`, real `New-SmbShare`, real `npm install`, or a real
MeshCentral. The script is logically green against stubs; real-hardware validation
is a separate step.

## Repo layout

```
├── src/
│   ├── lib/        # Reusable modules: Logging, State, Retry, HardwareDetect,
│   │               #   Net, Pkg, Service, Firewall, Tls, Smb, Config, Announce
│   ├── stages/     # The 13 setup stages, each a self-contained .ps1
│   └── Invoke-ClusterControllerSetup.ps1   # Top-level orchestrator
├── config/
│   └── cluster-controller.example.json
├── scripts/        # Operator helpers (Backup, Restore, Update, Uninstall — TBD)
├── tests/
│   ├── unit/       # 200+ Pester unit tests with mocked external surfaces
│   ├── integration/# E2E dry-run + orchestrator wiring tests
│   └── Invoke-Sandbox.ps1   # lint + unit + integration + manifests
├── docs/
└── install.ps1
```

## Stage flow

1. **Preflight** — admin, SKU, RAM, disk, network, scheduler service, exec policy, port 443 free
2. **PowerShell 7** — winget primary → MSI fallback
3. **OpenSSH client** — WindowsCapability primary → DISM fallback
4. **Node.js** — SHA256-verified MSI install
5. **DB** — NeDB skip (default) or MongoDB install + loopback bind
6. **MeshCentral** — npm install + config.json with TLS thumbprint placeholder
7. **TLS** — self-signed (default) / import PFX / Let's Encrypt stub
8. **Firewall** — idempotent rules: HTTPS, agent, announcer, MongoDB loopback
9. **MeshCentral service** — node `--install` primary → NSSM fallback → start + HTTPS probe
10. **Provisioning** — admin account (env-var password or generated) + device groups + agent bundles
11. **Share** — golden-VHDX drop dir + SMB ClusterShare export
12. **Announcer** — HttpListener-based discovery responder, NSSM-registered
13. **Verify** — health checks + operator setup-summary.txt

## Cost

**$0 in new hardware.** Uses your existing PC and WiFi. The entire software stack is free.

## License

TBD
