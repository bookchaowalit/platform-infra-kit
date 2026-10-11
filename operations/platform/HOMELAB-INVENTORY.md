---
title: Homelab inventory
status: evidence
tags: [evidence, operations]
updated: 2026-08-30
---

# Homelab inventory

**Checked:** 2026-08-20
**Method:** read-only SSH inventory plus private-LAN gateway HTTP probe
**Boundary:** private LAN only; no credentials, tokens, private keys, or
public addresses are stored here.

## Observed hardware

| Host | Operating system | CPU | RAM | Local disk | Current state |
|---|---|---:|---:|---:|---|
| `beelink` (`192.168.152.10`) | Proxmox VE 9.1.1 / kernel 6.17.2 | Intel N150, 4 vCPU | 15 GiB | 931.5 GB NVMe | Proxmox member; VM 114 running with `onboot=1` |
| `proxmox-laptop-asus-vivobooks14` (`192.168.152.11`) | Proxmox VE 9.1.1 / kernel 6.17.2 | AMD Ryzen 5 7535HS, 12 vCPU | 14 GiB | 476.9 GB NVMe | Proxmox cluster member; no VM/LXC |
| `bookchaowalit-MS-7D98` (`192.168.152.150`) | Ubuntu 26.04 LTS / kernel 7.0.0-29-generic | Intel Core i5-14400F, 16 logical CPU | 61 GiB | 931.5 GB NVMe | Standalone Ubuntu workstation; replacement for removed third Proxmox host |
| Fedora workstation (`192.168.152.12`) | Fedora Linux 43 | AMD Ryzen 7 4700U, 8 vCPU | 15 GiB | 476.9 GB NVMe | Designated private container registry host (not a K3s node) |

The original homelab had three Proxmox hosts. One Proxmox host was removed from
the cluster and is now the standalone Ubuntu workstation
`bookchaowalit-MS-7D98`. Fedora remains a separate registry workstation, so the
current hardware inventory has four machines.

The two Proxmox hosts have active local storage and unused LVM-thin capacity.
The Fedora workstation has a WireGuard interface and several stopped Docker
bridge networks; these should be reviewed before assigning it a cluster role.

## Network preflight

| Host | Observed network design | Impact |
|---|---|---|
| `beelink` | `vmbr0` bridges directly to the private LAN and receives a LAN address | Suitable for LAN-reachable VM networking after VM-level firewall rules are defined |
| `proxmox-laptop-asus-vivobooks14` | `vmbr0` is an isolated `10.10.10.0/24` NAT network over Wi-Fi | Not directly equivalent to the first host; cross-host K3s traffic needs an explicit routed/VPN design |
| `bookchaowalit-MS-7D98` | Ubuntu workstation on Wi-Fi at `192.168.152.150`; Docker and VPN interfaces present | Operator/development workstation only; not a Proxmox or K3s node |
| Fedora workstation | Private LAN interface plus `wg0` and stopped Docker bridge networks | Review routing/firewall before joining a cluster |

The second Proxmox host currently has DNAT rules for existing web, DNS, and
management-related services. No bridge, route, firewall, or port-forwarding
change was made during this inventory.

## Observed network gateway/router

| Device | Address | Observed identity | Evidence |
|---|---|---|---|
| Private-LAN gateway/router | `192.168.152.1` | ZTE; reported product string `F6107A` | HTTP and HTTPS admin pages reachable; LAN neighbor MAC `d8:9a:0d:bb:0d:22` |

The router model should still be confirmed from its physical label or an
authenticated admin page. No router credentials or configuration were copied
into the repository.

## Firewall audit and staged mitigation (2026-08-20)

The audit was performed from the Ubuntu workstation and through read-only SSH
checks. A staged guest-level mitigation was applied only to K3s VM `114` after
the audit. The Proxmox firewall service was enabled to enforce that VM rule,
but Proxmox host policies remain `ACCEPT`; no Ubuntu, Fedora, or router policy
was changed.

