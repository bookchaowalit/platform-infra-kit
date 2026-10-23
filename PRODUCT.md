# Product: platform-kit (platform-infra-kit)

## What it is

A repository of platform assets for the owner's homelab and a planned self-hosted PaaS:
OpenTofu modules and environments (`infra/platform/iac/`), Argo CD GitOps applications, the
Helm chart `solo-app`, Kyverno policies, an app onboarding workflow (PilotApp YAML →
`app_env.py` / `onboard-app.py`), observability config, a supply-chain policy, and
bootstrap scripts for homelab and local k3d clusters. It deploys nothing by itself.

## Who it is for

The owner and the agents that maintain the owner's infrastructure. No external users.

## What works today

- Offline validators: platform validation (432 checks), onboarding, observability, image
  supply-chain policy, homelab URL catalog and multi-node readiness.
- Three Python test suites in `infra/tests/platform/` (platform validation, git file modes,
  onboarding helpers) run in the shared CI `platform-ci-workflows` v1.1.1 with Ruff and a
  security scan; `platform-validate.yml` adds Helm, kubeconform, OpenTofu and supply-chain checks.

## Limits

- Nothing here has been applied to a cluster from CI; homelab Argo CD apps must be synced by hand.
- The staging environment (`iac/envs/staging/fsn1`) is a plan: staging deployment stays
  disabled and image signature enforcement is an honest placeholder (`rules: []`).
- `operations/` holds snapshot copies of docs that the validators read; the originals live in
  solo-empire, so both must be edited until one owner is chosen.
- A separate open pull request (shared-service delivery, D8) is not part of `main` and is not
  described here.

## Status

Active infrastructure kit, validated offline only. No runtime of its own, so no Sentry.
