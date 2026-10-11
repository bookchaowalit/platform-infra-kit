---
title: "Application Onboarding (local k3d pilots)"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-08-08
description: "Documentation for Application Onboarding (local k3d pilots)."
---

# Application Onboarding (local k3d pilots)

Reusable workflow for adding a **business application** to the Solo Empire
Kubernetes platform on **k3d-solo-dev only**. Does not provision cloud,
production, or real secrets.

## What gets created

| Artifact | Path pattern |
|----------|----------------|
| App definition | `infra/platform/onboarding/apps/<name>.yaml` |
| Catalog entry | `infra/platform/gitops/applications/catalog/apps.yaml` |
| Dev values | `infra/platform/gitops/applications/values/dev/<name>.yaml` |
| Argo Application template | `infra/platform/bootstrap/local/applications/<name>-dev.yaml.tpl` |
| Namespace destination | AppProject allows `apps-<name>-dev` (CreateNamespace) |
| Deploy entrypoint | `deploy-app.sh <name>` (wrappers keep old names) |
| Pilot runbook | `operations/<NAME>-PILOT-RUNBOOK.md` |

## Prerequisites

1. App is `approved` in `APP-INVENTORY.yaml` with an explicit **`data_contract`**
2. Single-service Dockerfile; no PostgreSQL/Redis inside the app chart
3. Health endpoints (`/healthz`, `/readyz` by default)
4. Inventory review complete (not freelance/client, not multi-service)

Before adding an app data path, read the shared
[Data Lake learning playbook](../../../learning/platform-engineering/app-cli-data-lake-playbook.md).
Every app must choose a batch, streaming, or native-file lane and persist to
Object Storage before creating an SQLite, API, MCP, dashboard, vector, or other
operational projection. The pilot `pilot-local` contract is still a lab
boundary; it does not make emptyDir or local uploads durable.

## Scaffold a new app (do not deploy third app yet)

```bash
# Dry-run: print paths that would be created
python3 infra/platform/onboarding/scripts/onboard-app.py --name example --dry-run

# Write scaffolding from definition + templates (fails if name already exists
# unless --force; never deploys)
python3 infra/platform/onboarding/scripts/onboard-app.py \
  --name example \
  --source-path path/to/app \
  --team product \
  --component web \
  --target-port 8080 \
  --data-contract pilot-local
```

Existing pilots **ai-doc-assistant** and **booknbook** already have definitions
under `apps/`. Use validate + deploy; do not re-scaffold unless intentional.

## Validate (offline guards)

```bash
python3 infra/platform/onboarding/scripts/validate-onboarding.py
# also invoked from platform_validation_test.py --strict-platform
# and from .github/workflows/platform-validate.yml (CI)
```

Guards:

- Unique app name and namespace across catalog + definitions
- Immutable image tag policy (no `:latest`; deploy rejects `git-pending`)
- Required probes (liveness, readiness, startup)
- Required resources (requests + limits)
- Required ownership labels (`app.team`, `app.environment`, `app.component`, `partOf`)
- No hardcoded secrets in values / catalog / templates
- Explicit `data_contract` on every catalog app in `APP-INVENTORY.yaml`
- Staging values present with `soloEmpire.deploymentEnabled: false`
- No active ApplicationSet staging generator

## Deploy (local only)

```bash
bash infra/platform/bootstrap/local/deploy-app.sh ai-doc-assistant
bash infra/platform/bootstrap/local/deploy-app.sh booknbook
# backward-compatible wrappers:
bash infra/platform/bootstrap/local/deploy-pilot.sh
bash infra/platform/bootstrap/local/deploy-booknbook.sh
```

## Regression (both pilots)

```bash
bash infra/platform/bootstrap/local/verify-pilots-regression.sh
```

Checks Argo Synced/Healthy, Pod Ready, healthz/readyz HTTP 200, NetworkPolicy.

## Business smoke (booknbook)

```bash
bash infra/platform/bootstrap/local/smoke-booknbook.sh
```

Homepage 200, locale middleware, static assets, probe paths not redirected.

## Resilience (per app)

```bash
NS=apps-ai-doc-assistant-dev APP=ai-doc-assistant ARGO_APP=ai-doc-assistant-dev \
  bash infra/platform/bootstrap/local/verify-pilot-resilience.sh

NS=apps-booknbook-dev APP=booknbook ARGO_APP=booknbook-dev \
  bash infra/platform/bootstrap/local/verify-pilot-resilience.sh
```

## Current onboarded pilots

| App | Namespace | Argo app | Data contract |
|-----|-----------|----------|---------------|
| ai-doc-assistant | apps-ai-doc-assistant-dev | ai-doc-assistant-dev | pilot-local |
| booknbook | apps-booknbook-dev | booknbook-dev | pilot-local |

Do **not** add a third app without inventory approval and data-contract review.
