---
title: Homelab multi-node readiness (audit only)
status: evidence
tags: [evidence, operations]
updated: 2026-08-20
---

# Homelab multi-node readiness (audit only)

**Status:** Option A selected — single-node operation; readiness audit only; **no node has joined**
**Last updated:** 2026-08-20
**Boundary:** private LAN; non-production portfolio; no cloud resources

**Proxmox membership note:** the former third node `proxmox` (node ID 2) was
removed from the cluster on 2026-08-20. The cluster now contains only
`beelink` and `proxmox-laptop-asus-vivobooks14`, both online and quorate.

Related:

- [HOMELAB-INVENTORY.md](HOMELAB-INVENTORY.md)
- [HOMELAB-K3S-RUNBOOK.md](HOMELAB-K3S-RUNBOOK.md)
- [HOMELAB-PLAN.md](HOMELAB-PLAN.md)
- [PLATFORM-STATUS.md](PLATFORM-STATUS.md)
- Audit script: `infra/platform/bootstrap/homelab/audit-multinode-readiness.sh`

---

## 1. Current topology (live)

```text
                    Private LAN 192.168.152.0/24
                    ┌──────────────────────────┐
  Ubuntu operator workstation
  192.168.152.150
         │ SSH
         ▼
  ┌──────────────────────────┐     HTTPS :5000
  │ K3s single node          │◄──────────────────┐
  │ 192.168.152.114          │                   │
  │ solo-k3s-server-01       │                   │
  │ control-plane + worker   │                   │
  │ Argo, Kyverno, ESO,      │                   │
  │ ingress-nginx, demos     │                   │
  └──────────────────────────┘                   │
                                                 │
  ┌──────────────────────────┐                   │
  │ Fedora workstation       │───────────────────┘
  │ 192.168.152.12           │  private registry only
  │ registry.homelab.local   │  NOT a K3s node
  └──────────────────────────┘

  Proxmox hosts (physical)
  - beelink .............. hosts VM 114 (K3s above)
  - proxmox-laptop-asus... capacity candidate; no K3s worker VM yet
  - former third Proxmox host → Ubuntu workstation .150 (not a Proxmox node)
```

| Host / address | Role today | Joined to K3s? |
|----------------|------------|----------------|
| `192.168.152.114` (`solo-k3s-server-01` on Proxmox `beelink`) | K3s **control-plane and worker** | **Yes (single-node)** |
| `192.168.152.12` (Fedora) | Private **registry only** | **No** (by design) |
| `192.168.152.150` (Ubuntu workstation) | Operator/development workstation; former third Proxmox host | **No** (by design) |
| Proxmox `beelink` hypervisor | Runs K3s VM | Hypervisor is not a K3s node |
| Proxmox second host (e.g. LAN candidates `192.168.152.10` / `.11`) | Future worker **VM** capacity | **No** |

**Claims not made:** multi-node HA, Proxmox HA for workloads, production SLA.

### SSH readiness (operator key audit)

**Last re-check:** 2026-08-02 evening — `BatchMode=yes`,
`-i ~/.ssh/bookchaowalit`, `PreferredAuthentications=publickey` only.
No password attempts. Deep Proxmox inventory **not run** (blocked).

| Target | LAN / TCP 22 | BatchMode public-key SSH | Deep inventory | Join readiness |
|--------|--------------|--------------------------|----------------|----------------|
| K3s `soloadmin@192.168.152.114` | open | **PASS** | PASS | Live single-node (do not re-join) |
| Registry `bookchaowalit@192.168.152.12` | open | **PASS** | PASS | **Registry-only** — do not join K3s |
| Proxmox candidate `192.168.152.10` | open | **FAIL** (`Permission denied (publickey,password)`) | **SKIP** | **BLOCKED** until keys installed |
| Proxmox candidate `192.168.152.11` | open | **FAIL** (`Permission denied (publickey,password)`) | **SKIP** | **BLOCKED** until keys installed |

