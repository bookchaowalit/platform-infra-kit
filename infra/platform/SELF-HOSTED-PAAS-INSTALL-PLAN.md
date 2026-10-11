---
title: "Self-hosted PaaS Installation Plan"
tags: [infra, self-hosted, paas, readiness]
created: 2026-08-23
updated: 2026-08-23
description: "Approval-gated plan for adding Coolify, CapRover, or Dokku without colliding with the existing lab."
---

# Self-hosted PaaS Installation Plan

## Decision

Do **not** install Coolify, CapRover, or Dokku on the current Solo Empire host
in-place. The host already runs the Docker/K3s learning stack and has existing
listeners on shared entry ports. A self-hosted PaaS should use a fresh,
isolated VM or server with its own DNS, firewall, backups, and rollback plan.

The repository now provides a read-only preflight:

```bash
task selfhosted:readiness
task selfhosted:readiness:coolify
task selfhosted:readiness:caprover
task selfhosted:readiness:dokku
```

The preflight never installs packages, changes firewall rules, modifies DNS,
creates containers, applies Kubernetes resources, or writes provider state.

Use [`SELF-HOSTED-PAAS-TARGET.example.yaml`](./SELF-HOSTED-PAAS-TARGET.example.yaml)
as the non-secret intake template. Keep the filled copy outside Git.

## Current local blocker evidence

The current host has existing workloads and shared listeners on at least TCP
`22`, `80`, `443`, and `3000`. These are required or commonly used during the
initial setup of the candidate platforms, so changing or stopping the current
services would be unsafe without a separate migration decision.

The current local runtime remains a portfolio/lab boundary:

- Docker Compose services are a local learning stack.
- K3s/k3d is a disposable local cluster.
- No public production ingress or customer SLA is established here.

## Candidate comparison

| Candidate | Current preflight ports | Isolation decision |
|---|---:|---|
| Coolify | `22`, `80`, `443`, `6001`, `6002`, `8000` | Fresh VM/server; do not share the current Docker host |
| CapRover | `80`, `443`, `3000`, `996` | Fresh VM/server; keep Swarm ports private to trusted nodes |
| Dokku | `22`, `80`, `443` | Fresh Debian/Ubuntu server; reserve SSH and web ingress |

The port lists and minimum requirements are based on the providers’ official
documentation and must be rechecked immediately before installation:

- [Coolify installation](https://coolify.io/docs/get-started/installation) and
  [firewall](https://coolify.io/docs/knowledge-base/server/firewall)
- [CapRover firewall](https://caprover.com/docs/firewall.html)
- [Dokku installation](https://dokku.com/docs/getting-started/installation/)

## Approval gate for a real installation

Before any install command is run, record these choices:

1. Target host: fresh VM/server identifier and provider.
2. Platform: one of Coolify, CapRover, or Dokku.
3. DNS/domain and certificate strategy.
4. SSH user, allowed source CIDRs, and recovery console access.
5. Backup destination, retention, and restore test.
6. Monthly budget and resource limit.
7. Whether the platform is a lab, staging, or production boundary.

Only after those values are approved should an operator run the provider’s
official installation procedure. The dashboard’s action gate remains disabled
and this repository will not execute a remote install implicitly.
