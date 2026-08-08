---
title: "Cluster: staging"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-08-08
description: "Documentation for Cluster: staging."
---

# Cluster: staging

| Field | Value |
|-------|-------|
| Environment | `staging` |
| Region | `ap-southeast-1` (example) |
| Purpose | Pre-production validation, production-like sizing |
| Data | Non-production managed DB / synthetic data only |
| Provisioned | **No** — design target only |
| App deploy | **Disabled** (`soloEmpire.deploymentEnabled: false`) |

Staging should mirror production topology (separate cluster, same chart, same policies)
with lower replica floors and staging TLS issuers.

## Values (ready, not applied)

- `gitops/applications/values/staging/common.yaml`
- `gitops/applications/values/staging/ai-doc-assistant.yaml`
- `gitops/applications/values/staging/booknbook.yaml`
- Gate: `gitops/applications/values/staging/DEPLOYMENT.md`

See [ENVIRONMENT-CONTRACT.md](../../../ENVIRONMENT-CONTRACT.md),
[PRODUCTION-GAPS.md](../../../../../operations/PRODUCTION-GAPS.md),
[PROVIDER-DECISION.md](../../../../../operations/PROVIDER-DECISION.md).
