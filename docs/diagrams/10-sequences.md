# 10 — Sequences

ไม่มี HTTP request path ของ repo เอง จึงเลือก 4 เส้นทางที่สำคัญที่สุดของ kit: local deploy, Homelab release, CI validation และ staging apply gate

## 1. `deploy-app.sh <name>` (local k3d dev)

```mermaid
sequenceDiagram
  actor Op as Operator
  participant D as deploy-app.sh
  participant E as app_env.py
  participant R as k3d-solo-registry
  participant G as Local Git source
  participant K as k3d-solo-dev kubectl
  participant A as Argo CD
  Op->>D: bash deploy-app.sh NAME
  D->>E: python3 app_env.py NAME
  E-->>D: export APP_* (namespace apps-NAME-dev, argo NAME-dev)
  D->>D: check APP_DIR, Dockerfile, values/dev/NAME.yaml, Argo template
  D->>D: IMAGE_TAG = git-HEAD SHA, refuse latest, 0.1.0-local, git-pending
  D->>R: create-registry.sh, docker build, docker push
  D->>D: write helm/solo-app/pilot/NAME-dev.yaml with repo and tag
  D->>G: start-local-git-source.sh unless remote ARGOCD_REPO_URL
  D->>K: kubectl apply argocd-apps-project.yaml and NAME-dev.yaml
  opt git or http repo URL
    D->>K: apply repository Secret repo-solo-empire-local-pilot insecure true
  end
  loop until Synced and Healthy or timeout
    D->>K: get application sync and health
    D->>A: annotate refresh=hard
  end
  A->>K: render solo-app and apply in apps-NAME-dev
```

Sources: `infra/platform/bootstrap/local/deploy-app.sh`, `infra/platform/onboarding/scripts/app_env.py`, `infra/platform/bootstrap/local/create-registry.sh`, `infra/platform/bootstrap/local/start-local-git-source.sh`

## 2. Homelab release of booknbook

```mermaid
sequenceDiagram
  actor Op as Operator workstation
  participant BP as build-push-booknbook.sh
  participant REG as registry.homelab.local:5000
  participant AP as apply-booknbook-application.sh
  participant K3S as K3s node via SSH
  participant AR as Argo CD
  participant GH as GitHub platform-infra-kit main
  Op->>BP: SOLO_BOOK_DEV_ROOT=... bash build-push-booknbook.sh
  BP->>BP: TAG = git-SHA of app repo
  BP->>REG: docker build and push solo-empire/booknbook:TAG
  BP-->>Op: IMAGE_TAG=TAG
  Op->>GH: edit Application image.tag to TAG and push (apply script only replaces git-pending)
  Op->>AP: run with IMAGE_TAG
  AP->>AP: sed git-pending to IMAGE_TAG on a temp copy
  AP->>K3S: scp AppProject, approved-registries, Application
  AP->>K3S: kubectl apply all three
  AR->>GH: fetch infra/platform/helm/solo-app at main over SSH deploy key
  AR->>K3S: apply release in apps-booknbook-homelab, selfHeal
  K3S->>REG: pull image by TAG
```

Sources: `infra/platform/bootstrap/homelab/build-push-booknbook.sh`, `infra/platform/bootstrap/homelab/apply-booknbook-application.sh`, `infra/platform/gitops/homelab/applications/booknbook-homelab.yaml`, `infra/platform/gitops/homelab/README.md`

## 3. Pull request validation

```mermaid
sequenceDiagram
  participant Dev as Author
  participant GH as GitHub
  participant CI as ci.yml
  participant PV as platform-validate.yml
  participant SC as platform-ci-workflows 87dc5e1c
  Dev->>GH: open PR or push main
  GH->>CI: trigger push main, pull_request, workflow_dispatch
  CI->>SC: validators ci-python.yml with pyyaml 6.0.3 and 3 suites
  CI->>SC: security security.yml gitleaks, semgrep, osv-scanner, trivy-fs
  alt changed path under infra/platform or validation test or the workflow
    GH->>PV: trigger
    PV->>PV: python guards, helm lint and template, Trivy config, secret and latest scan, supply-chain, tofu plan provision=false
    PV->>PV: kubeconform after helm job
  end
  CI-->>GH: status checks
  PV-->>GH: status checks
```

Sources: `.github/workflows/ci.yml`, `.github/workflows/platform-validate.yml`, `platform-ci-workflows` `.github/workflows/ci-python.yml` and `security.yml` at `87dc5e1c`

## 4. Staging apply gate (`apply-staging.sh`)

```mermaid
sequenceDiagram
  actor Op as Operator
  participant AS as apply-staging.sh
  participant PF as preflight-staging.sh
  participant T as tofu
  participant HZ as Hetzner Cloud API
  Op->>AS: PREFLIGHT_PROVISION=1 ... apply-staging.sh plan
  AS->>AS: require PREFLIGHT_PROVISION=1
  AS->>PF: preflight
  AS->>AS: require backend.tf s3, backend.hcl encrypt=true and lockfile
  AS->>AS: refuse local terraform.tfstate
  AS->>AS: pass ALLOW_SSH_CIDRS and SSH_KEY_IDS as -var lists
  AS->>T: tofu plan provision=true -out PLAN_FILE
  Op->>AS: apply-staging.sh apply
  AS->>Op: prompt Type APPLY-STAGING-FSN1
  Op-->>AS: confirmation text
  AS->>T: tofu apply PLAN_FILE
  T->>HZ: create network, firewalls, servers, volumes
```

Sources: `infra/platform/iac/scripts/apply-staging.sh`, `infra/platform/iac/scripts/preflight-staging.sh`, `infra/platform/iac/envs/staging/fsn1/main.tf`

การบังคับว่าต้องมี SSH CIDR/keys อยู่ใน `check` blocks ของ `main.tf` ซึ่งตามความหมายของ OpenTofu `check` แสดงผลเป็น warning ไม่หยุด plan/apply (ดู gap ใน [13](13-threat-model.md))

ขั้น "tofu apply" ยังไม่เคยเกิดขึ้น (PRODUCT.md, PRODUCTION-GAPS "not provisioned")

## Open questions

- ไม่มี
