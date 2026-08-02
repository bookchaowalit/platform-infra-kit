# Environment Contract

This contract defines the target shape of Solo Empire environments. It is
preparation only: **no cloud account, Kubernetes cluster, DNS record, registry,
or managed database is created by this document.**

Staging values may exist in Git with **`soloEmpire.deploymentEnabled: false`**.
That is readiness scaffolding, not a deployment.

**Related:** [PRODUCTION-GAPS.md](../../docs/operations/PRODUCTION-GAPS.md),
[PROVIDER-DECISION.md](../../docs/operations/PROVIDER-DECISION.md),
[DATA-CONTRACT.md](./DATA-CONTRACT.md),
[onboarding/README.md](./onboarding/README.md).

---

## Environment roles

| Environment | Purpose | Cluster model | Data policy | Deployment policy |
|---|---|---|---|---|
| `local` | Docker learning lab | Docker Compose | disposable/local volumes; MinIO lab-only | manual profile start |
| `dev` | Kubernetes integration | disposable k3d (`k3d-solo-dev`) today | pilot-local; emptyDir allowed where documented | Argo CD auto-sync on local Git source |
| `homelab` | portfolio K3s | single-node private LAN | **DEMO_ONLY** for ai-doc-assistant (emptyDir Chroma/uploads) | live demos; not staging |
| `staging` | release rehearsal | separate cluster or isolated managed environment (**not provisioned**) | durable Postgres + vector + S3 plan; no emptyDir for durable RAG | **disabled by default**; human-approved promotion |
| `production` | user-facing workloads | separate cluster per region (**not provisioned**) | managed HA data, PITR, restore drills | GitOps promotion with approval |

---

## 1. Namespace

| Environment | Namespace pattern | Examples |
|-------------|-------------------|----------|
| dev (local pilots) | `apps-<app>-dev` | `apps-ai-doc-assistant-dev`, `apps-booknbook-dev` |
| staging (target) | `apps-<app>-staging` | `apps-ai-doc-assistant-staging`, `apps-booknbook-staging` |
| production (target) | `apps-<app>-production` | per app |

Platform namespaces (design):

```text
platform              shared ingress, GitOps, observability, security
security              scanners, policy, external-secret integrations
monitoring            metrics agents and monitoring components
```

An application namespace owns its Deployment, Service, ServiceAccount,
NetworkPolicy, ConfigMap, and project secret **references**. Platform namespaces
must not receive application database credentials by default.

**Uniqueness:** One app id → one namespace per environment. Validated by
`validate-onboarding.py` for approved inventory entries.

---

## 2. Registry

| Environment | Registry (target) | Tag policy |
|-------------|-------------------|------------|
| dev (local) | `k3d-solo-registry:5000` (host push `localhost:5111`) | `git-<fullsha>` only; never `:latest` |
| staging | Shared private registry (TBD after provider decision) | immutable tag **or** digest; `git-pending` only as pre-enable placeholder |
| production | Same org registry with retention + scan | digest preferred; Cosign verify when signing is live |

Rules:

- Chart helper rejects `image.tag=latest`.
- Deploy scripts refuse `latest`, `0.1.0-local`, and `git-pending`.
- Staging/production values may use `git-pending` **only while**
  `soloEmpire.deploymentEnabled: false`.

---

## 3. Secrets

| Rule | Detail |
|------|--------|
| Never in Git | No API keys, DB URLs with passwords, or TLS private keys |
| Delivery | External Secrets Operator → Kubernetes Secret |
| Store | Cloud/VPS secret manager or sealed local store (staging+) |
| Dev pilots | Optional dummy Secret for demos; real keys only via env + `create-pilot-secret.sh` pattern |
| Staging values | ESO path **references** only (`remoteRef.key` / `property`) |

Validation scans platform + onboarding trees for hardcoded secret patterns.

---

## 4. Ingress

| Environment | Hostname pattern | TLS |
|-------------|------------------|-----|
| dev (local) | `<app>.dev.local` → host port **18080** | optional / none |
| staging | `<app>.staging.<domain>` (placeholder `.example.local` until DNS exists) | cert-manager issuer placeholder |
| production | `<app>.<domain>` | production issuer; no staging issuer |

Rules:

- Internet traffic only via load balancer + ingress/gateway.
- No public exposure of local k3d or Docker lab ports.
- Staging TLS secret **names** may appear in values; secret **data** never does.

