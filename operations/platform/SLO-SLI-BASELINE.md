---
title: SLO / SLI baseline (Homelab portfolio)
status: evidence
tags: [evidence, operations]
updated: 2026-08-04
---

# SLO / SLI baseline (Homelab portfolio)

**Status:** Practical Homelab targets only — **no production SLA claim**  
**Last updated:** 2026-08-02  
**Measurement:** read-only scripts + metrics-server (+ Argo / probes)

Related: [HOMELAB-OBSERVABILITY-RUNBOOK.md](HOMELAB-OBSERVABILITY-RUNBOOK.md)

---

## 1. Scope and non-claims

| In scope | Out of scope |
|----------|--------------|
| Homelab K3s portfolio apps (`ai-doc-assistant`, `booknbook`) | Customer production SLA |
| Verification-time SLIs (operator runs script) | Continuous multi-region availability |
| Best-effort monthly demo availability | Contractual uptime credits |
| metrics-server saturation thresholds | Full RED/USE with Prometheus (lab only) |

**No production SLA** is offered for Homelab. Targets guide operator hygiene
and portfolio demos only.

---

## 2. SLI catalog

| ID | SLI | Measurement | Unit |
|----|-----|-------------|------|
| SLI-HEALTH | Health/readiness smoke | Ingress `/healthz` + `/readyz` HTTP status | success ratio |
| SLI-ARGO | GitOps health | Argo Application sync + health | boolean pair |
| SLI-READY | Pod readiness | container Ready + deploy readyReplicas | boolean |
| SLI-RESTART | Unexpected restarts | restartCount during baseline window | count |
| SLI-CRASH | Crash / pull errors | CrashLoopBackOff / ImagePullBackOff | count |
| SLI-MEM | Node memory saturation | metrics-server memory % | percent |
| SLI-CPU | Node CPU saturation | metrics-server CPU % | percent |
| SLI-POLICY | Policy signal | Kyverno PolicyReport fail/error | count |
| SLI-EXPOSE | Exposure control | private Ingress hosts; no public LB IP | boolean |

---

## 3. SLO targets (Homelab)

| SLO | Target | Window | Severity if breached |
|-----|--------|--------|----------------------|
| Healthz/readyz smoke success | **100%** of checked paths during verification | Per verify run | FAIL script |
| Argo applications | **Synced + Healthy** for portfolio apps | Per verify run | FAIL script |
| Unexpected restarts | **0** during baseline | Per verify run | FAIL if restartCount ≠ 0 |
| CrashLoopBackOff / ImagePullBackOff | **0** cluster-wide (demo host) | Per verify run | FAIL script |
| Node memory | **&lt; 75%** warn · **≥ 85%** critical | Continuous snapshot | WARN / FAIL |
| Node CPU | **&lt; 70%** warn · **≥ 85%** critical | Continuous snapshot | WARN / FAIL |
| Demo availability (best-effort) | **99%** monthly | Calendar month (manual log) | Operator review only |
| Production SLA | **None** | — | Not claimed |

### Notes on thresholds

- Homelab single-node often runs near **~70% memory** with Argo + demos.  
  Warn at 75% encourages capacity discipline; critical at 85% is FAIL.  
- Monthly 99% is a **personal portfolio goal**, not a measured SaaS SLO with
  multi-probe synthetic monitoring.

---

## 4. Error budget (lightweight)

| Concept | Homelab practice |
|---------|------------------|
| Budget | ~7.2 hours unavailability / month for 99% best-effort |
| Tracking | Optional operator log when verify scripts FAIL |
| Burn | Do not add workloads if memory regularly ≥ 75% |
| Freeze | Prefer not to onboard more apps when node is critical |

---

## 5. Mapping to verification

```bash
bash infra/platform/bootstrap/homelab/verify-homelab-observability.sh
```

| Script outcome | Interpretation |
|----------------|----------------|
| PASS | SLI checks met for this snapshot |
| WARN | Soft threshold (e.g. memory 75–84%); still exit 0 |
| FAIL | Hard breach (critical saturation, Argo unhealthy, restarts, bad pods) |
| SKIP | Optional signal missing (e.g. PolicyReport CRD) |

---

## 6. Staging / production future targets (not Homelab)

When staging is enabled (separate environment):

| Area | Directional target |
|------|--------------------|
| Availability | ≥ 99.5% monthly with synthetic probes |
| Latency | p95 health endpoints &lt; 300 ms (region local) |
| Deploy health | Argo Healthy within 10 minutes of sync |
| Restore | RTO/RPO per STAGING-DATA-BACKUP-RESTORE |
| Alerting | Real pages via managed stack — not Homelab metrics-server |

These are **design goals** until provisioned and measured with Prometheus or
an equivalent production-grade system.
