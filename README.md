---
title: "Solo Empire Kubernetes Application Platform"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-08-23
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
├── paas-registry.json        ← read-only multi-PaaS provider catalog
├── paas-action-policy.json   ← governed action/resource/approval contract
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

## Multi-PaaS Control Plane (read-only)

The repository also exposes a small provider-neutral catalog and health surface
for Vercel, Render, Railway, Fly.io, and Heroku. It is intentionally limited to
credential state, bounded API health checks, provider metadata, and dashboard
links. Deployment, restart, rollback, environment-variable mutation, and other
write actions are disabled.

```bash
# Show the provider catalog without calling external APIs
npm --prefix infra run paas:catalog

# Check whether provider credentials are available locally
npm --prefix infra run paas:health

# Make bounded, read-only API checks (requires provider credentials)
npm --prefix infra run paas:health:live

# Inventory project/service/app metadata (offline by default)
npm --prefix infra run paas:inventory
npm --prefix infra run paas:inventory:live
```

The local task dashboard exposes the same surface at `/api/paas`; it defaults to
offline credential inspection and accepts `?live=true` for an explicit live
check. Set provider credentials through the normal runtime secret resolver; the
variable names are documented in [`infra/.env.example`](../.env.example).

The catalog is [`paas-registry.json`](./paas-registry.json), and the health
adapter is [`scripts/platform/paas_health.py`](../scripts/platform/paas_health.py).
This phase does not persist provider payloads in the data lake.

The bounded inventory adapter is [`scripts/platform/paas_inventory.py`](../scripts/platform/paas_inventory.py).
It returns only resource IDs, names, and a small set of non-secret metadata;
variables, logs, tokens, raw provider payloads, and mutation operations remain
out of scope. The dashboard exposes it at `/api/paas/inventory`, with live
requests requiring the explicit `?live=true` query.

### Local self-hosted control plane (read-only)

The existing local self-hosted runtime is now visible from the same dashboard
without adding Coolify, CapRover, or Dokku. The adapter reads only bounded
Docker container state and Kubernetes node/Argo application status. It never
executes `docker stop`, `docker rm`, `kubectl delete`, `kubectl apply`, Helm,
or cluster-management commands.

```bash
# Inspect Docker Compose lab + local K3s/k3d in one JSON report
npm --prefix infra run selfhosted:health

# Inspect one boundary only
npm --prefix infra run selfhosted:health:docker
npm --prefix infra run selfhosted:health:k8s
```

The dashboard exposes the same read-only result at `/api/self-hosted`. This is
a local operations surface, not a production PaaS: the Compose services are a
learning lab, the K3s cluster is a disposable local cluster, and no cloud or
production cluster is provisioned by this repository.

The implementation is [`scripts/platform/self_hosted_health.py`](../scripts/platform/self_hosted_health.py).

### Self-hosted PaaS install readiness (read-only)

Before adding Coolify, CapRover, or Dokku, run the local preflight. It reports
resource availability, listening-port conflicts, existing workloads, Docker
and K3s status, and backup evidence without installing or changing anything:

```bash
npm --prefix infra run selfhosted:readiness
npm --prefix infra run selfhosted:readiness:coolify
npm --prefix infra run selfhosted:readiness:caprover
npm --prefix infra run selfhosted:readiness:dokku
```

The current host is intentionally blocked for an in-place PaaS install because
the existing lab owns shared SSH/web ports and already has active workloads.
Use a fresh, isolated VM/server and complete the approval checklist in
[`SELF-HOSTED-PAAS-INSTALL-PLAN.md`](./SELF-HOSTED-PAAS-INSTALL-PLAN.md) before
running any provider installation command. Start from the non-secret target
intake template [`SELF-HOSTED-PAAS-TARGET.example.yaml`](./SELF-HOSTED-PAAS-TARGET.example.yaml).
The dashboard exposes the report at
`/api/self-hosted/readiness`.

The implementation is [`scripts/platform/self_hosted_readiness.py`](../scripts/platform/self_hosted_readiness.py).

### Render discovery and staging rollback preflight

Render now has a separate read-only adapter for selecting a service and a
rollback target. Discovery reads bounded service metadata and, when a service
is selected, recent deploy metadata. It never calls `POST /rollback`, `POST
/deploy`, or `PATCH /services`.

```bash
# Discover Render services without calling the provider
npm --prefix infra run paas:render:discover -- --json

# Discover services and recent deploys through Render GET endpoints
npm --prefix infra run paas:render:discover -- \
  --live \
  --environment-id env-staging \
  --service-id srv-staging \
  --json

# If the local Render CLI is already logged in, use its read-only session
npm --prefix infra run paas:render:discover -- \
  --live \
  --source cli \
  --service-id srv-staging \
  --json

# Check a rollback target; this is staging-only and still does not roll back
npm --prefix infra run paas:render:preflight -- \
  --live \
  --source cli \
  --service-id srv-staging \
  --environment-id env-staging \
  --target-deploy-id dep-previous \
  --health-url https://staging.example.com/health \
  --json
```

