---
title: Provider decision: where to run Kubernetes (pre-provisioning)
status: evidence
tags: [evidence, operations]
updated: 2026-08-04
---

# Provider decision: where to run Kubernetes (pre-provisioning)

**Status:** Decision record — **no infrastructure provisioned**.  
**Date:** 2026-08-02  
**Scope:** Choose a path for future `staging` / `production` clusters after local
k3d pilots prove the app platform pattern.

---

## Options compared

| Criterion | A. Managed Kubernetes | B. VPS + k3s | C. Multi-cloud later |
|-----------|----------------------|--------------|----------------------|
| Examples | GKE, EKS, AKS, DOKS, Civo | Hetzner/OVH/Linode VMs + k3s | Abstractions over A/B |
| Control plane ops | Vendor-managed | You (or k3sup/ansible) | Highest complexity |
| Time to first cluster | Hours–days after account | Hours if small | Months of design |
| Cost at small scale | Higher baseline (control plane + LB) | Often lower fixed VM cost | Highest (duplication) |
| Cost at scale | Better with node autoscaling | Ops cost grows | Fragmented spend |
| Managed data adjacency | Easy (RDS, Cloud SQL, etc.) | Self-host or buy managed separately | Must standardize interfaces |
| Compliance / enterprise | Strong vendor certifications | Depends on you | Complex shared responsibility |
| Lock-in | Medium (API + addons) | Low (k3s is portable) | Intentional flexibility tax |
| Fits Solo Empire now | Strong for staging/prod when ready | Strong if budget-first single region | Premature before one cloud works |
| Blast radius | Per-cluster env isolation | Per-VPS / per-cluster | Cross-cloud misconfig risk |
| GitOps fit | Excellent (Argo CD multi-cluster) | Excellent | Excellent if clusters register cleanly |
| Local parity | Medium (k3d ≈ k3s closer to B) | High with k3d → k3s | Low until abstraction freezes |

---

## Detailed notes

### A. Managed Kubernetes

**Pros**

- Control plane HA, upgrades, and etcd handled by the vendor
- Integrates with managed PostgreSQL, object storage, KMS, IAM
- Node pools, autoscaling, and regional topologies are productized
- Better default path for PITR, private networking, and audit logs

**Cons**

- Monthly floor cost even for small pilots
- Provider-specific IAM, CNI, and LB details in IaC
- Overkill if only one region and few apps for a long time

**Best when:** Staging/production need managed data + predictable ops time.

### B. VPS + k3s

**Pros**

- Lowest cash cost for a learning/staging single region
- Closest runtime to current **k3d** pilots (same K3s family)
- Full control over versions, CNI, and bare-metal-adjacent networking
- Easy to destroy and recreate for drills

**Cons**

- You own control plane backup, cert rotation, and upgrade windows
- Managed PostgreSQL/object storage still recommended (do not put DBs on the
  same VPS as apps long-term without a deliberate design)
- TLS, DNS, and load balancing are DIY (Traefik/nginx + cert-manager)
- Single-node “cluster” is not production HA

**Best when:** Budget-constrained staging or a self-hosted edge; still use
managed or separate data services when possible.

### C. Multi-cloud later

**Pros**

- Escape hatch for region/vendor outages and pricing leverage
- Forces clean interfaces (OCI images, External Secrets, portable Helm)

**Cons**

- Doubles networking, IAM, observability, and incident runbooks
- Premature before one environment is boring and reliable
- Conflicts with Solo Empire’s current single-operator capacity

**Best when:** After one provider path is stable and a second region/vendor is a
real requirement (not a theory).

---

## Recommendation (decision, not provisioning)

| Phase | Choice | Rationale |
|-------|--------|-----------|
| Now | **Local k3d only** | Already proven for two pilots; zero cloud cost |
| Next staging | **Prefer B (VPS + k3s)** *or* small **managed K8s** if managed DB is bought first | k3s maximizes parity with k3d; managed K8s if you pay for managed Postgres/vector the same week |
| First production | **A (managed Kubernetes)** in **one region** | HA control plane + managed data + PITR before public users |
| Multi-cloud | **Defer (C)** | Revisit only after production restore drills and cost baselines exist |

**Working decision for Solo Empire (2026-08-02, staging IaC locked):**

1. **Staging provider path: B — VPS + k3s on Hetzner Cloud, region `fsn1` only.**
   OpenTofu lives at `infra/platform/iac/envs/staging/fsn1/` with
   `provision = false` until human apply approval.
2. **Do not provision** until owner approval + runbook checklist complete.
3. **Production remains disabled** (`envs/production/` has no root module).
4. **Multi-cloud is deferred** — no second provider or region in this tree.
5. GitOps/Helm app charts stay portable; only the IaC root is Hetzner-specific.
6. Data plane: private Postgres VM + object-storage WAL/PITR for staging;
   production should still plan **managed Kubernetes + managed Postgres**.

See [STAGING-INFRA-RUNBOOK.md](STAGING-INFRA-RUNBOOK.md).

For the broader portfolio and production cost comparison, see
[PRODUCTION-COST-COMPARISON.md](PRODUCTION-COST-COMPARISON.md).

---

## Non-decisions (explicit)

- No cloud account resources created by this document
- No DNS, registry, or cluster IDs committed
- No requirement to abandon Docker Compose lab (local learning stays Compose)

---

## Exit criteria to revisit this decision

- [ ] Staging values enabled (`deploymentEnabled: true`) with real registry tags
- [ ] First restore drill completed
- [ ] Monthly cost actuals for 30 days
- [ ] On-call ownership documented for the chosen path
