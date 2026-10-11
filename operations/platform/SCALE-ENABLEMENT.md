---
title: Scale enablement — hard path completion
status: evidence
tags: [platform, scale, kubernetes, postgres, production-gaps]
updated: 2026-08-11
---

# Scale enablement (hard path)

This is the single playbook to take Solo Empire from **lab + offline evidence**
to **approved staging**, then production later. It deliberately separates:

1. **What is already finished offline** (can claim today).
2. **What one human approval + credentials unlocks** (real cloud spend).
3. **What must never be faked** (live UAT, signed prod, on-call).

Related: [PRODUCTION-GAPS.md](PRODUCTION-GAPS.md), [PLATFORM-STATUS.md](PLATFORM-STATUS.md),
[PROVIDER-DECISION.md](PROVIDER-DECISION.md),
`infra/platform/iac/envs/staging/fsn1/`.

## Already finished (2026-08-11)

| Capability | Evidence |
|---|---|
| Local Kubernetes pilots | k3d + homelab K3s; ai-doc-assistant + booknbook Synced/Healthy historically |
| Onboarding / GitOps path | 149 onboarding checks; platform validation **445 passed** |
| Staging OpenTofu modules | network, k3s, registry, database (Postgres VPS + PITR plan), object storage, secrets, DNS, cost |
| Staging plan scaffold | `bash infra/platform/iac/scripts/plan-staging.sh` → plan file **not applied** (`provision=false`) |
| Staging safety defaults | `provision=false`, `deploymentEnabled: false`, SSH CIDR/key checks, remote state required before apply |
| DE 33-dimension evidence | [technology-capability-evidence-data-engineering.md](../../systems/architecture/technology-capability-evidence-data-engineering.md) |
| Platform/Security evidence | [technology-capability-evidence-platform-security.md](../../systems/architecture/technology-capability-evidence-platform-security.md) |
| AI/MLOps local lifecycle | digest model + synthetic Gold + fail-closed promotion |

## Honest remaining hard gates

| Gate | Why it is hard | Exit |
|---|---|---|
| **G1. Written approval** | Cloud spend (current scaffold estimate **€105.85/mo** vs **€80** policy; exact prices unverified) | Written “approve staging provision fsn1” with an approved/re-priced budget |
| **G2. Hetzner credentials** | `HCLOUD_TOKEN` via secret manager only | Token in Infisical/Vault; never Git |
| **G3. Remote state bucket** | Encrypted S3-compatible state + lock | Bootstrap per `infra/platform/iac/docs/STATE-BACKEND.md` |
| **G4. SSH admin CIDRs + keys** | No `0.0.0.0/0` SSH | Real operator keys + home/office CIDRs |
| **G5. Domain decision** | TLS/DNS placeholders today | Approve real domain or keep `*.example.local` internal-only |
| **G6. Restore drill** | PITR contract exists; no live restore | One successful staging DB restore |
| **G7. Flip app deploy** | `soloEmpire.deploymentEnabled: false` | Only after G6 + signed image policy decision |
| **G8. Production root** | Intentionally absent | Separate production env design; not reuse staging recklessly |

## One-path enable sequence (human-approved)

Do **not** run apply until G1–G4 are satisfied.

```bash
# 0) Offline re-verify (safe anytime)
task test:platform
bash infra/platform/iac/scripts/plan-staging.sh

# 1) After approval + secrets available
cp infra/platform/iac/envs/staging/fsn1/backend.tf.example \
   infra/platform/iac/envs/staging/fsn1/backend.tf
cp infra/platform/iac/envs/staging/fsn1/backend.hcl.example \
   infra/platform/iac/envs/staging/fsn1/backend.hcl
# fill backend.hcl endpoints/bucket; never commit secrets

# 2) Preflight + plan with provision=true (still not apply)
bash infra/platform/iac/scripts/preflight-staging.sh
# use apply-staging.sh plan path documented in that script

# 3) Human reviews plan resource list (k3s + postgres + registry + volumes)

# 4) apply-staging.sh apply  (only with explicit approval)

# 5) Restore drill → then consider deploymentEnabled true per app
```

## What “scale finished” means here

| Layer | Finished offline? | Live staging? | Live production? |
|---|---|---|---|
| Control plane (SQLite/CLI/MCP) | Yes | N/A | N/A |
| Data lake contracts/catalog | Yes | Partial (R2 job-data lane) | No cutover claim |
| K8s platform code path | Yes | No until apply | No |
| Managed/private Postgres module | Yes (code) | No until apply | No |
| Book Dev portfolio hygiene | In progress | N/A | N/A |

**Scale is finished as engineering design + offline proof.**  
**Scale is not finished as paid always-on cloud** until G1–G7 clear.

## Explicit non-actions this document forbids

- Setting `provision=true` and apply without written approval.
- Putting Postgres inside the `solo-app` Helm chart.
- Claiming production multi-cloud HA.
- Marking real-device product UAT pass from platform green checks alone.
