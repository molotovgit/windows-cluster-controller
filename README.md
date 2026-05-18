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
- Network reachability to every host PC (LAN, same broadcast domain ideally for mDNS-style discovery)

## Status

🚧 In active development. 52-PR roadmap; see `docs/ARCHITECTURE.md` for the target stage list.

## Repo layout

```
├── src/
│   ├── lib/         # Reusable PowerShell modules (logging, state, retry, …)
│   ├── stages/      # The 25 setup stages, each a self-contained .ps1
│   └── Invoke-ClusterControllerSetup.ps1   # Top-level orchestrator
├── config/
│   └── cluster-controller.example.json
├── scripts/         # Operator helpers (backup, restore, update, uninstall)
├── tests/
│   ├── unit/        # Pester unit tests with mocked external cmdlets
│   ├── integration/ # End-to-end dry-run with all I/O mocked
│   └── fixtures/    # Mock data for tests
├── docs/
│   ├── ARCHITECTURE.md
│   ├── TROUBLESHOOTING.md
│   ├── REVIEW_PROCESS.md
│   └── RUNBOOK.md
├── REVIEW_PROMPT.md # Reviewer brief used by the peer-review subagent
└── install.ps1      # One-liner bootstrap (built in PR 41)
```

Every change is reviewed by an independent Claude subagent against `REVIEW_PROMPT.md` before merge — see [docs/REVIEW_PROCESS.md](docs/REVIEW_PROCESS.md).

## Cost

**$0 in new hardware.** Uses your existing PC and WiFi. The entire software stack is free.

## License

TBD
