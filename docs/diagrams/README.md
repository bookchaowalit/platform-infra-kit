# Core 22 SDLC diagram pack — platform-infra-kit

ชุดภาพ Core 22 ตาม SDLC Diagram Catalog v2 วาดจากไฟล์ใน repo นี้ (ณ `origin/main` `f80262a`, 2026-10-23; อ่านเมื่อ 2026-11-04)

repo นี้เป็น **tooling / infra kit** ไม่ใช่ service: เก็บ OpenTofu (`infra/platform/iac/`), Argo CD GitOps, Helm chart `solo-app`, Kyverno policies, onboarding workflow, observability design, supply-chain policy และ bootstrap scripts สำหรับ local k3d กับ Homelab K3s ([PRODUCT.md](../../PRODUCT.md)) — "It deploys nothing by itself"
ดังนั้นในชุดนี้ "actor" คือ owner/agent, CI และ Argo CD ที่อ่าน repo; "runtime" คือ cluster ที่ Argo CD sync จาก repo นี้ (Homelab) ไม่ใช่ process ของ repo เอง

ทุกไฟล์มี `Sources:` ใต้ภาพ และ "Open questions" สำหรับสิ่งที่ยืนยันจากไฟล์ไม่ได้ สิ่งที่ยังไม่ทำจริงระบุเป็น **gap**

| # | Item | Status | File | Sources read |
|---|---|---|---|---|
| 01 | Business process As-Is / To-Be | done | [01-business-process.md](01-business-process.md) | `PRODUCT.md`, `README.md`, `infra/platform/onboarding/README.md`, `bootstrap/*/README.md`, `operations/platform/PRODUCTION-GAPS.md` |
| 02 | Use cases | done | [02-use-cases.md](02-use-cases.md) | `PRODUCT.md`, workflows, bootstrap scripts, `iac/scripts/*.sh`, `renovate.json` |
| 03 | User flows (operator) | done | [03-user-flows.md](03-user-flows.md) | `onboarding/README.md`, `bootstrap/local/deploy-app.sh`, `bootstrap/homelab/README.md`, `iac/README.md` |
| 04 | Traceability (RTM) | done | [04-traceability.md](04-traceability.md) | `PRODUCT.md`, `DATA-CONTRACT.md`, `ENVIRONMENT-CONTRACT.md`, `infra/tests/platform/*.py`, workflows |
| 05 | C4 Context | done | [05-c4-context.md](05-c4-context.md) | `PRODUCT.md`, homelab Applications, `iac/envs/staging/fsn1/*`, workflows |
| 06 | C4 Container | done | [06-c4-container.md](06-c4-container.md) | repo tree, `helm/solo-app/`, `gitops/`, `iac/`, `onboarding/` |
| 07 | C4 Component | done | [07-c4-component.md](07-c4-component.md) | validators and tests under `infra/` |
| 08 | ADRs | done (4, retro) | [08-adr/](08-adr/) | `PROVIDER-DECISION.md`, `iac/README.md`, `helm/solo-app/`, homelab Applications, `DATA-CONTRACT.md`, workflows |
| 09 | ERD / data model | done (config schema + NetBox stores) | [09-erd.md](09-erd.md) | `onboarding/apps/*.yaml`, `catalog/apps.yaml`, `APP-INVENTORY.yaml`, `gitops/homelab/netbox/*.yaml` |
| 10 | Sequences | done | [10-sequences.md](10-sequences.md) | `deploy-app.sh`, `app_env.py`, homelab scripts, `apply-staging.sh`, `plan-staging.sh` |
| 11 | State machines | done | [11-state-machines.md](11-state-machines.md) | `APP-INVENTORY.yaml`, `DATA-CONTRACT.md`, Kyverno policies, `iac/envs/staging/fsn1/variables.tf` |
| 12 | API & integrations | done | [12-api-integration.md](12-api-integration.md) | bootstrap scripts, `install-platform.sh`, `iac/*/versions.tf`, workflows |
| 13 | Threat model | done | [13-threat-model.md](13-threat-model.md) | `argocd/solo-empire-apps-project.yaml`, Kyverno, `.trivyignore.yaml`, netbox manifests, `iac/` |
| 14 | Backup & DR | done (mostly gaps) | [14-backup-dr.md](14-backup-dr.md) | netbox manifests, `iac/modules/database/main.tf`, `STAGING-DATA-BACKUP-RESTORE.md`, `iac/README.md` |
| 15 | CI/CD pipeline | done | [15-cicd-pipeline.md](15-cicd-pipeline.md) | `.github/workflows/*.yml`, platform-ci-workflows `ci-python.yml` / `security.yml` @ `87dc5e1c` |
| 16 | Deployment | done | [16-deployment.md](16-deployment.md) | homelab Applications, `helm/solo-app/homelab/*.yaml`, `bootstrap/*`, `iac/envs/*` |
| 17 | Test coverage matrix | done | [17-test-coverage-matrix.md](17-test-coverage-matrix.md) | `infra/tests/platform/*.py`, validators, workflows; validator run 2026-11-04 |
| 18 | Git & release workflow | done | [18-git-release-workflow.md](18-git-release-workflow.md) | `git log --first-parent`, `gh pr list`, homelab Applications |
| 19 | Service dependency map | done | [19-service-dependency-map.md](19-service-dependency-map.md) | bootstrap scripts, netbox manifests, `iac/`, workflows |
| 20 | Observability | done | [20-observability.md](20-observability.md) | `observability/`, `HOMELAB-OBSERVABILITY-RUNBOOK.md`, `SLO-SLI-BASELINE.md`, `PRODUCT.md` |
| 21 | Incident response | done (Homelab best effort) | [21-incident-response.md](21-incident-response.md) | `HOMELAB-OBSERVABILITY-RUNBOOK.md` §5, `observability/alerts/README.md` |
| 22 | DORA | done (5/5 computed, with caveats) | [22-dora.md](22-dora.md) | `git log`, `gh run list` (ci.yml, platform-validate.yml) |

