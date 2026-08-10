---
title: "Infrastructure as Code (OpenTofu)"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-08-08
description: "Documentation for Infrastructure as Code (OpenTofu)."
---

# Infrastructure as Code (OpenTofu)

Single-region **staging** implementation for Solo Empire.  
**Provider path:** Hetzner Cloud + **k3s** (`fsn1`) per [PROVIDER-DECISION.md](../../../operations/platform/PROVIDER-DECISION.md).  
**Production:** disabled. **Multi-cloud:** not implemented.  
**Default:** `provision = false` — modules validate/plan without creating resources.

## Layout

```text
infra/platform/iac/
├── README.md
├── docs/STATE-BACKEND.md            # encrypted remote state design
├── scripts/
│   ├── plan-staging.sh              # provision=false plan (local backend OK)
│   ├── preflight-staging.sh
│   ├── pre-apply-audit.sh
│   └── apply-staging.sh             # gated provision=true plan/apply wrapper
├── modules/                         # network, k3s, registry, …
└── envs/
    ├── bootstrap/fsn1/              # state-bucket policy (separate state key)
    ├── staging/fsn1/                # k3s + apps infra (provision=false default)
    └── production/README.md         # DISABLED
```

## Remote state (required for provision=true)

| Control | Setting |
|---------|---------|
| Backend | S3-compatible (Hetzner Object Storage) |
| Encryption | `encrypt = true` + bucket SSE |
| Locking | `use_lockfile = true` |
| Versioning | bucket versioning on |
| Bootstrap key | `bootstrap/fsn1/terraform.tfstate` |
| Staging key | `staging/fsn1/terraform.tfstate` |
| Local state | OK only for `provision=false` scaffold |

Details: [docs/STATE-BACKEND.md](./docs/STATE-BACKEND.md).  
`backend.hcl` is **gitignored** — copy from `backend.hcl.example`.

## Safety

| Rule | Enforcement |
|------|-------------|
| No apply without approval | `apply-staging.sh` gates + confirmation |
| Encrypted remote state | preflight rejects missing encrypt/lock when PREFLIGHT_PROVISION=1 |
| No secrets in Git | env tokens; sensitive outputs; sensitive user_data |
| Production off | no production root module |
| Single region | check block requires `region == fsn1` |
| Cost caps | `max_worker_nodes`, budget JSON, required labels |

## Commands

```bash
export PATH="$HOME/.local/bin:$PATH"
bash infra/platform/iac/scripts/preflight-staging.sh
bash infra/platform/iac/scripts/pre-apply-audit.sh
bash infra/platform/iac/scripts/plan-staging.sh          # provision=false only

# provision=true plan (remote backend; still no apply until apply-staging.sh apply):
# cp envs/staging/fsn1/backend.hcl.example envs/staging/fsn1/backend.hcl
# PREFLIGHT_PROVISION=1 ALLOW_SSH_CIDRS=… SSH_KEY_IDS=… HCLOUD_TOKEN=… \
#   bash infra/platform/iac/scripts/apply-staging.sh plan
```

Registry TLS: `modules/registry/README.md`.  
Runbook: [STAGING-INFRA-RUNBOOK.md](../../../operations/platform/STAGING-INFRA-RUNBOOK.md).

## Sensitive data

Marked `sensitive` / redacted in plans:

- `hcloud_token`, `k3s_token`, `registry_password`, postgres bootstrap password  
- TLS private keys (state only; not root outputs)  
- cloud-init `user_data` via `sensitive(templatefile(...))`  

Root outputs intentionally **omit** passwords and tokens (`output.argocd` is non-secret facts only).

## Explicit non-goals

- Choosing a second cloud or region in this tree  
- Creating real resources from CI  
- Embedding production credentials  
- Putting PostgreSQL inside the `solo-app` Helm chart  
