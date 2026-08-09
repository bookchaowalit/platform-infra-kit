---
title: "Solo Empire Kubernetes Application Platform"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-08-08
description: "Documentation for Solo Empire Kubernetes Application Platform."
---

# Solo Empire Kubernetes Application Platform

Reusable platform for deploying approximately **100 applications** across
centralized Kubernetes clusters, multiple environments, and regions.

> **Status:** Design + manifests plus a local-only bootstrap. A disposable
> `solo-dev` k3d cluster can be created for platform validation. No cloud or
> production cluster is provisioned by this repository.

## Layout

```text
infra/platform/
├── README.md                 ← this file
├── bootstrap/local/          ← disposable local k3d/K3s bootstrap
├── helm/solo-app/            ← reusable application Helm chart
│   └── pilot/                ← generated local values; never the GitOps source
├── gitops/                   ← Argo CD ApplicationSets + app catalog
│   ├── clusters/{dev,staging,production}/
│   └── applications/
├── policies/kyverno/         ← cluster security policies (Audit → Enforce)
└── iac/                      ← provider-neutral Terraform/OpenTofu design
```

## Principles

| Principle | Decision |
|-----------|----------|
| One app chart | `solo-app` deploys many apps via values only |
| GitOps | Argo CD ApplicationSet generates apps from a catalog |
| Environments | Separate overlays: `dev`, `staging`, `production` |
| Regions | Separate cluster per environment **and** region (no stretched clusters) |
| Secrets | External Secrets Operator references — never commit credentials |
| Stateful data | Prefer managed services (PostgreSQL, object storage) outside the app chart |
| Stateless apps | Run in Kubernetes with HPA/KEDA, PDB, NetworkPolicy |
| Security | Kyverno policies start in **Audit** mode |

## Quick start (local validation only)

```bash
cd infra/platform/bootstrap/local
./install-tools.sh
export PATH="$HOME/.local/bin:$PATH"
./create-cluster.sh
./install-platform.sh
./apply-boundaries.sh
./test-external-secrets.sh
```

This installs platform controllers only. It does not deploy business apps.

`helm/solo-app/pilot/` is disposable output. The local deploy script copies
the canonical values from `gitops/applications/values/dev/`, applies only the
local registry image override, and rebuilds this directory before creating the
temporary Git source. It is ignored so deployment cannot dirty or duplicate the
canonical GitOps values.

### Manifest-only validation

```bash
# Helm chart lint (requires helm)
helm lint infra/platform/helm/solo-app
helm template demo infra/platform/helm/solo-app \
  -f infra/platform/gitops/applications/values/dev/example-api.yaml

# Schema validation (requires kubeconform)
helm template demo infra/platform/helm/solo-app \
  -f infra/platform/gitops/applications/values/dev/example-api.yaml \
  | kubeconform -strict -ignore-missing-schemas -

# Platform test suite (stdlib Python; no cluster required)
python3 infra/tests/platform_validation_test.py
```

## Related docs

- [Current platform status](../../operations/PLATFORM-STATUS.md)
- [Cost plan](../../operations/COST-PLAN.md)
- [Production cost comparison](../../operations/PRODUCTION-COST-COMPARISON.md)
- [Portfolio execution plan](../../operations/PORTFOLIO-EXECUTION-PLAN.md)
- [Homelab plan](../../operations/HOMELAB-PLAN.md)
- [Kubernetes Platform Readiness](../../operations/KUBERNETES-PLATFORM-READINESS.md)
- [IaC design](./iac/README.md)
- [Self-hosted Docker lab](../self-hosted-stack/README.md) (local learning only)
- [Service ownership boundaries](../self-hosted-stack/SERVICE-OWNERSHIP.md)
- [Application inventory](./APP-INVENTORY.yaml) (discovery only)
- [Application data contract](./DATA-CONTRACT.md) (approval gate)
- [App/CLI Data Lake learning playbook](../../learning/platform-engineering/app-cli-data-lake-playbook.md) (lake-first procedure)
- [Platform services inventory](./PLATFORM-SERVICES.yaml) (design only)
- [Environment contract](./ENVIRONMENT-CONTRACT.md) (design only)
- [Local Kubernetes bootstrap](./bootstrap/local/README.md) (local-only)

## Pilot applications (local k3d only)

Reusable onboarding: [`onboarding/README.md`](./onboarding/README.md).

| App | Namespace | Argo CD | Data contract | Runbook |
|-----|-----------|---------|---------------|---------|
| **ai-doc-assistant** | `apps-ai-doc-assistant-dev` | `ai-doc-assistant-dev` | pilot-local | [runbook](../../operations/AI-DOC-ASSISTANT-PILOT-RUNBOOK.md) |
| **booknbook** | `apps-booknbook-dev` | `booknbook-dev` | pilot-local | [runbook](../../operations/BOOKNBOOK-PILOT-RUNBOOK.md) |

```bash
# After platform bootstrap on k3d-solo-dev:
bash infra/platform/bootstrap/local/deploy-app.sh ai-doc-assistant
bash infra/platform/bootstrap/local/deploy-app.sh booknbook
bash infra/platform/bootstrap/local/verify-pilots-regression.sh
bash infra/platform/bootstrap/local/smoke-booknbook.sh
python3 infra/platform/onboarding/scripts/validate-onboarding.py
```

## Staging readiness (not deployed)

Staging **values** exist for both pilots with `soloEmpire.deploymentEnabled: false`.
**IaC** for single-region Hetzner + k3s (`fsn1`) is under `iac/envs/staging/fsn1/`
with **`provision = false`**, private registry TLS, preflight, audit, secure
remote-state requirements, and an apply gate. ApplicationSet staging generators
stay inactive. Production IaC root is disabled.

MinIO remains part of the Docker learning lab. Staging object storage is a
separate S3-compatible data-plane decision and has not been provisioned or
connected to production app data.

| Doc | Purpose |
|-----|---------|
| [ENVIRONMENT-CONTRACT.md](./ENVIRONMENT-CONTRACT.md) | Namespace, registry, secrets, ingress, data, budgets |
| [PRODUCTION-GAPS.md](../../operations/PRODUCTION-GAPS.md) | Open production gaps |
| [PROVIDER-DECISION.md](../../operations/PROVIDER-DECISION.md) | Locked staging: Hetzner k3s fsn1 |
| [STAGING-INFRA-RUNBOOK.md](../../operations/STAGING-INFRA-RUNBOOK.md) | Plan-only ops + enablement checklist |
| [iac/README.md](./iac/README.md) | OpenTofu modules + plan script |
| [values/staging/DEPLOYMENT.md](./gitops/applications/values/staging/DEPLOYMENT.md) | App deploy gate |

## What this platform does **not** do yet

- Provision real cloud VPCs, clusters, DNS, or registries
- Deploy to staging or production clusters
- Store or load production credentials
- Replace the Docker Compose learning lab
