# 05 — C4 Context

ระบบในภาพคือ "platform-infra-kit" (Git repo ของ desired state + validators) และสิ่งที่อ่าน/เขียนมัน

```mermaid
C4Context
  title System Context - platform-infra-kit
  Person(owner, "Owner / operator", "Edits Git, runs bootstrap and verify scripts from a workstation")
  Person(agent, "Maintainer AI agent", "Edits files and runs offline validators")
  System(kit, "platform-infra-kit", "GitHub repo bookchaowalit/platform-infra-kit: OpenTofu, Argo CD apps, Helm chart solo-app, Kyverno, onboarding, validators")
  System_Ext(gha, "GitHub Actions", "ci.yml and platform-validate.yml on GitHub-hosted runners")
  System_Ext(sharedci, "platform-ci-workflows", "Reusable ci-python.yml and security.yml pinned at 87dc5e1c v1.1.1")
  System_Ext(renovate, "Renovate", "Dependency update PRs")
  System_Ext(homelab, "Homelab K3s", "Single node solo-k3s-server-01 with Argo CD, Kyverno, ESO, cert-manager, metrics-server")
  System_Ext(registry, "Homelab registry", "registry.homelab.local:5000 on Fedora host, TLS + htpasswd")
  System_Ext(k3d, "Local k3d cluster", "k3d-solo-dev with k3d-solo-registry, disposable")
  System_Ext(hetzner, "Hetzner Cloud fsn1", "Staging target, not provisioned")
  System_Ext(apprepos, "App source repos", "ai-doc-assistant and booknbook Dockerfiles")

  Rel(owner, kit, "commits, PRs")
  Rel(agent, kit, "commits, validators")
  Rel(gha, kit, "checks out and validates")
  Rel(gha, sharedci, "calls reusable workflows")
  Rel(renovate, kit, "opens PRs")
  Rel(homelab, kit, "Argo CD pulls main over SSH")
  Rel(owner, registry, "docker push git-SHA images")
  Rel(homelab, registry, "pulls images")
  Rel(owner, homelab, "ssh + kubectl apply Applications, verify scripts")
  Rel(owner, k3d, "deploy-app.sh")
  Rel(owner, apprepos, "builds images from")
  Rel(owner, hetzner, "tofu apply only after typed approval, never done")
```

Sources: `PRODUCT.md`, `.github/workflows/ci.yml`, `.github/workflows/platform-validate.yml`, `renovate.json`, `infra/platform/gitops/homelab/applications/*.yaml`, `infra/platform/gitops/homelab/README.md`, `infra/platform/bootstrap/homelab/README.md`, `infra/platform/bootstrap/local/create-cluster.sh`, `infra/platform/bootstrap/local/install-platform.sh`, `infra/platform/iac/envs/staging/fsn1/versions.tf`, `infra/platform/iac/scripts/apply-staging.sh`

ข้อสังเกต
- Homelab controllers (Kyverno, ESO, cert-manager, metrics-server) มาจาก `operations/platform/HOMELAB-URL-CATALOG.md` ("Controllers … kubectl only") และ `HOMELAB-OBSERVABILITY-RUNBOOK.md` — การติดตั้งบน Homelab ไม่มี script ใน repo นี้ (`install-platform.sh` เป็นของ local k3d)
- Registry อยู่บน Fedora `192.168.152.12`, K3s อยู่ที่ `192.168.152.114` (`bootstrap/homelab/README.md`)
- solo-empire ยังเป็นเจ้าของ registry ไฟล์บางชุด (`cloud-providers.yaml`, `paas-action-policy.json` ฯลฯ) ตาม `README.md`; `infra/platform/README.md` ยังบรรยาย Multi-PaaS control plane (`task paas:*`, `scripts/platform/paas_health.py`) ที่ **ไม่มีอยู่ใน repo นี้**

## Open questions

- Homelab Argo CD sync จาก repo นี้แล้วจริงหรือไม่ (README: "ยังไม่ได้ apply กับ cluster; ต้อง sync เองหลัง merge")