**Join decision:** **deferred** and blocked on Proxmox SSH.
**Current decision:** **A — keep single-node K3s** for the portfolio. Options B/C
(one/two Ubuntu worker VMs) remain future choices and cannot be sized from live
`qm list` until keys work.

### Current checkpoint

- The single-node K3s platform is sufficient for the current portfolio goal.
- `ai-doc-assistant` and `booknbook` are demo fixtures for the delivery path;
  their business features do not need to be completed here.
- Do not add workloads, join nodes, or change cluster topology as part of this
  readiness document.
- Revisit this audit only if there is a deliberate decision to use the extra
  Proxmox capacity.

Operator public keys present locally (fingerprints only; private keys never leave the workstation):

| Comment | Algorithm | Fingerprint |
|---------|-----------|-------------|
| `bookchaowalit@gmail.com` (primary) | ED25519 | `SHA256:szdYtvStArG3iYgNPSY1mOVJyh86c0RdWNO+ndY4m1o` |
| `chaowalit@nexatech.co.th` | ED25519 | `SHA256:aFP8F5wsxE/LeWIwUibBqb3MLqc1ThirV/lz2PxHEBk` |
| `chaowalit@cocofriday.com` | ED25519 | `SHA256:+rM8tmO/SFRdzYtlCSWz14h2xRgREGva5FPUITbe2n0` |

All three keys were offered with `BatchMode=yes` / `IdentitiesOnly=yes` against
`root`, `bookchaowalit`, and `soloadmin` on `.10` and `.11`. **None** were
accepted. No password authentication was attempted or logged.

### Owner action: authorize the operator public key on Proxmox

Run **once per Proxmox host** while logged in as a privileged user on the
console or an existing session (password over console is fine; do not paste
passwords into chat or Git).

**Preferred key:** `~/.ssh/bookchaowalit.pub`
(`ssh-ed25519 … bookchaowalit@gmail.com`, fingerprint above).

On the **operator workstation**, print the public line only:

```bash
cat ~/.ssh/bookchaowalit.pub
# optional check:
ssh-keygen -lf ~/.ssh/bookchaowalit.pub
```

On **each Proxmox host** (example for root; adjust user if you use a non-root
operator account):

```bash
# As root on the Proxmox host (console / existing admin session):
install -d -m 700 /root/.ssh
# Paste ONLY the single public key line from bookchaowalit.pub:
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOyLn504YVTvziwb/ZWS4M79yYeQdi6Z/LU1Ex+bEnst bookchaowalit@gmail.com' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

Or from the operator workstation **after** you have one working interactive
login (still not automated by the audit):

```bash
# Uses public key only; never ships the private key.
ssh-copy-id -i ~/.ssh/bookchaowalit.pub root@192.168.152.10
ssh-copy-id -i ~/.ssh/bookchaowalit.pub root@192.168.152.11
```

Verify (BatchMode, no password):

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o PreferredAuthentications=publickey \
  -i ~/.ssh/bookchaowalit root@192.168.152.10 'hostname; pveversion'
ssh -o BatchMode=yes -o ConnectTimeout=8 -o PreferredAuthentications=publickey \
  -i ~/.ssh/bookchaowalit root@192.168.152.11 'hostname; pveversion'
```

Then re-run:

```bash
PROXMOX_USERS=root bash infra/platform/bootstrap/homelab/audit-multinode-readiness.sh
```

**Do not** join K3s agents, create VMs, change firewalls, or run `k3sup` as
part of unlocking SSH.

### Worker capacity (design; pending Proxmox SSH inventory)

| Host (from prior inventory) | Can host Ubuntu worker VM? | Notes |
|----------------------------|----------------------------|-------|
| Proxmox `beelink` (LAN; VM 114 = K3s) | Yes, if spare RAM/CPU after VM 114 | Prefer **not** to oversubscribe the control-plane host |
| Proxmox laptop (`proxmox-laptop-asus-vivobooks14`) | **Best capacity** once SSH works | Higher CPU for demo/agent VMs |
| Fedora `192.168.152.12` | N/A for workers | **Registry-only**; keep off the K3s node list |
| Ubuntu `192.168.152.150` | N/A for workers | Operator/development workstation; keep off the K3s node list |

