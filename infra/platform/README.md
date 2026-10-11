---
title: "Solo Empire Kubernetes Application Platform"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-09-07
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
├── cloud-providers.yaml      ← cloud/PaaS provider source of truth
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

## Multi-PaaS Control Plane

The repository also exposes a provider-neutral catalog for the cloud and SaaS
providers used, declared, or evaluated by Solo Empire. The registry records
auth sources, CLI binaries, implemented capability status, project usage
evidence, and a proposal-only write policy. A `project_usage.status` of
`documented`, `planned`, `adapter_only`, or `control_only` is not proof of a
live deployment. The PaaS health and inventory surfaces currently cover
Vercel, Render, Railway, Fly.io, and Heroku. The local owner can
now register, review, approve, submit, and verify Render web-service actions,
including the bounded `autoDeploy` service setting, from `/cloud`; other
provider write adapters and environment-variable mutation remain unavailable.
See [Governed PaaS execution](./PAAS-EXECUTION.md).

```bash
# Show the provider catalog without calling external APIs
task paas:catalog

# Show offline provider status without reading secrets or calling APIs
task paas:health

# Make bounded, read-only API checks (requires provider credentials)
task paas:health:live

# Inventory project/service/app metadata (offline by default)
task paas:inventory
task paas:inventory:live
```

The local task dashboard exposes the same surface at `/api/paas`; it defaults to
offline status and accepts `?live=true` for explicit credential resolution and
provider API checks. Set provider credentials through the normal runtime secret
resolver; the variable names are documented in
[`infra/.env.example`](../.env.example).

Render target discovery is a separate bounded read-only surface. Use the local
CLI session when available, or the server-side API key resolver, and pass only
the selected IDs into a later governed request:

```bash
task paas:render:discover -- --live --source cli --json
task paas:render:discover -- --live --source cli --service-id srv-example --environment-id evm-example --json
```

The Cloud/PaaS page exposes the same discovery flow and lets the owner select a
service or recent deploy to populate the action form. Discovery does not make
deploy, restart, rollback, or configuration changes.

The source of truth is [`cloud-providers.yaml`](./cloud-providers.yaml), and the health
adapter is [`scripts/platform/paas_health.py`](../scripts/platform/paas_health.py).
Validate the registry with `task cloud:providers:check` or `task platforms:check`.
It contains names and capability metadata only; no credentials or live account
payloads are stored here.

Live adapters resolve credentials in this order: the configured secret
provider/environment policy, then a registered provider CLI session. Results
include only the source label (`secret_manager`, `env`, or `cli_session`), never
the credential. If a configured secret provider is unreachable, resolution
fails closed rather than bypassing it with a CLI session. `vercel whoami` can
confirm an interactive Vercel session for health checks, but billing API reads
still require a token; GitHub can use the token returned by `gh auth token`.
Offline commands do not inspect any of these credential sources.

### Unified cloud status and tool doctor

Use the normalized status command to review all registered providers, or limit
the report and any live API calls to one provider. Offline is the default;
`--live` is explicit and remains read-only:

```bash
task cloud:status
task cloud:status -- --json
task cloud:status -- --live --provider vercel
task cloud:status -- --live --provider cloudflare --json
task cloud:tools:doctor
task cloud:tools:doctor -- --json
task cloud:tools:doctor -- --check-versions
task cloud:secrets:health -- --offline --json
task cloud:secrets:health -- --provider neon --json
```

The status schema separates health, inventory, usage, billing, and auth source.
Unsupported and not-yet-implemented adapters are reported explicitly instead
of being treated as zero usage; unchecked or unavailable metrics are omitted
rather than rendered as zero. Vercel's billing adapter supplies its usage and
charge summary; GitHub Actions reports usage quantities but not charge amounts.
The local finance ledger remains an aggregate and is not attributed to a
provider. Cloudflare R2's storage estimate is not an invoice. The CLI doctor
only checks whether registry-listed binaries are on `PATH` and prints official
installation guidance by default. `--check-versions` explicitly runs only the
fixed version command from the registry, using the resolved executable
(including Windows `.cmd` shims), a bounded timeout, and no stdin. The default
timeout is eight seconds; Heroku has a registry-declared 40-second allowance
for its slower Windows Node startup. Version probes disable supported
telemetry/auto-update flags and accept numeric versions with build suffixes
without exposing the suffix or terminal color codes. Only a
numeric version or classified error is returned; executable paths, raw
stdout/stderr, account identities and credentials are not returned. Missing
CLIs are not installed, and no login/session command is run by the doctor.
The registry includes official Upstash and PostHog CLIs as well as the existing
12 provider CLIs; registration does not establish an active deployment.