The preflight fails closed unless the environment returned by Render is named
`staging`, the service is bound to that exact environment, `autoDeploy` is
disabled, the target deploy is successful (`live` or a completed previous
deploy such as `deactivated`), and the health URL returns HTTP 2xx. A passing
preflight only produces evidence for a later proposal; `execution_allowed`
remains `false` and `write_attempted` remains `false`.

The local task dashboard also exposes Render discovery at
`/api/paas/render/discovery`; use `?live=true&source=cli` when the local Render
CLI session is authenticated. The rollback preflight stays CLI-only so an
operator-supplied health URL cannot turn the dashboard into an arbitrary
network-probe surface. The `cli` source captures only sanitized service,
environment, deploy status, commit ID, and timestamps; owner, repository,
SSH, and secret-shaped fields are never emitted.

The implementation is [`scripts/platform/render_preflight.py`](../scripts/platform/render_preflight.py).

### Governed action proposal (still no provider writes)

The action policy describes `deploy`, `restart`, and `rollback` per provider,
including the stable resource type, target fields, provider API surface, and
whether the action is `supported`, `manual`, or `unsupported`. The policy is
proposal-only: every action requires a matching approved `paas` decision record,
and the global execution gate remains disabled.

```bash
# Inspect the action/resource matrix
npm --prefix infra run paas:actions

# Produce a blocked proposal; this does not contact a provider or write SQLite
npm --prefix infra run paas:action:propose -- \
  --provider render \
  --action rollback \
  --resource-type service \
  --resource-id srv-example \
  --environment production \
  --rollback-target deploy-example-previous \
  --reason "Recover from a verified production incident" \
  --json
```

To register the proposal locally as an approval request, add
`--register --confirm-register`. This writes only a `decision_records` row and
its audit event; it still cannot call Render or any other provider. Review it
with the existing decision workflow, for example:

```bash
python3 infra/scripts/cli/decision-cli.py list \
  --status proposed --privacy-class internal --json
python3 infra/scripts/cli/decision-cli.py approve <decision-id> \
  --confirm --reason "Approved after reviewing the incident evidence"
```

The proposal fingerprint binds an approval to the exact provider, action,
resource, environment, and target. Approval alone is insufficient while
`execution_enabled` is `false`; no automatic rollback is performed.

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
python3 infra/tests/platform/platform_validation_test.py
```

## Related docs

- [Technology Platform and Security Evidence](../../systems/architecture/technology-capability-evidence-platform-security.md)
- [Current platform status](../../operations/platform/PLATFORM-STATUS.md)
- [Cost plan](../../operations/platform/COST-PLAN.md)
- [Production cost comparison](../../operations/platform/PRODUCTION-COST-COMPARISON.md)
- [Portfolio execution plan](../../operations/evidence/PORTFOLIO-EXECUTION-PLAN.md)
- [Homelab plan](../../operations/platform/HOMELAB-PLAN.md)
- [Kubernetes Platform Readiness](../../operations/platform/KUBERNETES-PLATFORM-READINESS.md)
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
| **ai-doc-assistant** | `apps-ai-doc-assistant-dev` | `ai-doc-assistant-dev` | pilot-local | [runbook](../../operations/ai/AI-DOC-ASSISTANT-PILOT-RUNBOOK.md) |
| **booknbook** | `apps-booknbook-dev` | `booknbook-dev` | pilot-local | [runbook](../../operations/ai/BOOKNBOOK-PILOT-RUNBOOK.md) |

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
| [PRODUCTION-GAPS.md](../../operations/platform/PRODUCTION-GAPS.md) | Open production gaps |
| [PROVIDER-DECISION.md](../../operations/platform/PROVIDER-DECISION.md) | Locked staging: Hetzner k3s fsn1 |
| [STAGING-INFRA-RUNBOOK.md](../../operations/platform/STAGING-INFRA-RUNBOOK.md) | Plan-only ops + enablement checklist |
| [iac/README.md](./iac/README.md) | OpenTofu modules + plan script |
| [values/staging/DEPLOYMENT.md](./gitops/applications/values/staging/DEPLOYMENT.md) | App deploy gate |

## What this platform does **not** do yet

- Provision real cloud VPCs, clusters, DNS, or registries
- Deploy to staging or production clusters
- Store or load production credentials
- Replace the Docker Compose learning lab
