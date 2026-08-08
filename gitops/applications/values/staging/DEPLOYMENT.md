---
title: "Staging deployment gate"
tags: [documentation, infra]
created: 2026-08-02
updated: 2026-08-08
description: "Documentation for Staging deployment gate."
---

# Staging deployment gate

**Status: DISABLED by default**

This directory holds staging-ready Helm values only. It does **not** deploy.

## Rules

1. `soloEmpire.deploymentEnabled: false` must remain on every pilot staging
   values file until a human enablement change is approved.
2. No Argo CD Application for `*-staging` is applied from local bootstrap.
3. ApplicationSet generators for `staging` / `production` stay inactive until
   a real cluster and secret store exist (see `applicationset.yaml` comments).
4. No real secrets, production hostnames, or live registry credentials in Git.
5. No cloud resources are provisioned by adding these files.

## Enablement checklist (manual, future)

- [ ] Provider decision accepted (`operations/PROVIDER-DECISION.md`)
- [ ] Environment contract gates for staging satisfied
- [ ] Managed data provisioned **outside** the app chart (Postgres, vector, S3)
- [ ] ai-doc-assistant durable plan gates satisfied
      (`operations/AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md`)
- [ ] Backup/PITR + restore drill logged
      (`operations/STAGING-DATA-BACKUP-RESTORE.md`)
- [ ] Staging values: no emptyDir for chroma/uploads; ESO refs present
- [ ] External Secrets ClusterSecretStore live
- [ ] Image repository points at real shared registry with immutable tags
- [ ] Ingress DNS + TLS issuer ready
- [ ] Offline: `python3 infra/platform/onboarding/scripts/validate-data-contract.py`
- [ ] Flip `soloEmpire.deploymentEnabled: true` in a dedicated PR
- [ ] Register Argo Application / enable ApplicationSet staging generator

**Homelab** stays DEMO_ONLY and is not enabled via this directory.

## Namespaces (target, not created here)

| App | Staging namespace |
|-----|-------------------|
| ai-doc-assistant | `apps-ai-doc-assistant-staging` |
| booknbook | `apps-booknbook-staging` |
