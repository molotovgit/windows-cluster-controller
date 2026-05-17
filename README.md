# windows-cluster-controller

Automated setup script for the **controller PC** of a 30-node self-healing Windows cluster.

## What this installs on the controller PC

| Component | Role |
|---|---|
| **Node.js LTS** | Runtime for MeshCentral |
| **MongoDB Community** | Persistent state for MeshCentral (inventory, event log) |
| **MeshCentral** | Orchestration brain — agent registration, HTML5 remote desktop, group script execution, Wake-on-LAN, audit log |
| **PowerShell 7** | Secondary automation channel (heavy / pipeline automation) |
| **OpenSSH client** | For `Invoke-Command -HostName` against the fleet |

After running, you have a working `https://controller.lan` dashboard that all host PCs and VMs can phone home to.

## Architecture context

This repo is **half of a pair**. The companion repo, [`windows-cluster-host`](https://github.com/molotovgit/windows-cluster-host), automates the setup of the 10 host PCs (each with 2 Hyper-V VMs).

| Repo | Runs on | Sets up |
|---|---|---|
| `windows-cluster-controller` (this one) | 1× controller PC | MeshCentral server stack |
| `windows-cluster-host` | 10× host PCs | Hyper-V + 2 VMs per host + MeshAgent |

## Requirements

- Windows 11 Pro on the controller PC
- Administrator rights (for service install)
- Internet connection (to download installers)
- WiFi connection on the same network as the host PCs

## Status

🚧 In active development. Setup scripts coming soon.

## Cost

**$0 in new hardware.** Uses your existing PC and WiFi. The entire software stack is free.

## License

TBD