## ADR list

- [ADR-0001](08-adr/ADR-0001-validate-offline-deploy-nothing.md) Kit ตรวจแบบ offline และไม่ deploy เอง
- [ADR-0002](08-adr/ADR-0002-argocd-gitops-from-this-repo.md) Argo CD GitOps อ่าน repo นี้ (Homelab)
- [ADR-0003](08-adr/ADR-0003-one-helm-chart-solo-app.md) Helm chart เดียว `solo-app` และไม่มี DB ใน chart
- [ADR-0004](08-adr/ADR-0004-hetzner-k3s-staging-provision-false.md) Staging บน Hetzner fsn1 + k3s ผ่าน OpenTofu, `provision=false` เป็นค่าเริ่มต้น

## เอกสารเดิมที่ชุดนี้อ้างถึง (ไม่ได้คัดลอก)

- [`infra/platform/ENVIRONMENT-CONTRACT.md`](../../infra/platform/ENVIRONMENT-CONTRACT.md), [`DATA-CONTRACT.md`](../../infra/platform/DATA-CONTRACT.md)
- [`operations/platform/PRODUCTION-GAPS.md`](../../operations/platform/PRODUCTION-GAPS.md), [`PROVIDER-DECISION.md`](../../operations/platform/PROVIDER-DECISION.md)
- [`operations/platform/HOMELAB-OBSERVABILITY-RUNBOOK.md`](../../operations/platform/HOMELAB-OBSERVABILITY-RUNBOOK.md), [`SLO-SLI-BASELINE.md`](../../operations/platform/SLO-SLI-BASELINE.md)
- [`operations/runbooks/STAGING-DATA-BACKUP-RESTORE.md`](../../operations/runbooks/STAGING-DATA-BACKUP-RESTORE.md)
- Central: [technology-capability-evidence-platform-security.md](https://github.com/bookchaowalit/architecture-docs/blob/main/systems/architecture/technology-capability-evidence-platform-security.md) อ้าง repo นี้เป็นหลักฐาน DevOps/IaC/IDP (ระดับ `partial`)

หมายเหตุ: `operations/` ใน repo นี้เป็นสำเนา snapshot ของเอกสารใน solo-empire (README) ค่าในนั้นอาจล้าหลังต้นฉบับ

## Open questions รวม (ต้องให้ owner ตอบ)

1. repo เป็น **PUBLIC** (`gh repo view` 2026-11-04) แต่ `gitops/homelab/README.md` บอกว่า "private" และให้ Argo CD ใช้ SSH deploy key — ยังต้องใช้ deploy key หรือไม่ และ IP/hostname ของ Homelab ใน repo สาธารณะยอมรับได้หรือไม่
2. Homelab Argo CD Applications ชี้ `platform-infra-kit` `main` แล้ว แต่ README บอก "ยังไม่ได้ apply กับ cluster" — ตอนนี้ cluster sync จาก repo นี้จริงหรือยังชี้ solo-empire
3. `deploy-app.sh` สร้าง path แอปเป็น `$ROOT/<source_path>` โดย `source_path` ยังเป็น path ใน solo-empire (`projects/product/...`) — หลังแยก repo แล้ว local deploy ยังใช้ได้หรือไม่
4. NetBox (Postgres 4Gi, media 2Gi, Valkey 1Gi + cache 512Mi บน `local-path`) ไม่มี backup ใน repo — ยอมรับการสูญหายหรือมี backup นอก repo
5. ใครเป็นเจ้าของเอกสาร `operations/` (สำเนา vs ต้นฉบับใน solo-empire)
6. PR #1 (shared-service delivery, เปิดค้างตั้งแต่ 2026-10-15) จะ merge, ปิด หรือแยกงาน
