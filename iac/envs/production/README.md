# Production IaC root — **DISABLED**

Production infrastructure is **not implemented** in this phase.

| Rule | Value |
|------|--------|
| Provisioning | Forbidden from this directory |
| Multi-cloud | Forbidden |
| Staging first | Use `envs/staging/fsn1` only |

When production is authorized later:

1. Complete staging restore drills and 30-day cost baseline
2. Prefer **managed Kubernetes** (PROVIDER-DECISION production path)
3. Create `envs/production/<region>/` as a **new** root (do not reuse staging state)
4. Keep `provision = false` until human approval

Do **not** run `tofu apply` here. There is no root module on purpose.
