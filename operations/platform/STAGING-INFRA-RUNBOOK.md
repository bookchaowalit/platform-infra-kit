---
title: Staging infrastructure runbook (single-region)
status: durable
tags: [durable, operations, runbook]
updated: 2026-08-04
---

# Staging infrastructure runbook (single-region)

**Provider path:** VPS + k3s on **Hetzner Cloud**, region **`fsn1` only**.
**Status:** IaC implemented; **provisioning disabled by default**.
**Multi-cloud:** not in scope.

Related:

- [PROVIDER-DECISION.md](PROVIDER-DECISION.md)
- [PLATFORM-STATUS.md](PLATFORM-STATUS.md)
- [PRODUCTION-GAPS.md](PRODUCTION-GAPS.md)
- [ENVIRONMENT-CONTRACT.md](../../infra/platform/ENVIRONMENT-CONTRACT.md)
- IaC root: `infra/platform/iac/envs/staging/fsn1/`

---

## What this creates (when approved)

| Module | Purpose |
|--------|---------|
| `network` | Private network, subnet, node firewall |
| `k3s-cluster` | Control plane VM + k3s server cloud-init |
| `node-pools` | General (and optional system) workers with node caps |
| `registry` | Private container registry VM + volume |
| `dns` | Planned records (apply blocked until real domain) |
| `secrets` | External Secrets path map + example ClusterSecretStore |
| `object-storage` | Plan-only S3-compatible buckets for assets/backups/logs; not provisioned |
| `database` | Private Postgres host + **PITR/WAL archive plan** |
| `monitoring` | ServiceMonitor / scrape hooks for Argo CD |
| `cost` | Labels, monthly EUR budget, resource limits |

Production root `envs/production/` is intentionally empty/disabled.

MinIO remains available in the Docker learning lab only. It is not installed
inside the staging k3s cluster; staging object storage must be approved and
provisioned as a separate S3-compatible data-plane service.

---

## Safety rules

1. `provision = false` in `terraform.tfvars.example` and code defaults.
2. **Do not** `tofu apply` without written owner approval.
3. No real secrets in Git, tfvars committed files, or Helm values.
4. App chart still does **not** create PostgreSQL/Redis.
5. Helm staging values stay `soloEmpire.deploymentEnabled: false` until cluster + secrets + restore drill exist.
6. `allow_ssh_cidrs` must list real admin CIDRs when provisioning (no `0.0.0.0/0`).
7. Registry and Postgres use **private IPs only**; see [PRE-APPLY-AUDIT.md](../evidence/PRE-APPLY-AUDIT.md).
8. Registry is **HTTPS + htpasswd** with internal CA; nodes install CA via `registries.yaml`
   (`modules/registry/README.md`). Port 5000 is never public.
9. Backups/PITR: [STAGING-DATA-BACKUP-RESTORE.md](../runbooks/STAGING-DATA-BACKUP-RESTORE.md).
10. Preflight before any apply: `bash infra/platform/iac/scripts/preflight-staging.sh`.
11. **Remote encrypted state** required for `provision=true` — see
    [STATE-BACKEND.md](../../infra/platform/iac/docs/STATE-BACKEND.md).
    Local `terraform.tfstate` is **forbidden** when provisioning.
12. Sensitive values (tokens, passwords, TLS keys) are `sensitive` and must not
    appear in root outputs; cloud-init is `sensitive(templatefile(...))`.
13. Apply only via `scripts/apply-staging.sh` (not bare `tofu apply`).

---

## Remote state (before provision)

| Item | Value |
|------|--------|
| Bucket | private S3-compatible (Hetzner Object Storage) |
| Encryption | AES-256 + `encrypt = true` |
| Versioning | enabled; noncurrent ≥ 90 days |
| Locking | `use_lockfile = true` |
| Bootstrap state key | `bootstrap/fsn1/terraform.tfstate` |
| Staging state key | `staging/fsn1/terraform.tfstate` |
| Config | `backend.tf` + `backend.hcl` (both gitignored; from `*.example`) |

Bootstrap root: `infra/platform/iac/envs/bootstrap/fsn1/` (policy only; separate state).

---

## Plan-only (safe)