Workers must be **Ubuntu VMs** (match server guest), not the Proxmox host OS
as an agent. Proxmox cluster quorum is independent of K3s quorum; extra workers
add **capacity only**, not control-plane HA.

---

## 2. Proposed future topology

| Component | Address / host | Future role | Notes |
|-----------|----------------|-------------|-------|
| K3s server | `192.168.152.114` | Remain control-plane (optionally also worker) | Keep single server until etcd/HA is intentionally designed |
| Registry | `192.168.152.12` | Stay **registry-only** | Do not join as K3s node unless explicitly approved |
| Worker candidate #1 | New Ubuntu VM on second Proxmox host | K3s **agent** | Prefer VM over bare-metal hypervisor join |
| Worker candidate #2 | Optional second VM (beelink or second Proxmox) | Backup / extra agent | Still non-HA control-plane |

```text
GitHub main → Argo CD (on .114)
               │
               ▼
        K3s server .114
         /          \
   agent VM #1    agent VM #2   (future)
         \          /
      pull images from registry.homelab.local:5000 (.12)
```

---

## 3. Three different “quorums” (do not confuse)

| Concept | What it means here | Status |
|---------|-------------------|--------|
| **Proxmox cluster quorum** | Corosync votes among Proxmox hypervisors | 2-node Proxmox lab is **not** reliable Proxmox HA |
| **K3s cluster quorum** | etcd/control-plane majority for API HA | **Single server** → **no** K3s control-plane HA |
| **Application worker capacity** | Extra nodes to schedule pods | Future agents improve **capacity**, not control-plane HA |

Adding workers **does not** make the control-plane highly available. Losing
`.114` still loses the API until a multi-server K3s design is adopted.

---

## 4. Network requirements

Workers must reach (private LAN only; no public Internet requirement for
cluster fabric):

| Port | Protocol | Purpose |
|------|----------|---------|
| 6443 | TCP | Kubernetes API (agent → server) |
| 10250 | TCP | Kubelet (server → agent, logs/exec) |
| 8472 | UDP | Flannel VXLAN (node ↔ node) |
| 5000 | TCP | Private registry (agent → Fedora) |
| 22 | TCP | Operator SSH (management) |

Also required:

- Shared private L3 reachability between worker VM and `192.168.152.114` / `.12`
- Time sync (NTP/chrony)
- No need for a public interface on workers for cluster traffic

**Known risk:** second Proxmox host historically used isolated/NAT Wi-Fi bridge
in inventory notes — cross-host K3s requires an explicit routed LAN design.

---

## 5. Minimum sizing (future K3s agent VM)

| Resource | Minimum | Recommended for demos |
|----------|---------|------------------------|
| vCPU | 1 | 2+ |
| RAM | 1 GiB (agent only) | 2–4 GiB with demos |
| Disk | 20 GiB SSD | 40 GiB |
| OS | Ubuntu 24.04 (match server) | Same |
| Runtime | containerd (via K3s) | Do not pre-install conflicting Docker K8s stacks |

Hypervisor hosts (`beelink`, laptop Proxmox) need free CPU/RAM **after** existing
VMs (current server is 2 vCPU / 4 GiB).

---

## 6. K3s join prerequisites (when approved later)

Do **not** run these during the audit. Checklist only:

1. SSH key auth to candidate **as non-root operator where possible**  
2. Network path to API 6443, VXLAN 8472, registry 5000  
3. `/etc/rancher/k3s/registries.yaml` trust for `registry.homelab.local`  
4. Host clock synchronized  
5. Documented join token stored **out of band** (never Git)  
6. Node labels: `solo.empire/environment=homelab`, worker role  
7. Decision gate signed off (section 11)