---

## 5. Database and vector storage

| Concern | Policy |
|---------|--------|
| In app chart | **Forbidden** — no PostgreSQL/Redis/Qdrant subcharts in `solo-app` |
| PostgreSQL | Managed (or separate VM service): per-app database, role, secret, NetworkPolicy, backup scope |
| Vector store | Managed Qdrant / pgvector / equivalent; **no emptyDir for staging/prod** durable RAG |
| Object storage | Bucket + access boundary when uploads/backups needed |
| Dev / Homelab exception | Documented pilot-local / DEMO_ONLY (e.g. Chroma emptyDir) allowed only in **dev** and **homelab** |
| Staging rejection | `chromaEmptyDirAllowed: false`, `uploadsEmptyDirAllowed: false`; ExternalSecret refs required |
| MinIO | Docker Compose lab only — not Homelab/staging K8s data plane |

Each approved app must declare `data_contract` in `APP-INVENTORY.yaml`.
Staging values restate data intent under `soloEmpire.data` (see
`dataContract: staging-durable-planned` for ai-doc-assistant).
Durable design: `docs/operations/AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md`.

---

## 6. Resource budgets

Per-environment floors (design defaults in values overlays):

| Environment | Min replicas | CPU request (typ.) | Memory request (typ.) | HPA max (typ.) |
|-------------|--------------|--------------------|------------------------|----------------|
| dev | 1 | 100m | 256Mi | 2 |
| staging | 2 | 100m | 256Mi | 4–6 |
| production | 3 | 200m | 256Mi+ | 20 (app-specific) |

Rules:

- Every workload: `resources.requests` **and** `resources.limits`.
- PDB enabled when replicas ≥ 2.
- Cost labels required (see below) before cloud enablement.
- Soft monthly budget targets are set **after** provider choice; see
  PRODUCTION-GAPS cost section.

---

## Required labels

Every Kubernetes workload and (future) cloud data resource must carry:

```text
solo.empire/team
solo.empire/environment
solo.empire/region
app.kubernetes.io/name
app.kubernetes.io/part-of
app.kubernetes.io/component
```

Target additional labels when cost tooling exists:

```text
solo.empire/cost-center
solo.empire/managed-by
```

These support cost allocation, incident ownership, backup selection, and cleanup.

---

## Exposure rules

- Internet traffic enters through the managed load balancer and ingress/gateway.
- PostgreSQL, Valkey, NATS, Qdrant, and object storage remain private.
- Applications receive data endpoints through External Secrets, never Git values.
- Platform dashboards are private by default and protected by identity-aware access.
- Kubernetes API access uses short-lived identity/OIDC, not static admin tokens.

---

## Staging deployment gate

Staging is **ready as Git values only** when:

1. `values/staging/<app>.yaml` exists for each approved pilot.
2. `soloEmpire.deploymentEnabled` is **`false`**.
3. ApplicationSet does **not** auto-deploy staging (see `applicationset.yaml`).
4. No real secrets or live registry credentials are present.
5. `validate-onboarding.py` and CI platform validation pass.

Staging is **enabled** only via an explicit human PR that flips the gate and
registers a real cluster (out of scope for this contract’s preparation work).

---

## Minimum production gates

Before `production` is enabled, the platform must have:

- managed Kubernetes **or** an explicitly accepted self-managed equivalent
  ([PROVIDER-DECISION.md](../../docs/operations/PROVIDER-DECISION.md))
- IaC for network, cluster, node pools, DNS, registry, data, and secrets
- Argo CD registered with the target cluster
- External Secrets connected to the selected secret manager
- Kyverno policies reviewed and moved from Audit to Enforce where appropriate
- encrypted backups, PITR where supported, and a restore drill
- metrics, logs, traces, alerts, and cost allocation
- documented rollback and incident ownership

See [PRODUCTION-GAPS.md](../../docs/operations/PRODUCTION-GAPS.md) for the open list.

---

## Current status

| Environment | Status |
|-------------|--------|
| `local` | Active (Docker Compose lab) |
| `dev` | Active on disposable **k3d-solo-dev** for ai-doc-assistant + booknbook |
| `staging` | Helm values prepared (`deploymentEnabled: false`); **IaC** for Hetzner+k3s `fsn1` with `provision=false`; **no apply** without approval |
| `production` | Design only; IaC root **disabled** |

No Kubernetes or cloud resource is provisioned by this contract.
