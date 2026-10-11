---
title: Homelab observability runbook
status: durable
tags: [durable, operations, runbook]
updated: 2026-08-04
---

# Homelab observability runbook

**Scope:** private LAN Homelab K3s (portfolio / demo)  
**Status:** Read-only baseline available; **not** production monitoring  
**Last updated:** 2026-08-02

Related:

- [SLO-SLI-BASELINE.md](SLO-SLI-BASELINE.md)
- [HOMELAB-PLATFORM-OPERATIONS.md](HOMELAB-PLATFORM-OPERATIONS.md)
- [HOMELAB-K3S-RUNBOOK.md](HOMELAB-K3S-RUNBOOK.md)
- [PLATFORM-STATUS.md](PLATFORM-STATUS.md)
- [PRODUCTION-GAPS.md](PRODUCTION-GAPS.md)
- Design-only alerts: `infra/platform/observability/alerts/`

---

## 1. Current monitoring boundary

| Layer | What runs | Purpose |
|-------|-----------|---------|
| Homelab K3s | **metrics-server** (bundled), Argo CD health, probes, Kyverno Audit | Resource usage + app health smoke |
| Docker Compose Lab | Prometheus, Grafana, Loki, Tempo, Alertmanager (learning) | Local observability education |
| Staging / production | **Not provisioned** | Future managed or dedicated stack |

**Explicit non-installs on Homelab K3s:**

- kube-prometheus-stack  
- Prometheus Operator / Grafana Operator in-cluster  
- Loki, Tempo, full logging/tracing stack  
- Any cloud APM or paid SaaS wired into this demo  

Homelab is **portfolio and GitOps demonstration**. It does **not** claim
production SLAs, 24×7 paging, or multi-region observability.

---

## 2. metrics-server vs Prometheus/Grafana

| Capability | metrics-server (Homelab live) | Prometheus + Grafana (Compose lab) |
|------------|-------------------------------|-------------------------------------|
| CPU/memory snapshots | `kubectl top nodes/pods` | Time-series scrape + dashboards |
| Historical retention | No | Yes (lab retention settings) |
| Alerting rules | No (design-only YAML in Git) | Lab Alertmanager only |
| App RED metrics | No | Requires app instrumentation + scrape |
| Operator workflow | SSH + read-only verify scripts | Browser to `prometheus.local` / `grafana.local` |

Use **metrics-server** for Homelab saturation evidence. Use **Compose** to
practice PromQL and dashboards. Do not assume lab Grafana watches Homelab K3s
unless you deliberately configure remote scrape (not part of this baseline).

---

## 3. One-command baseline

From the operator workstation:

```bash
bash infra/platform/bootstrap/homelab/verify-homelab-observability.sh
```

Overrides:

```bash
K3S_HOST=192.168.152.114 K3S_USER=soloadmin \
  MEM_WARN_PCT=75 MEM_CRIT_PCT=85 \
  CPU_WARN_PCT=70 CPU_CRIT_PCT=85 \
  bash infra/platform/bootstrap/homelab/verify-homelab-observability.sh
```

The script is **read-only**. It never scales, restarts, deletes, patches, or
applies resources. Platform ops companion:

```bash
bash infra/platform/bootstrap/homelab/verify-homelab-platform.sh
```

Offline doc/script guards:

```bash
python3 infra/platform/observability/validate-observability.py
```

---

## 4. SLI definitions (Homelab)

| SLI | How measured | Source |
|-----|--------------|--------|
| **Availability (demo)** | Ingress `/healthz` and `/readyz` return HTTP 200 for portfolio hosts | curl from K3s node with `Host:` header |
| **Health / readiness** | Deployment readyReplicas == desired; container Ready | kubectl |
| **Argo sync health** | Application `status.sync=Synced` and `status.health=Healthy` | Argo CR |
| **Pod restart** | `containerStatuses.restartCount` for demo app pods | kubectl |
| **Resource saturation** | Node CPU% and Memory% from metrics-server | `kubectl top nodes` |
| **Workload resource** | Pod CPU/memory for demo namespaces | `kubectl top pods -A` |
| **Policy signal** | Kyverno PolicyReport fail/error summaries (Audit); NetworkPolicy presence is covered by platform baseline | kubectl |
| **Bad pod states** | Count of CrashLoopBackOff / ImagePullBackOff | kubectl get pods -A |
| **Exposure** | Ingress hosts only `*.homelab.local` / `*.local`; no public LB | kubectl |

