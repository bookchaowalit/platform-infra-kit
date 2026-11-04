# 06 — C4 Container

"Container" ในที่นี้คือส่วนหลักของ repo (ไม่ใช่ process) และ workload ที่ Homelab Argo CD สร้างจากส่วนเหล่านั้น

```mermaid
C4Container
  title Containers - platform-infra-kit
  Person(owner, "Owner / operator")
  System_Boundary(kit, "platform-infra-kit repo") {
    Container(iac, "OpenTofu IaC", "HCL", "envs staging/fsn1 and bootstrap/fsn1, 10 modules, scripts plan/apply/preflight")
    Container(chart, "Helm chart solo-app", "Helm 3", "One app chart, 12 resource templates, homelab values")
    Container(gitops, "GitOps manifests", "Argo CD YAML", "ApplicationSet + catalog, homelab Applications, AppProject, netbox, platform-smoke")
    Container(policies, "Kyverno policies", "ClusterPolicy YAML", "9 policies, all Audit; provenance rules empty")
    Container(onboard, "Onboarding toolkit", "Python 3 + PyYAML", "PilotApp defs, templates, onboard-app.py, app_env.py, validators")
    Container(validators, "Validators and tests", "Python 3 stdlib + PyYAML", "platform_validation_test.py, 2 unittest suites, observability, supply-chain, homelab validators")
    Container(bootstrap, "Bootstrap scripts", "bash", "local k3d and homelab build, push, apply, verify")
    ContainerDb(opsdocs, "Ops docs snapshot", "Markdown", "operations/ copied from solo-empire; read by validators")
  }
  System_Ext(gha, "GitHub Actions")
  System_Boundary(hl, "Homelab K3s") {
    Container(argocd, "Argo CD", "argocd ns", "Applications with selfHeal")
    Container(apps, "ai-doc-assistant, booknbook", "solo-app releases", "apps-*-homelab namespaces")
    Container(smoke, "platform-smoke", "busybox 1.36.1", "Synthetic HTTP smoke")
    Container(netbox, "NetBox + worker", "netbox v4.6.7-5.0.2", "apps-netbox-homelab")
    ContainerDb(pg, "netbox-postgres", "postgres 17-alpine StatefulSet", "PVC 4Gi local-path")
    ContainerDb(valkey, "netbox-redis / redis-cache", "valkey 9.1-alpine", "PVC 1Gi for netbox-redis")
  }
  Rel(owner, onboard, "runs")
  Rel(owner, bootstrap, "runs")
  Rel(owner, iac, "runs plan")
  Rel(gha, validators, "runs")
  Rel(gha, chart, "helm lint, template, kubeconform")
  Rel(gha, iac, "plan-staging.sh")
  Rel(validators, opsdocs, "reads")
  Rel(validators, onboard, "subprocess")
  Rel(argocd, chart, "renders from main")
  Rel(argocd, gitops, "syncs netbox and platform-smoke paths")
  Rel(argocd, apps, "deploys")
  Rel(argocd, netbox, "deploys")
  Rel(argocd, smoke, "deploys")
  Rel(netbox, pg, "5432")
  Rel(netbox, valkey, "6379")
```

Sources: repo tree (`find . -type f`), `infra/platform/helm/solo-app/templates/`, `infra/platform/gitops/**`, `infra/platform/policies/kyverno/*.yaml`, `infra/platform/onboarding/`, `infra/tests/platform/`, `infra/platform/iac/modules/`, `infra/platform/iac/envs/`, `infra/platform/gitops/homelab/netbox/*.yaml`, `infra/platform/gitops/homelab/platform-smoke/deployment.yaml`, `README.md` (operations snapshot)

IaC: modules 10 โฟลเดอร์ (`cost, database, dns, k3s-cluster, monitoring, network, node-pools, object-storage, registry, secrets`) และ env roots 2 ชุด (`bootstrap/fsn1`, `staging/fsn1`) + `production/README.md` (disabled)

## Open questions

- `operations/` ถือเป็น data ของ validator; ถ้าต้นฉบับใน solo-empire เปลี่ยน สำเนานี้ไม่อัปเดตเอง (README "แก้ทั้งสองที่")
