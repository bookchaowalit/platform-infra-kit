---
title: "Supply-chain security baseline"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-08-08
description: "Documentation for Supply-chain security baseline."
---

# Supply-chain security baseline

This directory describes the image supply-chain boundary for Solo Empire
platform workloads. It is a DevSecOps control for the demo and future staging
paths; it does not publish images or contain registry credentials.

## Current controls

- Application images use immutable `git-<commit-sha>` tags; `:latest` is not
  allowed in Kubernetes platform manifests.
- The Homelab registry uses private TLS and authentication.
- CI runs platform secret scans, Trivy configuration scanning, Helm rendering,
  Kubernetes schema checks, and data/onboarding guards.
- Kyverno has an image-provenance placeholder, but signature enforcement is not
  enabled yet.
- Homelab demo workloads are allowed to run unsigned images only because they
  are private portfolio workloads, not production workloads.

## Promotion levels

| Environment | Image requirement | Signing state | Decision |
|-------------|-------------------|---------------|----------|
| Local Docker/k3d | Git-SHA preferred | Not required | Learning/pilot |
| Homelab | Git-SHA required | Audit/placeholder | Portfolio demo |
| Staging | Git-SHA or digest | Cosign/Sigstore required before enablement | Blocked |
| Production | Digest + verified signature + SBOM/provenance | Enforced admission | Not implemented |

## CI contract

Run the offline policy guard:

```bash
python3 infra/platform/supply-chain/validate-image-policy.py
```

The guard checks image reference policy, `:latest` absence, staging
deployment gates, secret-like assignments, and that signature enforcement is
not falsely documented as active.

The CI workflow may later add a build job for each application repository. A
build job must produce, in order:

1. an immutable image tag and digest;
2. an SBOM artifact;
3. a vulnerability scan result with the approved severity threshold;
4. a Cosign signature and provenance attestation;
5. registry push only after all checks pass.

No private key, OIDC token, registry password, or signed artifact belongs in
this repository.

## Enablement gate

Before staging is enabled, the owner must choose keyless Sigstore/OIDC or a
managed Cosign key, publish the verification identity/key through a protected
cluster configuration, run one audit window, and then change Kyverno from
placeholder/Audit to an approved verification policy. This is a separate
reviewed change from the current Homelab demo deployment.