Forbidden in readiness automation:

- `k3s agent` / `k3s server` install  
- `k3sup install`  
- `kubectl apply` for join  
- `tofu apply`  
- Proxmox `qm`/`pct` create/destroy  

---

## 7. Registry placement

| Decision | Rationale |
|----------|-----------|
| Registry on Fedora `.12` | Survives K3s node failure |
| Not on K3s node | Avoids losing image store + workloads together |
| Not public | Homelab private LAN + TLS + htpasswd |
| Workers pull via `registry.homelab.local:5000` | Same trust config as server |

---

## 8. Workload placement (future)

| Workload | Placement guidance |
|----------|-------------------|
| Argo CD, ingress-nginx controller | Prefer control-plane node (or dedicated system pool later) |
| `ai-doc-assistant`, `booknbook` demos | Can schedule on workers when agents exist |
| Stateful durable data | **Still not** on Homelab emptyDir; see durable data plan |
| Registry | Remains on Fedora, not scheduled as a pod requirement for this lab |

---

## 9. Failure scenarios

| Failure | Impact today (single-node) | Impact after workers (still 1 server) |
|---------|----------------------------|----------------------------------------|
| K3s VM `.114` down | Entire cluster down | API still down; pods on workers orphaned until API returns |
| Fedora registry down | No new image pulls | Same; running pods keep local images |
| One worker down | N/A | Only pods on that worker reschedule (if capacity) |
| Proxmox host `beelink` down | K3s VM down | Same unless VM migrated (not free HA) |
| Second Proxmox offline | No effect on current cluster | Loses worker VMs hosted there |

---

## 10. Resource and cost impact

| Item | Cost |
|------|------|
| Cloud | **€0** (private LAN only) |
| Power | +worker VMs increase electricity |
| RAM pressure | Current server ~4 GiB; do not oversubscribe |
| Ops complexity | Higher (networking, registry trust, labels) |
| HA benefit | **None** for API until multi-server K3s |

---

## 11. Decision gate before joining nodes

Join a worker **only** when all are true:

- [ ] Audit script re-run: current node Ready; Argo Synced/Healthy  
- [ ] Candidate SSH + inventory PASS (not SKIP on keys)  
- [ ] Candidate can reach `.114:6443` and `.12:5000`  
- [ ] Worker is a **dedicated Ubuntu VM**, not the Proxmox host OS  
- [ ] Registry stays on Fedora unless a written exception exists  
- [ ] No claim of “HA Homelab” is published  
- [ ] Rollback steps understood (section 12)  
- [ ] Operator has free capacity to support the extra node  

---

## 12. Rollback / removal procedure (future, not run now)

1. Cordon and drain worker: `kubectl drain <node> --ignore-daemonsets`  
2. Delete node object: `kubectl delete node <node>`  
3. On worker VM: stop/disable `k3s-agent`, remove `/etc/rancher/k3s` if retiring  
4. Confirm `kubectl get nodes` is single-node again  
5. Re-run platform + observability verify scripts  

Never force-remove the control-plane node as a “worker cleanup.”

---

## 13. How to run the audit

```bash
bash infra/platform/bootstrap/homelab/audit-multinode-readiness.sh

# Overrides
PROXMOX_HOSTS=192.168.152.10,192.168.152.11 \
  K3S_HOST=192.168.152.114 FEDORA_HOST=192.168.152.12 \
  bash infra/platform/bootstrap/homelab/audit-multinode-readiness.sh
```

Offline validator:

```bash
python3 infra/platform/homelab/validate-multinode-readiness.py
```

---

## 14. Explicit non-claims

- Multi-node is **not live**  
- No new node has been joined by this documentation or audit script  
- No cloud resources are involved  
- Registry is separate from K3s  
- Homelab remains **single-node** until a deliberate join  
- No HA, no production SLA  
