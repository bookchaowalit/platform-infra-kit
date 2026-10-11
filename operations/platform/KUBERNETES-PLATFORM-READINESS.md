---
title: Kubernetes Platform Readiness
status: evidence
tags: [evidence, operations]
updated: 2026-08-04
---

# Kubernetes Platform Readiness

> **Status:** Design + repository scaffolding complete. A disposable local
> `solo-dev` k3d cluster and shared platform controllers are available for
> validation. **No cloud or production Kubernetes cluster has been provisioned.**
> The Docker Compose lab remains available for local learning only.

**Related:**

- [`infra/platform/README.md`](../../infra/platform/README.md)
- [`infra/platform/iac/README.md`](../../infra/platform/iac/README.md)
- [`operations/platform/PLATFORM-STATUS.md`](PLATFORM-STATUS.md)
- [`operations/platform/COST-PLAN.md`](COST-PLAN.md)
- [`operations/platform/PRODUCTION-COST-COMPARISON.md`](PRODUCTION-COST-COMPARISON.md)
- [`operations/platform/HOMELAB-PLAN.md`](HOMELAB-PLAN.md)
- [`infra/self-hosted-stack/README.md`](../../infra/self-hosted-stack/README.md)
- [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md)

---

## 1. Current state

| Area | State |
|------|-------|
| Solo Empire core | SQLite + TypeScript CLI + MCP on a workstation; not multi-tenant K8s |
| Docker Compose lab | ~80 services under `infra/self-hosted-stack/` for learning |
| Compose secrets | Moved to `.env` / `.env.example` (no hardcoded lab passwords in compose) |
| Kubernetes platform | Scaffolded under `infra/platform/` plus local bootstrap, Helm, GitOps, Kyverno, ESO, and IaC design |
| Local dev cluster | `solo-dev` k3d/K3s; disposable; two pilot apps deployed |
| Local pilot apps | **ai-doc-assistant** and **booknbook** via Argo CD |
| Cloud / production clusters | **None** managed by this repo |
| CI deploy | **None** — validation only (`platform-validate.yml`) |

### What exists today

1. **Reusable Helm chart** `solo-app` — one chart, many apps via values.
2. **GitOps layout** — Argo CD ApplicationSet + application catalog +
   `dev` / `staging` / `production` values.
3. **Kyverno policies** — security baseline in **Audit** mode.
4. **IaC** — OpenTofu modules + staging root `envs/staging/fsn1` (Hetzner k3s);
   `provision=false` by default, secure state/apply gates, and production root disabled.
5. **CI validation** — helm lint/template, kubeconform, trivy config, secret and
   `:latest` detection, optional tofu fmt.
6. **Local Kubernetes bootstrap** — user-local `kubectl`, Helm, and k3d; `solo-dev`
   with Argo CD, cert-manager, Kyverno Audit policies, External Secrets, and
   metrics-server.
7. **Platform boundary checks** — local namespaces, Argo projects, RBAC smoke
   checks, and an External Secrets dummy-value smoke test.
8. **First business pilot** — `ai-doc-assistant` image imported into k3d, deployed
   with `solo-app` via Argo CD Application `ai-doc-assistant-dev`. Runbook:
   [AI-DOC-ASSISTANT-PILOT-RUNBOOK.md](../ai/AI-DOC-ASSISTANT-PILOT-RUNBOOK.md).
9. **Second business pilot** — `booknbook` uses the same onboarding, registry,
   Argo CD, regression, and resilience path. Runbook:
   [BOOKNBOOK-PILOT-RUNBOOK.md](../ai/BOOKNBOOK-PILOT-RUNBOOK.md).
10. **Reusable onboarding** — definitions, templates, scaffold, offline guards,
    unified deploy, dual regression, and business smoke tests under
    `infra/platform/onboarding/`.
11. **Staging readiness** — disabled staging values, Hetzner `fsn1` IaC,
    private registry TLS, pre-apply audit, preflight, remote state design, and
    typed apply wrapper.

