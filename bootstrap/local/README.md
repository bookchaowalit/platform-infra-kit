# Local Kubernetes Platform Bootstrap

This bootstrap creates a disposable local Kubernetes environment for validating
the Solo Empire platform. It does not deploy business applications, provision
cloud resources, or create production secrets.

## Quick start

```bash
cd infra/platform/bootstrap/local
./install-tools.sh
export PATH="$HOME/.local/bin:$PATH"
./create-cluster.sh
./install-platform.sh
```

The cluster is named `solo-dev`. Ingress uses host ports `18080` and `18443`,
so it does not conflict with the Docker Compose lab on ports `80` and `443`.

By default `create-cluster.sh` also creates a **disposable local registry**
(`k3d-solo-registry` on host port `5111`) via `create-registry.sh`. Set
`CREATE_REGISTRY=false` to skip. For an existing cluster, run
`./create-registry.sh` any time.

The default install includes Argo CD, cert-manager, Kyverno, External Secrets
Operator, and metrics-server. Set `INSTALL_OBSERVABILITY=true` only if a second
Prometheus/Grafana stack inside Kubernetes is wanted; the Docker lab already
provides local observability.

### Pilot applications (reproducible, multi-app)

```bash
cp -n pilot.env.example pilot.env   # gitignored; no secrets
./deploy-app.sh ai-doc-assistant    # first pilot
./deploy-app.sh booknbook           # second pilot
# wrappers still work:
./deploy-pilot.sh
./deploy-booknbook.sh
```

Onboarding templates, definitions, and offline guards live under
[`infra/platform/onboarding/`](../../onboarding/README.md).

Argo CD Application source is a **configurable Git URL + revision** (local
git-daemon snapshot by default, or remote HTTPS). The old `file:///workspace`
mount path is not used.

See:

- [AI-DOC-ASSISTANT-PILOT-RUNBOOK.md](../../../../docs/operations/AI-DOC-ASSISTANT-PILOT-RUNBOOK.md)
- [BOOKNBOOK-PILOT-RUNBOOK.md](../../../../docs/operations/BOOKNBOOK-PILOT-RUNBOOK.md)

### Dual-pilot regression + booknbook smoke

```bash
./verify-pilots-regression.sh   # both apps: Argo, Ready, probes, NetworkPolicy
./smoke-booknbook.sh            # homepage, locale, static assets, probes not redirected
```

### Pilot resilience checks (per app)

```bash
./verify-pilot-resilience.sh
NS=apps-booknbook-dev APP=booknbook ARGO_APP=booknbook-dev ./verify-pilot-resilience.sh
```

Covers restart, scale, self-heal, rollback, dummy secret rotation, NetworkPolicy
deny, and (for ai-doc) Chroma emptyDir data loss. Decision record:
[AI-DOC-ASSISTANT-DATA-DECISION.md](../../../../docs/operations/AI-DOC-ASSISTANT-DATA-DECISION.md).

Apply the local audit policies and platform boundary after installation:

```bash
./apply-boundaries.sh
./test-external-secrets.sh
```

## Verify and access

```bash
kubectl config use-context k3d-solo-dev
kubectl get nodes
kubectl get pods -A
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open Argo CD at `https://127.0.0.1:8080`. The initial admin password remains in
the Kubernetes Secret and is never printed by these scripts.

Remove only this disposable cluster with:

```bash
k3d cluster delete solo-dev
```

No business app is installed by this bootstrap, and no app is added to the
deployable Argo CD catalog.
