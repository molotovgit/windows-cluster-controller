# Architecture — windows-cluster-controller

> This document describes the **target architecture** of the controller stack. Implementation is in progress; see `README.md` Status for what's actually built.

## What the controller is

The controller is the one PC in the cluster that runs the orchestration brain. Every host PC and every VM (10 hosts × 3 = 30 nodes total) phones home to it via MeshAgent over HTTPS. From the controller, an operator can:

- See every node green/red
- Run scripts against any group (HTML5 remote desktop, PowerShell pipeline)
- Wake hosts via Wake-on-LAN
- Read the audit log

## Software stack

```
   ┌──────────────────────────────────────────────────────────────┐
   │ Controller PC (Win11 Pro)                                     │
   │                                                                │
   │  ┌────────────────┐   ┌──────────────────────────────────┐   │
   │  │ Announcer svc  │   │ MeshCentral service (Node.js)    │   │
   │  │ TCP 8765       │   │ TCP 443 (HTTPS, agent + UI)      │   │
   │  │ /.well-known/  │   │                                   │   │
   │  │ cluster-       │   │  ├── meshcentral-data/            │   │
   │  │ controller     │   │  │     config.json, certs, db    │   │
   │  └────────────────┘   │  ├── meshcentral-files/           │   │
   │                       │  └── node_modules/                 │   │
   │                       └──────────────────────────────────┘   │
   │                                  │                             │
   │                                  ▼                             │
   │            ┌──────────────────────────────────┐               │
   │            │ MongoDB service (optional)         │               │
   │            │ bind 127.0.0.1:27017 only          │               │
   │            └──────────────────────────────────┘               │
   │                                                                │
   │  ┌────────────────────────────────────────────────────────┐   │
   │  │ SMB share "ClusterShare" (read-only, authenticated)    │   │
   │  │   share\agents\hosts\*.msh                              │   │
   │  │   share\agents\vms\*.msh                                │   │
   │  │   share\vhdx\golden.vhdx  (operator-supplied)           │   │
   │  └────────────────────────────────────────────────────────┘   │
   └──────────────────────────────────────────────────────────────┘
```

## Stage flow

The 25-stage setup runs once on a fresh Win11 Pro. Stages are idempotent and the entire run is reboot-resilient via the State module + scheduled task.

| # | Stage | What it does |
|---|---|---|
| 1 | Preflight | admin, SKU, RAM ≥ 8 GB, disk ≥ 50 GB free, network up |
| 2 | PowerShell7 | install PS 7 LTS (winget → MSI fallback) |
| 3 | OpenSshClient | install OpenSSH client (capability → DISM fallback) |
| 4 | NodeDownload | download Node.js LTS MSI with SHA256 verification |
| 5 | NodeInstall | install Node.js MSI silently, verify node + npm |
| 6 | DbDecision | choose MongoDB vs built-in NeDB based on config |
| 7 | MongoInstall | install MongoDB Community (skipped if NeDB) |
| 8 | MongoConfigure | bind 127.0.0.1, dbPath under ProgramData, start service |
| 9 | MeshcentralDir | create %ProgramData%\MeshCentral with strict ACLs |
| 10 | MeshcentralNpmInstall | npm install meshcentral (with retry + offline-cache aware) |
| 11 | MeshcentralConfig | generate config.json deterministically from cluster-controller.json |
| 12 | TlsSelfSigned | self-signed cert with SAN list (default TLS path) |
| 13 | TlsImport | import operator-supplied .pfx (alternative TLS path) |
| 14 | TlsLetsencryptStub | ACME / Let's Encrypt placeholder (gated, opt-in) |
| 15 | Firewall | TCP 443 (Private+Domain), agent port, 27017 loopback |
| 16 | MeshcentralService | install MeshCentral as Windows service |
| 17 | MeshcentralStart | start service + wait for HTTPS ready |
| 18 | AdminAccount | bootstrap initial admin user with secure password |
| 19 | DeviceGroups | create canonical groups: cluster-hosts, cluster-vms |
| 20 | AgentBundles | generate .msh installer bundles per group |
| 21 | GoldenVhdxDir | create golden-VHDX drop dir (operator places the file) |
| 22 | Smb | create "ClusterShare" SMB share (authenticated, read-only) |
| 23 | Announcer | install controller-announcer service (host discovery) |
| 24 | HealthVerify | all services Running, HTTPS up, share reachable |
| 25 | OperatorSummary | write setup-summary.txt + next-step instructions |

## State machine

The orchestrator records progress in `HKLM:\Software\ClusterController` (or `$env:CLUSTERCTRL_REG_BASE` for tests):

- `Stage` (DWORD) — last stage that began
- `Status` (string) — InProgress | Completed | Failed
- `StartedAt`, `UpdatedAt`, `Version`, `RunId` — diagnostics
- `LastError` — populated on Status=Failed

On a fresh run with prior terminal status (Completed/Failed), the orchestrator regenerates RunId + StartedAt so each run has a fresh identity. On Resume after reboot (Status=InProgress), identity is preserved.

## Trust model

- **MeshCentral ↔ agents:** TLS. The self-signed cert is exported and installed into every host PC's Trusted Root store at host-setup time (via `cluster-host`'s Agents stage).
- **Operator → MeshCentral UI:** TLS. Browser must trust the cert (same self-signed root, or a real CA cert imported via Stage 13).
- **MongoDB:** loopback-only. No auth in single-host LAN-only mode. The DB never accepts connections from outside the controller.
- **SMB share:** authenticated read-only for everyone, full control for Administrators. Hosts authenticate as their own machine accounts (Domain-joined) or as a dedicated cluster-share user (workgroup).

## What's intentionally NOT here

- **No cloud dependencies.** No telemetry, no remote logging, no auto-update from the internet.
- **No PKI server.** Self-signed cert distribution is push-based (host setup imports it). No SCEP, no ADCS.
- **No HA.** Single controller. Backup → restore is the DR story (`scripts\Backup-Controller.ps1`).
- **No external authentication.** No SSO, no LDAP. Local admin only.