| Boundary | Observation | Assessment |
|---|---|---|
| Ubuntu `192.168.152.150` | UFW is active with default input/forward `DROP`, but Docker-published ports were reachable from Fedora on the LAN: `80`, `443`, `3000`, `3001`, `6550`, `8001`, `8080`, `8081`, and `9000` | **High priority:** Docker publishing bypasses the intended UFW boundary for these services; reduce bindings or add an explicit Docker/UFW policy |
| K3s VM `192.168.152.114` | UFW remains inactive, but Proxmox guest firewall is enabled with inbound `DROP`; LAN allowlist is `22`, `80`, `443`, `6443`; `10250`, `32286`, and `32439` are now filtered | **Mitigated for VM 114:** keep host policy review and future cluster-source rules pending |
| Proxmox `192.168.152.10` / `.11` | Proxmox firewall is now `enabled/running` with host policies still `ACCEPT`; VM 114 has its own inbound allowlist; host LAN scan still reaches `22`, `111`, `3128`, and `8006` | **Medium:** host management allowlist and rpcbind/SPICE review remain pending |
| Fedora `192.168.152.12` | `firewalld` active on `FedoraServer` with `ssh`/`cockpit`; Docker zone target is `ACCEPT`; LAN scan reaches registry `5000` and Cockpit `9090` | **Medium:** review Docker zone behavior and restrict sources if required |
| Router `192.168.152.1` | LAN scan showed `53`, `80`, and `443` open; SSH `22` was filtered | **Unverified:** WAN port forwards and admin ACLs still require an authenticated router review |

### Recommended remediation order

1. Preserve the tested VM 114 rollback snapshot and keep Proxmox host policy
   `ACCEPT` until a complete cluster/management allowlist is reviewed.
2. Keep K3s `6443` on the admin LAN only; leave `10250` and NodePorts filtered
   externally unless a specific cluster integration requires them.
3. Bind Ubuntu development/database/metrics ports to `127.0.0.1` where LAN
   access is not required, then retest from Fedora.
4. Inspect Fedora firewalld/Docker interaction with an authorized sudo session
   and restrict registry/Cockpit sources if they are not LAN-wide services.
5. Review router WAN forwarding and disable any Internet exposure for the
   private management and demo ports.

## VM image preflight

Neither Proxmox host currently has a VM cloud image/template ready. Both have
an Ubuntu 24.04 LXC template; `beelink` also has several ISO files. Creating a
K3s VM therefore requires an explicit image choice and a reviewed network
design before downloading an image or creating disks.

## Existing Proxmox cluster

| Item | Observation |
|---|---|
| Cluster name | `homelab` |
| Members | 2 registered and online nodes: `beelink`, `proxmox-laptop-asus-vivobooks14` |
| Corosync | Secure auth enabled; cluster is currently quorate |
| Expected votes | 2 configured; 2 current votes; cluster remains quorate |
| Current VMs | VM `114` (`solo-k3s-server-01`) on `beelink` |
| Current LXC containers | None |
| Ceph | Not selected for this two-node lab |

The former third node `proxmox` (node ID `2`, previously recorded at
`192.168.152.13`) was removed from `/etc/pve/corosync.conf` on 2026-08-20
using `pvecm delnode`. The current Ubuntu replacement workstation is
`192.168.152.150` and is not a Proxmox node.

The cluster is useful for learning Proxmox administration, but it is not a
reliable production HA foundation. Keep the standalone Ubuntu workstation and
Fedora registry workstation outside the Proxmox cluster unless a deliberate
quorum/witness design is chosen. Do not
enable Ceph or place irreplaceable data on this two-node arrangement.

## Applied first node

| Item | State |
|---|---|
| VM | `114` / `solo-k3s-server-01` on `beelink` |
| Guest | Ubuntu 24.04, 2 vCPU, 4 GiB RAM, 40 GiB local-LVM disk |
| Address | Private LAN `192.168.152.114` |
| Runtime | K3s `v1.36.2+k3s1`, containerd |
| Role | Single-node control-plane and worker for the non-production lab |
| VM autostart | Enabled (`onboot=1`) for always-on portfolio runtime |
| Ingress | ingress-nginx LoadBalancer on private IP `192.168.152.114`; ports 80/443 |
| System pods | CoreDNS, local-path-provisioner, and metrics-server Running/Ready |
| Data | No customer data; synthetic/demo workloads only |
| IaC | Not yet managed by the repository's OpenTofu; manually bootstrapped |

The VM was created after image checksum verification and is configured with
`onboot=0` so it does not silently become an always-on production service.
The VM's kubeconfig and credentials remain on the guest; none were copied into
the repository.

Platform controllers are now installed on this node: ingress-nginx,
cert-manager, Argo CD, Kyverno Audit, External Secrets Operator, and the K3s
metrics-server. The synthetic `platform-smoke` workload is healthy through
private ingress and is owned by Argo CD Application `platform-smoke-homelab`
(Git path `infra/platform/gitops/homelab/platform-smoke` on `main`, durable
`git@github.com:bookchaowalit/solo-empire.git` with a cluster-local read-only
deploy key).