### What does **not** exist yet

- Real VPC, cloud cluster, public DNS, shared production registry, managed database,
  vector store, or object storage
- Staging/production Argo CD registration (staging **values** exist; deploy disabled)
- Signed image pipeline (offline contract + Cosign placeholder; enforcement not active)
- Production hostnames or credentials in git
- Managed PostgreSQL / vector store / object storage / PITR (see [PRODUCTION-GAPS.md](PRODUCTION-GAPS.md))
- Provider-provisioned clusters (see [PROVIDER-DECISION.md](PROVIDER-DECISION.md));
  provider choice is recorded but no apply has occurred

---

## 2. Security risks (Compose lab vs platform)

| Risk | Compose lab | Target platform |
|------|-------------|-----------------|
| Hardcoded secrets | Mitigated via env vars; lab still uses simple local secrets | External Secrets + KMS |
| Docker socket mounts | Required for some lab tools; high privilege | Avoid; use K8s APIs / sidecars |
| `:latest` tags | Mostly pinned; few lab-only exceptions | Forbidden by chart + Kyverno |
| Watchtower auto-update | Profile `lab-auto-update` only; not for prod | GitOps digest promotion |
| Traefik dashboard | Bound to `127.0.0.1:8088` | Authenticated admin interfaces only |
| Privileged / hostPath | Common in container labs | Denied by policy (Audit → Enforce) |
| Public exposure | Must never expose lab ports publicly | Private nodes + controlled ingress |

**Rule:** Treat Compose as a classroom. Treat `infra/platform/` as the path to
production readiness.

---

## 3. Docker → Kubernetes migration strategy

```text
Phase 0  Secure Compose lab (done in-repo) — secrets, pins, warnings
Phase 1  Platform scaffolding (done in-repo) — chart, gitops, policies, CI
Phase 2  Choose provider + implement staging OpenTofu modules (done, no apply)
Phase 3  Bootstrap local dev cluster + platform controllers (done)
Phase 4  Validate 2 local pilot apps via onboarding + resilience (done)
Phase 5  Staging cluster + managed PostgreSQL + ESO
Phase 6  Production clusters per region; Enforce policies
Phase 7  Scale catalog toward ~100 applications
```

### Migration mapping (examples)

| Compose concept | Kubernetes equivalent |
|-----------------|------------------------|
| `docker-compose.yml` service | `solo-app` values entry + catalog row |
| `.env` file | Secret manager → ExternalSecret |
| Traefik labels | Ingress / Gateway API |
| Watchtower | Image digest PR + Argo CD sync |
| Host volumes | PVC or managed storage (prefer managed DB/object store) |
| Single host | Separate cluster per env/region |

Do **not** lift the entire 80-service lab into Kubernetes. Only product and
platform applications belong in the app catalog; learning tools stay local.

---

## 4. Tool selection decisions

| Concern | Choice | Why |
|---------|--------|-----|
| Packaging | Helm (`solo-app`) | Mature, values-driven multi-app |
| Delivery | Argo CD ApplicationSet | Catalog × env × region generation |
| Policy | Kyverno (Audit first) | Kubernetes-native YAML policies |
| Secrets | External Secrets Operator | Keeps secrets out of git |
| Autoscaling | HPA + optional KEDA | CPU/mem + event-driven workers |
| Ingress | Ingress NGINX or Gateway API | Chart supports both |
| Validation CI | helm, kubeconform, trivy, custom guards | Fail PRs before merge |
| IaC | OpenTofu | Hetzner `fsn1` staging modules with `provision=false`; production disabled |
| Image trust | Cosign/SBOM/provenance | Offline guard exists; placeholder policy only today |

---

## 5. 100-application deployment model

1. **One chart** (`solo-app`) for nearly all stateless web/worker apps.
2. **Catalog** (`gitops/applications/catalog/apps.yaml`) lists name, namespace,
   image, resources, ingress host, secret refs, autoscaling.