The unified collector also uses bounded GET-only adapters for:

| Provider | Inventory | Usage signal / limitation |
|---|---|---|
| Neon | Projects and up to five projects' branches | Billing-period compute hours, current storage bytes, storage byte-hours and transfer bytes; missing values stay null |
| Cloudflare | Workers and Pages projects; canonical production deployment | R2 retains its existing adapter; Worker request analytics and billed costs remain unavailable |
| RunPod | Pods and serverless endpoints | Desired pod state and RunPod credits/hour only, not actual runtime or accumulated USD spend |
| Supabase | Projects and management-reported database status | Project usage and billing adapters remain unavailable |
| Upstash | Redis databases | Up to five databases' current-month request/bandwidth counters and current storage; billing currency is not assumed |

Each list is capped at 20 items, with a maximum of five detail reads per
resource type. Pagination/truncation and detail failures are explicit; a
partial result is not an account-wide total. Transport rejects redirects,
limits response bodies to 2 MiB, and uses a 15-second timeout. Raw environment
variables, database hosts, public IPs, connection strings and resource secrets
are discarded. Management API health means access to those reads, not uptime.
Neon personal keys can require `NEON_ORG_ID`; Upstash requires
`UPSTASH_EMAIL` plus a Developer API `UPSTASH_API_KEY`, not a Redis REST token.

`paas:inventory` keeps its five-PaaS default for compatibility; explicit
`--provider neon|cloudflare|runpod|supabase|upstash` selects the new read adapter.
`task gpu:workers:status -- --live` adds the same RunPod read projection to
the local queue report without launching, stopping or modifying a worker.
Default GPU status remains local-only.

Cloud secret health lists only registry names and presence classifications.
`--offline` does not read a secret store or environment values; without that
flag the check is explicit. A missing alias or optional configuration name
does not itself mean authentication is impossible. CLI sessions are not
checked by secret-name presence. See
[runtime secret management](../../systems/cloud-platform/secret-management.md).
Cloud status currently writes no persisted dashboard/data-lake projection or
quota notification; those integrations and credential-backed live verification
remain separate work.

The bounded inventory adapter is [`scripts/platform/paas_inventory.py`](../scripts/platform/paas_inventory.py).
It returns only resource IDs, names, and a small set of non-secret metadata;
variables, logs, tokens, raw provider payloads, and mutation operations remain
out of scope. The dashboard exposes it at `/api/paas/inventory`, with live
requests requiring the explicit `?live=true` query.

### Cloud account + usage snapshot (read-only)

The decision board can combine the inventory with non-secret account metadata
and the local finance ledger without returning account IDs, endpoints,
credential references, or raw provider payloads:

```bash
# Local snapshot: no provider API or secret store is read
task cloud:usage

# Explicit bounded provider list/read calls through the existing adapters
task cloud:usage:live

# Cloudflare R2 account-level storage/object signal only
task cloud:r2:usage
task cloud:r2:usage:live

# GitHub Actions current-month billing usage (minutes/storage)
task cloud:github:actions
task cloud:github:actions:live

# Vercel billing summary
task cloud:vercel:billing
task cloud:vercel:billing:live
```