Private registry target (separate from K3s):

| Item | Value |
|---|---|
| Host | Fedora `192.168.152.12` |
| Hostname | `registry.homelab.local` |
| Role | TLS + htpasswd Docker Distribution registry |
| Reason not on K3s | Avoid single-node failure taking registry + workloads together |
| Bootstrap scripts | `infra/platform/bootstrap/homelab/` |
| Credentials | Host-local only under `/etc/solo-empire-registry/` (never Git) |

## NetBox inventory projection

**Deployed:** 2026-08-30 on the private K3s node `192.168.152.114`.

| Item | State |
|---|---|
| URL | `http://netbox.homelab.local` (private LAN only) |
| Namespace | `apps-netbox-homelab` |
| Managed assets | 5 devices, 1 K3s VM, and management IP addresses from this document |
| Storage | PostgreSQL 17 + Valkey 9.1 with local-path PVCs; non-production/single-node |
| Source boundary | This evidence document remains the reviewable source for the initial seed; NetBox is the operational inventory view |
| Secret boundary | Runtime and admin secrets are generated/applied out-of-band; no credentials are stored here or in Git |
| Reconciliation | `infra/platform/bootstrap/homelab/bootstrap-netbox.sh` is idempotent and re-seeds after reviewed inventory changes |

`ai-doc-assistant` Homelab GitOps is live
(`infra/platform/helm/solo-app/homelab/ai-doc-assistant.yaml` + Application
`ai-doc-assistant-homelab`) with a published immutable `git-<sha>` image.
`booknbook` is also live as a demo fixture. Neither app is a claim of product
completion or durable SaaS readiness.

## Multi-node readiness (audit only)

As of 2026-08-02 the Homelab K3s cluster remains **single-node**. No extra
worker has joined. Multi-node work is limited to a **read-only readiness
audit**:

| Item | State |
|---|---|
| Live K3s nodes | **1** (`solo-k3s-server-01` / `192.168.152.114`) |
| Registry | Fedora `192.168.152.12` — **not** a K3s node |
| Future workers | Proxmox capacity candidates only (VM not created/joined) |
| Audit script | `infra/platform/bootstrap/homelab/audit-multinode-readiness.sh` |
| Design doc | [HOMELAB-MULTINODE-READINESS.md](HOMELAB-MULTINODE-READINESS.md) |
| Cloud | None |
| HA claim | **None** |

### SSH readiness (public-key BatchMode)

**Re-checked:** 2026-08-02 (evening). Still no Proxmox public-key auth.

| Host | SSH key auth | Notes |
|---|---|---|
| `192.168.152.114` (K3s) | PASS (`soloadmin`) | Live control-plane; still **1 node** |
| `192.168.152.12` (Fedora registry) | PASS (`bookchaowalit`) | Registry-only |
| `192.168.152.10` (Proxmox candidate) | **BLOCKED** | TCP 22 open; no authorized operator key; inventory SKIP |
| `192.168.152.11` (Proxmox candidate) | **BLOCKED** | TCP 22 open; no authorized operator key; inventory SKIP |

### Live password-auth inventory check

On 2026-08-20, read-only password-auth SSH checks succeeded for both Proxmox
hosts and the Fedora host. The passwords were used only for this check and are
not stored here. Public-key BatchMode status above was not changed.

| Host | Live observation |
|---|---|
| `192.168.152.10` (`beelink`) | `vmbr0` on `192.168.152.0/24`; VM `114` is **running** with `onboot=1`; no LXC |
| `192.168.152.11` (`proxmox-laptop-asus-vivobooks14`) | Wi-Fi `192.168.152.11/24`; `vmbr0` is `10.10.10.1/24`; no VM/LXC |
| `192.168.152.150` (`bookchaowalit-MS-7D98`) | Ubuntu 26.04 LTS operator/development workstation; not a Proxmox or K3s node |
| `192.168.152.12` (Fedora) | Fedora Linux 43; registry container is running; default gateway is `192.168.152.1` |

The live Proxmox cluster check reports **2 configured nodes / 2 online nodes**:
`beelink` and `proxmox-laptop-asus-vivobooks14`. The former `proxmox` member is
no longer registered, and the cluster is currently quorate with 2 votes.

The always-on K3s verification completed on 2026-08-20: node
`solo-k3s-server-01` is `Ready`, K3s is active, and the private health/smoke
probes for `ai-doc-assistant`, `booknbook`, and `platform-smoke` returned HTTP
200.