3. **ApplicationSet** expands catalog × environment × region into Argo CD Apps.
4. **Per-env values** under `values/{dev,staging,production}/` override replicas,
   resources, hosts, and monitoring.
5. **Teams** set `solo.empire/team` labels; policies and cost reports use them.
6. **Onboarding a new app** = image in approved registry + catalog entry +
   optional values file + secret remote keys (not values).

### Capacity sketch (planning only)

| Env | Clusters | Apps (target) | Notes |
|-----|----------|---------------|-------|
| dev | 1 local/small | all | Low replicas, Audit policies |
| staging | 1 regional | all | Production-like |
| production | N regional | all | Higher floors, digests, Enforce |

Node pools: `system`, `general`, optional `spot` for workers, optional `data`.

---

## 6. Multi-region strategy

- **Separate cluster per environment and region** (no stretched control plane).
- Argo CD in a management context deploys to many clusters.
- Stateless apps replicate per region via ApplicationSet list elements.
- **Data:** regional managed PostgreSQL and object storage; no multi-region etcd.
- **Failover:** DNS / global traffic management, not Kubernetes federation.
- **Config:** `solo.empire/region` label on every workload.

---

## 7. Autoscaling strategy

| Layer | Tool | Use |
|-------|------|-----|
| Pod | HPA (CPU/memory) | Default for web/API |
| Pod (event) | KEDA | Queues, Kafka, custom metrics |
| Node | Cluster autoscaler / NAP | When pods pending |
| App design | Stateless + connection pooling | Survive scale events |

Defaults in `solo-app`:

- Requests/limits required
- PDB for voluntary disruption safety
- Topology spread across zones when the cluster has them

---

## 8. Backup and disaster recovery

| Component | Approach |
|-----------|----------|
| Cluster etcd / control plane | Cloud managed snapshots (provider) |
| Application config | Git (this monorepo) is SSOT |
| Secrets | Secret manager replication / backup |
| PostgreSQL | Managed automated backups + PITR |
| Object storage | Versioning + cross-region replication for critical buckets |
| Stateless apps | Redeploy from GitOps; no pod-level backup |
| RTO/RPO | Define per venture before production cutover |

Regular **game days**: restore DB to staging; rebuild a cluster from IaC + GitOps.

---

## 9. Observability

| Signal | Direction |
|--------|-----------|
| Metrics | ServiceMonitor optional; Prometheus remote write / managed |
| Logs | Node/agent ship to central store; short local retention |
| Traces | OTLP collectors; sample production |
| Alerts | Route by `solo.empire/team` |
| SLOs | Latency/error/availability per critical app |

Compose stack (Prometheus/Grafana/Loki/Tempo) is a **learning analog**, not the
production observability control plane.

---

## 10. Cost optimization

- Mandatory labels: team, environment, app, region
- Right-size requests; HPA over static over-provisioning
- Spot/preemptible for workers and batch
- Prefer managed DB over always-on self-hosted HA databases for small teams
- Delete idle LoadBalancers and unattached disks via scheduled audits
- Budgets and anomaly alerts per environment

---

## 11. Migration phases (detailed)

### Phase A — Repository ready (current)

- [x] Compose secrets externalized
- [x] Lab warning + Watchtower isolation
- [x] Helm chart + GitOps + policies + CI + readiness doc
- [x] Disposable local `solo-dev` cluster bootstrap
- [x] Local Argo CD, cert-manager, Kyverno, External Secrets, metrics-server
- [x] Kyverno policies applied in Audit mode
- [x] External Secrets local dummy-value smoke test with cleanup
- [x] Reusable onboarding workflow and offline guards
- [x] Two local business pilots with regression/resilience checks
- [x] Staging IaC, pre-apply audit, preflight, secure state design, and apply gate
- [ ] Human review of PR / merge strategy

### Phase B — Cloud foundation

