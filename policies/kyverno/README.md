---
title: "Kyverno security policies"
tags: [documentation, infra]
created: 2026-08-03
updated: 2026-08-08
description: "Documentation for Kyverno security policies."
---

# Kyverno security policies

All policies in this directory start in **`validationFailureAction: Audit`**.

Audit mode reports violations without blocking workloads. Use this until existing
and planned workloads are compliant, then switch to **Enforce** per policy.

## Policies

| File | Rule |
|------|------|
| `disallow-latest-tag.yaml` | No `:latest` image tags |
| `approved-registries.yaml` | Images only from approved registries |
| `require-non-root.yaml` | Containers must not run as root |
| `require-labels.yaml` | Required app/team/environment labels |
| `require-resources.yaml` | CPU and memory requests mandatory |
| `disallow-privileged.yaml` | Privileged containers denied |
| `disallow-host-namespaces.yaml` | HostNetwork, HostPID, HostPath denied by default |
| `require-readonly-rootfs.yaml` | Prefer read-only root filesystem |
| `image-provenance-placeholder.yaml` | Signature/attestation hooks (disabled until Cosign ready) |

## Moving Audit → Enforce

1. Install Kyverno on a non-production cluster.
2. Apply policies (Audit).
3. Review Policy Reports / ClusterPolicyReport for 1–2 sprints.
4. Fix failing workloads (chart defaults already aim for compliance).
5. Change `validationFailureAction: Audit` → `Enforce` **one policy at a time**.
6. Keep a break-glass ClusterPolicy exception process for platform namespaces
   (`kube-system`, `kyverno`, `argocd`) using `exclude` blocks already present.

```bash
# Example: promote a single policy
sed -i 's/validationFailureAction: Audit/validationFailureAction: Enforce/' \
  infra/platform/policies/kyverno/require-non-root.yaml
# Review the diff, PR, then apply via GitOps — do not kubectl apply ad-hoc to prod.
```

## Scope

Policies target namespaced workloads (`Deployment`, `StatefulSet`, `DaemonSet`,
`Job`, `CronJob`, `Pod`). Platform namespaces are excluded where host access is
unavoidable (e.g. node agents).