**Worker decision (current):** keep **single-node K3s (option A)** as the
portfolio baseline. Proxmox SSH and live capacity inventory remain future
prerequisites if multi-node capacity is later wanted. Join remains unapproved.

Operator primary public key fingerprint (for `authorized_keys` on Proxmox):

`SHA256:szdYtvStArG3iYgNPSY1mOVJyh86c0RdWNO+ndY4m1o` (`bookchaowalit@gmail.com`, ED25519).

Exact install commands: [HOMELAB-MULTINODE-READINESS.md](HOMELAB-MULTINODE-READINESS.md)
§ SSH readiness. No private keys, passwords, or tokens are stored in this repo.
Deep Proxmox inventory (bridges, `pvecm`, VM list) waits until key auth works.
Worker VMs must be Ubuntu; workers add capacity only (not K3s HA).

## Future allocation proposal (not selected)

This is a proposal, not an applied change:

| Host | Proposed role | Reason |
|---|---|---|
| `beelink` | Low-power K3s server VM and platform control services | Suitable for an always-on lightweight control-plane role |
| `proxmox-laptop-asus-vivobooks14` | K3s **worker VM** (not hypervisor as agent), CI runner, demo capacity | Highest CPU capacity for builds and demo workloads |
| `bookchaowalit-MS-7D98` | Standalone Ubuntu operator/development workstation | Former third Proxmox host; keep outside Proxmox and K3s until explicitly redesigned |
| Fedora workstation | **Private registry only** (do not join K3s unless explicitly approved) | Separate failure domain for images |

Initial cluster should be labelled **non-production** and use synthetic data.
Keep PostgreSQL, MinIO, vector stores, and registries disposable or backed up
to a separate target. Do not expose Kubernetes API, registry, Grafana, or
database ports to the Internet.

## Future worker/change prerequisites

- [ ] Rotate the passwords that were shared during setup.
- [ ] Create non-root operator accounts and use SSH keys.
- [ ] Record power, sleep, and reboot behavior for all four machines.
- [ ] Define management, cluster, workload, and VPN network ranges.
- [x] Remove the former third `proxmox` member after confirming it is no
      longer an active Proxmox host; cluster now has two configured votes.
- [x] Define an encrypted off-host backup destination: Fedora
      `192.168.152.12:~bookchaowalit/solo-empire-backups/` (or the path set by
      `SOLO_EMPIRE_OFFHOST_DIR`).
- [x] Perform the local SQLite backup and restore test (6/6 passed on 2026-08-20).
- [x] Define backup rotation, retention, and an automated transfer schedule:
      daily `backup_db` cron at `00:00`, with 7 daily / 4 weekly / 12 monthly
      encrypted copies retained on Fedora.
- [ ] Confirm firewall rules: SSH from admin LAN only; Kubernetes API and
      internal services remain private.
- [ ] Reserve VM CPU/RAM/disk budgets before creating any future worker VM.
- [ ] Document how to tear down the lab without deleting host data.

The encrypted off-host backup workflow was automated on 2026-08-20. The daily
`backup_db` job used `offhost_backup.py` (retired 2026-10-11 with the local SQLite DB), SSH key auth with
`BatchMode`, and the existing cron runner. Fedora receives ciphertext only
(`.db.gz.gpg`, mode `600`); the local GPG private key is not copied. The
automated run produced `solo-empire_20260820_213829.db.gz.gpg`; its checksum
matched locally, and a decrypt/gzip/SQLite recovery test passed (`141` tables).

## Current decision and next safe action

The first single-node lab VM and the platform baseline are complete. **Option A
is selected:** keep the second Proxmox host, Ubuntu workstation, and Fedora
registry workstation outside K3s, and do not
add workloads or workers now. The only future action for multi-node is to
authorize SSH on Proxmox and repeat the read-only inventory; that does not
authorize VM creation or K3s joining.

The current safe action is to preserve the single-node portfolio baseline;
there is no requirement to complete the Proxmox inventory or add workers.

After the network choice and Ubuntu cloud-image source are approved, create
only disposable VMs with explicit CPU/RAM/disk limits. The Fedora machine
should remain a standalone registry host, and the Ubuntu machine should remain
an operator/development workstation, until their firewall and VPN routing are
reviewed.

See [Homelab Plan](HOMELAB-PLAN.md) and
[Portfolio Execution Plan](../evidence/PORTFOLIO-EXECUTION-PLAN.md).
For the operational bootstrap details, see
[HOMELAB-K3S-RUNBOOK.md](HOMELAB-K3S-RUNBOOK.md).