- [x] Select provider and region: Hetzner `fsn1`
- [x] Implement OpenTofu modules (network, cluster, registry, DNS, data contracts)
- [x] Default-safe `provision=false`, preflight, audit, and apply wrapper
- [ ] OIDC for CI roles
- [ ] Bootstrap dev cluster only

### Phase C — Platform services

- [x] Local cert-manager, ESO, Kyverno, metrics-server, and Argo CD
- [ ] Cloud ingress/Gateway and production cluster registration
- [ ] Apply policies in Audit; fix platform findings before Enforce

### Phase D — Pilot apps

- [x] 2 local apps in catalog and onboarding workflow
- [ ] 3–5 apps in catalog
- [ ] Staging promotion path with digests
- [ ] Backup restore drill for managed DB

### Phase E — Production

- [ ] Production clusters per region
- [ ] Enforce policies gradually
- [ ] Scale catalog; retire any temporary Compose prod-like usage

---

## 12. Known limitations

1. **No cloud/production infrastructure** — only a disposable local k3d cluster
   exists; it can be deleted and recreated from the local bootstrap scripts.
2. **Provider not provisioned** — Hetzner `fsn1` is selected and IaC exists, but
   no cloud resource has been created.
3. **Optional validation tools** — local bootstrap installs kubectl, Helm, and
   k3d; kubeconform and some CI scanners remain optional local tools.
4. **Image registry allow-list** uses placeholders (`ghcr.io`, `registry.example.local`).
5. **Cosign / attestations** not enforced yet (placeholder policy).
6. **ApplicationSet** example uses placeholder repo URLs and cluster API servers.
7. **Compose lab** still has a few `:latest` images where upstream lacks tags;
   those are lab-only and allow-listed in tests.
8. **Gateway API / KEDA / ExternalSecret / ServiceMonitor** CRDs require cluster
   installs; kubeconform skips those CRDs unless schemas are provided.
9. **100 apps** is a capacity **target**, not a current inventory.
10. **Do not** use Watchtower, host Docker socket apps, or Compose as production.
11. **Object storage** — local MinIO belongs to the Docker lab; staging
    S3-compatible object storage is planned but not provisioned or wired to a
    production data path.

---

## 13. Verification commands

```bash
# Offline platform guards
python3 infra/tests/platform/platform_validation_test.py
python3 infra/tests/platform/platform_validation_test.py --strict-platform

# Compose syntax (uses .env.example placeholders)
set -a && source infra/self-hosted-stack/.env.example && set +a
docker compose -f infra/self-hosted-stack/docker-compose.yml config --quiet

# Helm (if installed)
helm lint infra/platform/helm/solo-app
helm template example-api infra/platform/helm/solo-app \
  -f infra/platform/gitops/applications/values/dev/example-api.yaml

# Local disposable cluster
export PATH="$HOME/.local/bin:$PATH"
kubectl config use-context k3d-solo-dev
kubectl get nodes
kubectl get pods -A
cd infra/platform/bootstrap/local
./apply-boundaries.sh
./test-external-secrets.sh

# Repo checks
task test
task typecheck
task docs:check
```

---

## 14. Acceptance checklist (repository)

| Criterion | Status |
|-----------|--------|
| No production-target hardcoded secrets | ✅ platform scan |
| No production-target `:latest` | ✅ chart + scan |
| Reusable Helm chart for many apps | ✅ `solo-app` |
| GitOps dev/staging/production + multi-region list | ✅ |
| Two local business pilots through reusable onboarding | ✅ |
| Pilot resilience and business smoke checks | ✅ |
| Requests/limits + probes | ✅ chart defaults |
| Security policies (non-root, registries, resources, privileged) | ✅ Audit |
| CI validates without deploying | ✅ `platform-validate.yml` |
| Docker lab remains available | ✅ |
| No cloud or production K8s provisioned; local disposable K3s only | ✅ |
| Staging IaC defaults safe and apply-gated | ✅ |
| No commit/push by agent | ✅ (human decision) |

---

*Last updated: 2026-08-02*
