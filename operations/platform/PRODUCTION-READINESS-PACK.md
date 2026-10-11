---
title: Production Readiness Pack
aliases: [Production Gate Pack, Promotion Readiness]
tags: [evidence, operations, production, readiness, release]
created: 2026-08-24
updated: 2026-08-24
description: Evidence pack and fail-closed checklist for deciding whether Solo Empire or BookFinance may enter an approved staging or production promotion path.
status: blocked-for-production
owner: "Solo Empire platform owner"
related: [PRODUCTION-GAPS.md, SCALE-ENABLEMENT.md, STAGING-INFRA-RUNBOOK.md, ../../systems/architecture/finance-enterprise-readiness.md]
---

# Production Readiness Pack

> Purpose: provide one auditable promotion boundary for Solo Empire and the
> BookFinance API without confusing local tests, homelab checks, or IaC plans
> with a live production environment.

## Document control

| Field | Value |
|---|---|
| Document ID / version | [OPS-PROD-READINESS / 1.0] |
| Owner | Solo Empire platform owner |
| Accountable approver | [named human approver] |
| Status | blocked-for-production |
| Effective date | 2026-08-24 |
| Next review | [YYYY-MM-DD] |
| Source of truth | This pack plus linked contracts, runbooks, and CI evidence |

## Current decision

**NO-GO for production.** The repository has an enterprise-aware local
foundation and a repeatable offline verification boundary. It does not yet
have a provisioned, approved, monitored, restored, or rollback-tested
production environment.

No cloud resource, cluster, production secret, or deployment is created by
this document.

## Verification floor

Run these checks from the repository root and attach their output to the
release/change record. Commands that need real credentials remain blocked until
the environment owner approves them.

```bash
task test
task typecheck
task test:api
task test:platform
task contracts:check
task docs:check
task preflight:production
```

`preflight:production` validates local configuration shape without printing
credential values. It accepts the preferred `API_TOKENS_JSON` hash-only
registry or the legacy `API_TOKEN`; it does not prove secret-manager
rotation/revocation or gateway protection.

## Latest staging plan evidence

Recorded 2026-08-24 from the repository root:

- `preflight-staging.sh`: 15 passed, 0 failed.
- `pre-apply-audit.sh`: 21 passed, 0 failed after correcting its document
  paths to the canonical `operations/runbooks/`, `operations/evidence/`, and
  `operations/platform/` locations.
- `plan-staging.sh`: OpenTofu initialization, validation, and a
  `provision=false` plan completed successfully; the plan was written to
  `/tmp/solo-staging-fsn1.tfplan` and was not applied.
- The plan reports an estimated staging cost of **€105.85/month** against the
  configured **€80/month** budget. This is a budget gate, not permission to
  spend or a reason to change the budget without approval.
- The same `provision=false` plan with `TF_VAR_general_node_count=1` reports
  **€86.36/month** and still fails the €80 guard. The cost model now scales the
  worker line item with the requested topology; reducing workers alone is not
  sufficient to clear the policy.

### Budget decision scenarios

The following are arithmetic scenarios from the current line items, not
provider quotes or approval to change the IaC profile:

| Scenario | Workers | Optional allowances | Monthly estimate | Interpretation |
|---|---:|---|---:|---|
| Full staging baseline | 2 | LB + object storage + contingency | €105.85 | Over policy; complete staging cost boundary |
| Lean full boundary | 1 | LB + object storage + contingency | €86.36 | Still over policy; backup/edge boundary retained |
| Core-only preview | 1 | Excludes LB and object-storage allowances | €75.96 | Within policy, but not staging-ready: PITR/object backup and public edge remain blocked |

The core-only preview must not be promoted or described as production-ready.
It is useful only if the owner explicitly chooses a temporary private lab
profile and accepts the missing durability and edge controls.

## Promotion gates

| Gate | Current status | Required evidence before approval |
|---|---|---|
| Human approval and budget | `blocked` | Named approver, environment, provider, re-priced or approved monthly budget (€105.85 current scaffold estimate vs €80 policy), and rollback owner |
| Identity and authorization | `partial` | Managed secret/identity lifecycle, scoped finance permissions, rotation and revocation test |
| Data durability | `blocked` | Managed Postgres/vector/object storage decision, encrypted backup/PITR, measured restore RPO/RTO |
| Edge protection | `blocked` | TLS termination, explicit DNS, distributed rate limiting, WAF/abuse controls, security headers |
| Supply chain | `partial` | SBOM, signed image digest, provenance, and enforced admission policy |
| Observability and incident response | `partial` | Metrics/logs/traces, SLO dashboards, alert routing, on-call owner, synthetic alert test |
| Deployment and rollback | `partial` | Approved artifact promotion, migration rehearsal, rollback drill, previous digest retained |
| Consumer readiness | `partial` | Hosted frontend contract, concurrent-load evidence, no direct DB/CSV access, accessibility/UAT record |
| Compliance and privacy | `partial` | Data inventory, retention/deletion rule, access review, applicable regulatory decision |

The detailed gap register remains [PRODUCTION-GAPS.md](PRODUCTION-GAPS.md).
BookFinance-specific gates remain in
[finance-enterprise-readiness.md](../../systems/architecture/finance-enterprise-readiness.md).

## Safe sequencing

1. Approve the target environment, owner, budget, and data classification.
2. Provision managed secret/identity and remote state through the approved
   provider process; do not put values in Git or local Terraform state.
3. Run IaC preflight and plan; review the redacted resource list.
4. Provision staging only after the written approval and G1–G4 in
   [SCALE-ENABLEMENT.md](SCALE-ENABLEMENT.md) are complete.
5. Run migration, synthetic smoke, backup/restore, alert, and rollback drills.
6. Enable an app only after `deploymentEnabled: false` is deliberately changed
   under an approved promotion record.
7. Re-run this pack and record the exact evidence before any production claim.

## Approval record

| Decision | Approver | Date | Evidence |
|---|---|---|---|
| approve / revise / reject staging | [Name/role] | [YYYY-MM-DD] | [change record / plan output] |
| approve / revise / reject production | [Name/role] | [YYYY-MM-DD] | [release record / drill evidence] |

## Quality gate

- [ ] Current decision is explicit and matches live environment evidence
- [ ] No credential, raw token, or private payload is stored in this pack
- [ ] Every production gate has an owner and evidence path
- [ ] Staging and production deployment switches remain disabled until approval
- [ ] Restore, alert, and rollback drills are recorded before promotion
- [ ] The pack is re-run after material architecture, identity, data, or edge changes