The same contract is available at `/api/cloud/usage`; it defaults to local
aggregation and requires `?live=true` for provider calls. `resources` is an
inventory signal, not provider billing telemetry. Cost values are known linked
commitments/payments from `finance_subscriptions`, with no currency conversion.
The first provider-specific adapter is Cloudflare R2. It calls only the
account-level `GET /accounts/{account_id}/r2/metrics` endpoint in explicit live
mode and returns aggregate published/uploaded metrics by storage class. The
provider documents that account-level metrics may lag the latest data. When a
healthy snapshot is available, the adapter adds a clearly labelled
storage-only estimate using the public [R2 pricing page](https://developers.cloudflare.com/r2/pricing/):
current published payload is treated as a constant GB-month, Standard gets the
documented 10 GB-month free tier, and Infrequent Access is priced separately.
The estimate excludes operation counts, Infrequent Access retrieval, and
30-day daily-average/rounding effects, so it is not an invoice and does not
enable provider billing reconciliation. Cloudflare's billing-usage endpoints
remain out of scope while they are marked alpha/restricted in the official API
reference.

The aggregate collector is
[`scripts/platform/cloud_usage.py`](../scripts/platform/cloud_usage.py), and
the provider adapter is
[`scripts/platform/cloudflare_r2_usage.py`](../scripts/platform/cloudflare_r2_usage.py).
Both are read-only and never write SQLite, the data lake, or provider
resources. Raw provider payloads, account IDs, bucket names, and credential
values are discarded at the adapter boundary.

### Free cloud/SaaS quota coverage

The same snapshot now includes `usage.free_quota`, built from the
[`free-resource-index.json`](../../systems/cloud-platform/free-resource-index.json)
catalog. It lists free-forever and free-quota cloud/SaaS services, their public
plan-limit references, and the status of a live usage adapter:

| Status | Meaning |
|---|---|
| `usage_available` | A bounded adapter returned an observed value and a known free limit |
| `reference_only` | The service and free-limit reference are cataloged, but no live usage adapter exists |
| `unavailable` | An adapter exists but the provider request failed; observed usage is omitted |
| `not_configured` | The required provider credential is not available |
| `not_connected` | The service has no configured usage connection |

The quota adapters currently cover Cloudflare R2 Standard storage (10 GB-month)
and GitHub Actions. R2 reports used, remaining, and percentage when account
metrics are healthy. GitHub Actions reads the current UTC month's billing usage
report; it reports minutes and storage usage, and calculates remaining minutes
only when the API or `GITHUB_ACTIONS_PLAN` identifies the plan. Other services
remain explicit gaps until an official read-only usage endpoint and credential
scope are verified. The projection is reference/diagnostic data and does not
claim an invoice or treat failed calls as zero.

The implementation is
[`scripts/platform/free_quota.py`](../scripts/platform/free_quota.py), and its
contract is covered by `tests/platform/free_quota_test.py` and
`tests/platform/github_actions_usage_test.py`. The GitHub adapter is
[`scripts/platform/github_actions_usage.py`](../scripts/platform/github_actions_usage.py);
it uses only GitHub's read-only billing usage report, requires
`GITHUB_PERSONAL_ACCESS_TOKEN`, and uses `GITHUB_BILLING_OWNER_TYPE` plus
`GITHUB_BILLING_OWNER` for organization billing. A user billing report can
derive the owner from the authenticated `/user` response without returning the
login to the dashboard. The official endpoint is limited to accounts on
GitHub's enhanced billing platform and requires the documented plan or
organization administration read permission.

### Vercel billing charges (read-only)

The next provider-specific billing adapter is
[`scripts/platform/vercel_billing.py`](../scripts/platform/vercel_billing.py).
In explicit live mode it calls only Vercel's official
`GET /v1/billing/charges` endpoint, requests a bounded window, consumes the
FOCUS v1.3 JSONL stream in memory, and returns only charge count, totals by
currency, and a small service/category breakdown. Raw FOCUS rows, resource
identifiers, tags, account identifiers, and tokens are discarded. It never
calls a mutating Vercel endpoint and it does not archive billing rows to the
data lake yet.

```bash
# Offline contract (does not resolve credentials)
task cloud:vercel:billing

# Live read-only billing window (requires VERCEL_TOKEN and billing access)
task cloud:vercel:billing:live
```

The official API exposes billing data for teams with the appropriate billing
scope; Vercel documents that this scope is available for Pro and Enterprise
teams. The dashboard labels this as provider billing charges, not as the local
finance ledger. If the token or billing permission is absent, the adapter
returns a safe `not_configured`/`error` state and the dashboard keeps the
provider cost disconnected. The response also exposes only the required secret
name, whether a team scope was configured, and a machine-readable next action;
it never returns a secret value, team ID, or provider payload. A
`secret_provider_unreachable` result means the runtime secret session must be
restored before retrying; it is not evidence that the Vercel token is invalid.

Render and Fly.io remain inventory/metrics/pricing references in this phase,
not billing-charge adapters. Their official documentation describes provider
dashboards, invoices, or usage/pricing surfaces, but this repository has not
found a bounded public charges endpoint with the same read-only contract. Keep
their costs in the local ledger until an official API can be verified.

### Local self-hosted control plane (read-only)

The existing local self-hosted runtime is now visible from the same dashboard
without adding Coolify, CapRover, or Dokku. The adapter reads only bounded
Docker container state and Kubernetes node/Argo application status. It never
executes `docker stop`, `docker rm`, `kubectl delete`, `kubectl apply`, Helm,
or cluster-management commands.

```bash
# Inspect Docker Compose lab + local K3s/k3d in one JSON report
task selfhosted:health

# Inspect one boundary only
task selfhosted:health:docker
task selfhosted:health:k8s
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
task selfhosted:readiness
task selfhosted:readiness:coolify
task selfhosted:readiness:caprover
task selfhosted:readiness:dokku
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

### Render discovery and action preflight

Render now has a separate read-only adapter for selecting a service and a
rollback target. Discovery reads bounded service metadata and, when a service
is selected, recent deploy metadata. It never calls `POST /rollback`, `POST
/deploy`, or `PATCH /services`.

```bash
# Discover Render services without calling the provider
task paas:render:discover -- --json

# Discover services and recent deploys through Render GET endpoints
task paas:render:discover -- \
  --live \
  --environment-id env-staging \
  --service-id srv-staging \
  --json

# If the local Render CLI is already logged in, use its read-only session
task paas:render:discover -- \
  --live \
  --source cli \
  --service-id srv-staging \
  --json

# Check a staging or production rollback target; this still does not roll back
task paas:render:preflight -- \
  --live \
  --source cli \
  --service-id srv-example \
  --environment-id evm-example \
  --environment production \
  --target-deploy-id dep-previous \
  --health-url https://service.onrender.com/healthz \
  --json

# Check a pinned deploy before registering the approval request
python3 infra/scripts/platform/render_preflight.py action-preflight \
  --live --source cli --action deploy \
  --service-id srv-example --environment-id evm-example \
  --environment production \
  --target-revision 0123456789abcdef0123456789abcdef01234567 \
  --health-path /healthz --json
```

The action preflight fails closed unless the environment returned by Render is
named the requested `staging` or `production`, the service is bound to that
exact environment, and the requested action's recovery checks pass. Deploy,
restart, and rollback require `autoDeploy` to be disabled, one current live
deploy, no deploy in progress, and a provider-owned health URL returning HTTP
2xx. A `set-auto-deploy` preflight requires a known current value that differs
from the requested value. A passing preflight only produces evidence for a
later proposal; `execution_allowed` remains `false` and `write_attempted`
remains `false`.

The local task dashboard also exposes Render discovery at
`/api/paas/render/discovery`; use `?live=true&source=cli` when the local Render
CLI session is authenticated. Action preflight accepts only a provider-owned
Render health origin, so an operator-supplied path cannot turn the dashboard
into an arbitrary network-probe surface. The dashboard exposes the bounded
`/api/paas/render/action-preflight` GET route for deploy, restart, rollback, and
set-auto-deploy; the legacy `/api/paas/render/preflight` route remains for
rollback compatibility. Both derive the health origin from the provider-owned
Render URL and remain read-only. The `cli` source captures only sanitized service,
environment, deploy status, commit ID, and timestamps; owner, repository,
SSH, and secret-shaped fields are never emitted.

The implementation is [`scripts/platform/render_preflight.py`](../scripts/platform/render_preflight.py).
Selected services also return a sanitized `healthCheckPath`; the dashboard
uses it when present and falls back to `/healthz` when the provider does not
return one. The same read-only adapter now checks deploy, restart, rollback,
and set-auto-deploy prerequisites before an approval request is created.

### Governed action proposal and Render execution

The action policy describes `deploy`, `restart`, and `rollback` per provider,
plus the bounded Render `set-auto-deploy` action,
including the stable resource type, target fields, provider API surface, and
whether the action is `supported`, `manual`, or `unsupported`. The policy is
governed: every action requires a matching approved `paas` decision record.
Only `render-v1` is enabled. Merely inspecting or registering a proposal cannot
call a provider write endpoint; submission is a separate confirmed command.

```bash
# Inspect the action/resource matrix
task paas:actions

# Produce a blocked proposal; this does not contact a provider or write SQLite
task paas:action:propose -- \
  --provider render \
  --action rollback \
  --resource-type service \
  --resource-id srv-example \
  --environment production \
  --environment-id evm-example \
  --health-path /healthz \
  --rollback-target dep-example-previous \
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
resource, environment name/ID, target, reason, and health path. Live preflight
and an atomic, non-replayable claim are required before submission. Setting
`execution_enabled` to `false` disables new execution; verification stays
available. No automatic rollback is performed. The command protocol, local
browser boundary, uncertainty handling, and known gaps are documented in
[PAAS-EXECUTION.md](./PAAS-EXECUTION.md).

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
