# Pilot runbook: __APP_NAME__

Local k3d-only pilot using the Solo Empire platform onboarding workflow
(solo-app chart, local registry, Git source, Argo CD, NetworkPolicy).

## Runtime

| Field | Value |
|-------|--------|
| App | **__APP_NAME__** |
| Source | `__SOURCE_PATH__` |
| Image | `k3d-solo-registry:5000/__IMAGE_NAME__:git-<fullsha>` |
| Namespace | `apps-__APP_NAME__-dev` |
| Argo CD Application | `__APP_NAME__-dev` |
| Ingress | `__INGRESS_HOSTNAME__` → host port **18080** |
| Health | `GET __LIVENESS_PATH__`, `GET __READINESS_PATH__` |
| Data contract | `__DATA_CONTRACT__` |
| Team | `__TEAM__` |

## Deploy

```bash
export PATH="$HOME/.local/bin:$PATH"
kubectl config use-context k3d-solo-dev
bash infra/platform/bootstrap/local/deploy-app.sh __APP_NAME__
```

## Verify

```bash
kubectl -n argocd get application __APP_NAME__-dev
kubectl -n apps-__APP_NAME__-dev get pods,networkpolicy
curl -sS -H 'Host: __INGRESS_HOSTNAME__' http://127.0.0.1:18080__LIVENESS_PATH__
curl -sS -H 'Host: __INGRESS_HOSTNAME__' http://127.0.0.1:18080__READINESS_PATH__

# Dual-pilot regression
bash infra/platform/bootstrap/local/verify-pilots-regression.sh

# Resilience suite
NS=apps-__APP_NAME__-dev APP=__APP_NAME__ ARGO_APP=__APP_NAME__-dev \
  bash infra/platform/bootstrap/local/verify-pilot-resilience.sh
```

## Secrets

No real secrets in Git. Optional dummy Secret only for local demos.
Prefer ExternalSecret when a ClusterSecretStore exists.

## Data / database

- **No PostgreSQL/Redis in the application chart**
- Data dependencies must be declared in the inventory `data_contract`
- See `infra/platform/DATA-CONTRACT.md`

## Non-goals

No cloud/production, no Compose changes, no real production credentials, no commit/push
unless explicitly requested.