Numeric targets: [SLO-SLI-BASELINE.md](SLO-SLI-BASELINE.md).

---

## 5. Incident response (Homelab)

### 5.1 Severity (best-effort)

| Level | Meaning | Example |
|-------|---------|---------|
| Sev-3 | Demo degraded, portfolio only | One app Unhealthy; healthz fails |
| Sev-2 | Node pressure or multi-app impact | Memory ≥ 85%; both apps down |
| Sev-1 | Not defined for Homelab | No production customers on this cluster |

There is **no on-call pager** for Homelab. Treat issues as operator learning
and portfolio hygiene.

### 5.2 Response steps

1. **Confirm blast radius**  
   `bash infra/platform/bootstrap/homelab/verify-homelab-observability.sh`
2. **Classify**  
   - Argo OutOfSync / Degraded  
   - Pod not Ready / restarts  
   - CrashLoop / ImagePull  
   - Node CPU/memory pressure  
   - Ingress non-200  
   - PolicyReport noise (Audit)
3. **Evidence pack** (collect, do not paste secrets):
   ```bash
   ssh soloadmin@192.168.152.114 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   kubectl get nodes -o wide
   kubectl top nodes
   kubectl top pods -A | head -50
   kubectl -n argocd get applications
   kubectl get pods -A | grep -E "CrashLoop|ImagePull|Error|Pending" || true
   kubectl -n apps-ai-doc-assistant-homelab get deploy,pod,ingress
   kubectl -n apps-booknbook-homelab get deploy,pod,ingress
   '
   ```
4. **Remediate within Homelab rules**  
   - Prefer GitOps: fix Git, let Argo self-heal.  
   - Do not force-push broken images as `:latest`.  
   - Do not install full monitoring stacks to “fix” demos.  
   - For DEMO_ONLY data loss after restart: expected for Chroma emptyDir.
5. **Close**  
   Re-run observability + platform verify scripts; note WARN vs FAIL.

### 5.3 Escalation

| If… | Then… |
|-----|--------|
| Single app probe fails | App Homelab runbook (ai-doc / booknbook) |
| Argo cannot sync | Homelab K3s runbook + GitHub deploy key / repo access |
| Node NotReady / OOM | Host capacity; reduce demos; do not add Prometheus stack |
| Needs durable data | Durable data plan — not an observability fix |
| Staging/prod monitoring required | PRODUCTION-GAPS observability exit criteria |

---

## 6. Production observability (later, not now)

When a real staging/production environment is approved:

1. Choose managed Prometheus-compatible metrics **or** a dedicated small stack
   on a **non-demo** cluster (not this single-node Homelab).
2. Wire External Secrets for any remote-write / SaaS credentials (never Git).
3. Install only after capacity review; Homelab RAM is constrained (~69% used).
4. Promote design-only alerts in `infra/platform/observability/alerts/` into
   real PrometheusRule / provider alert policies.
5. Add logs/traces only with retention and cost budgets.

Until then, Compose Lab remains the place to practice Prom/Grafana; Homelab
uses metrics-server + smoke scripts.

---

## 7. Safety checklist

- [ ] No kube-prometheus-stack on Homelab  
- [ ] No real secrets in verify scripts or alert YAML  
- [ ] Verify scripts stay read-only  
- [ ] Demo apps remain infrastructure fixtures (no business feature edits)  
- [ ] No public Internet exposure for Homelab ingress hosts  