```bash
export PATH="$HOME/.local/bin:$PATH"
bash infra/platform/iac/scripts/preflight-staging.sh
bash infra/platform/iac/scripts/pre-apply-audit.sh
bash infra/platform/iac/scripts/plan-staging.sh   # provision=false, -backend=false OK

# Apply-readiness simulation (still does not apply):
# Requires backend.hcl with encrypt+use_lockfile and no local tfstate
cp -n infra/platform/iac/envs/staging/fsn1/backend.hcl.example \
      infra/platform/iac/envs/staging/fsn1/backend.hcl
PREFLIGHT_PROVISION=1 \
  ALLOW_SSH_CIDRS=203.0.113.10/32 \
  SSH_KEY_IDS=12345678 \
  bash infra/platform/iac/scripts/preflight-staging.sh
```

Expected: local_file / terraform_data for policy hooks; **zero** Hetzner servers when `provision=false`.

### Registry TLS (staging private)

| Item | Value |
|------|--------|
| Endpoint | `https://registry.staging…:5000` → private IP `10.10.1.20` |
| SANs | hostname + `10.10.1.20` |
| Trust | CA on every k3s node (`/etc/rancher/k3s/registry-ca.crt`) |
| Auth | htpasswd user `solo-registry` (password in TF state / secret manager only) |
| Cost | Internal CA **€0**; no public ACME cert required |

---

## Enablement checklist (human approval required)

- [ ] Owner approves monthly budget (policy: **80 EUR**; current re-priced scaffold estimate: **€105.85**, exact provider prices unverified)
- [ ] Pre-apply audit green: [PRE-APPLY-AUDIT.md](../evidence/PRE-APPLY-AUDIT.md)
- [ ] State bucket created (SSE + versioning); bootstrap root recorded
- [ ] `backend.hcl` present (`encrypt=true`, `use_lockfile=true`, staging key)
- [ ] No local `terraform.tfstate` in staging root
- [ ] Hetzner project created; API token in secret manager (not Git)
- [ ] SSH key uploaded; `ssh_key_ids` set
- [ ] `allow_ssh_cidrs` set to operator IPs only
- [ ] Object storage credentials ready (backups/PITR + **state** backend)
- [ ] DNS zone ownership (replace `example.local`) — DNS module stays off until then
- [ ] `PREFLIGHT_PROVISION=1` preflight green
- [ ] `bash apply-staging.sh plan` reviewed (sensitive redacted)
- [ ] `SOLO_EMPIRE_APPLY_CONFIRM=yes` + typed confirmation
- [ ] **Approved** `bash apply-staging.sh apply` only
- [ ] Kubeconfig retrieved; Argo CD cluster registered via `output.argocd`
- [ ] Secrets loaded at ESO paths (see `module.secrets`)
- [ ] Postgres PITR verified (WAL archive to backups bucket)
- [ ] Restore drill documented
- [ ] Only then consider flipping Helm `deploymentEnabled`

---

## Argo CD consumption

After a successful apply, use root output `argocd`:

```text
argocd.cluster.server_url     → cluster API
argocd.cluster.namespaces     → allowed destinations
argocd.registry               → image repository prefix
argocd.secrets                → ClusterSecretStore name + paths
argocd.database.pitr          → backup contract
argocd.monitoring             → ServiceMonitor labels
argocd.cost                   → cost-center labels
```

Suggested Application destinations:

| App | Namespace |
|-----|-----------|
| ai-doc-assistant | `apps-ai-doc-assistant-staging` |
| booknbook | `apps-booknbook-staging` |

Do not enable ApplicationSet staging generators until the cluster secret exists.

---

## Backup / PITR

`module.database` defines:

- Continuous WAL archive to `s3://…/postgres/wal`
- Base backups to `s3://…/postgres/base`
- Default retention: **7 days** (`pitr_retention_days`)
- Full backup cron: `0 3 * * *`
- Restore drill cadence: **30 days**

Tools (operator choice at enablement): pgBackRest or wal-g.
Credentials for object storage come from secret manager, never Git.

---

## Cost controls

- Labels: `solo.empire/environment`, `region`, `cost-center`, `team`, `provider`
- Soft budget: `monthly_budget_eur` (default 80)
- Hard caps: `max_worker_nodes` (default 4), single control plane, volume size limits
- Policy JSON: `modules/cost/generated/staging-budget-policy.json` after plan

---

## Explicit non-goals

- Multi-cloud / multi-region clusters
- Production apply
- Storing kubeconfig or API tokens in the monorepo
- Auto-apply from CI
