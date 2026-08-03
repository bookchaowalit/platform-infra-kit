# Homelab / platform alert designs (design-only)

**Status:** Design documentation only  
**Do not apply** these manifests to Homelab K3s unless Prometheus Operator /
PrometheusRule CRDs are intentionally installed on a **non-demo** cluster.

## Why design-only?

Homelab observability baseline uses **metrics-server** and read-only verify
scripts. Docker Compose Lab may run Prometheus/Alertmanager for learning, but
that stack is **not** the Homelab GitOps desired state.

Installing kube-prometheus-stack on the single-node Homelab is **out of scope**
(memory pressure, portfolio-only).

## Files

| File | Purpose |
|------|---------|
| `homelab-alerts.yaml` | Example PrometheusRule-shaped definitions for future use |

## Alert catalog

| Alert | Intent | Homelab signal today |
|-------|--------|----------------------|
| ArgoApplicationDegraded | Sync/Health not Synced+Healthy | `verify-homelab-observability.sh` |
| PodUnavailable | readyReplicas &lt; desired | same |
| PodRestartIncrease | restarts rising | restartCount baseline |
| CrashLoopBackOff | container crash loop | pod phase grep |
| ImagePullBackOff | image pull failure | pod phase grep |
| NodeMemoryPressure | memory ≥ warn/crit | `kubectl top nodes` |
| NodeCPUSaturation | CPU ≥ warn/crit | `kubectl top nodes` |
| IngressHigh5xx | elevated 5xx | not scraped yet (design) |
| CertificateExpirySoon | TLS cert &lt; 14 days | design (Homelab often HTTP LAN) |

## Promotion path (staging/prod later)

1. Provision metrics stack **outside** Homelab demo node (or managed service).  
2. Ensure PrometheusRule CRD exists.  
3. Review thresholds against real capacity.  
4. Apply via GitOps with External Secrets for notification channels.  
5. Never commit webhook URLs, SMTP passwords, or PagerDuty keys.

## Safety

- No secrets in this directory  
- No `:latest` images  
- No `kubectl apply` of these files in Homelab bootstrap scripts  
