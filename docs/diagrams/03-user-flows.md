# 03 — User flows (operator journeys)

ไม่มี UI/route; "user" คือ operator ที่รัน scripts ตามลำดับที่ README/runbook กำหนด

## Flow A — onboard แอปใหม่จนถึง local k3d dev

```mermaid
flowchart TD
  A["App approved in APP-INVENTORY.yaml with explicit data_contract"] --> B["onboard-app.py --name X --dry-run"]
  B --> C["onboard-app.py writes apps/X.yaml, catalog entry, values/dev/X.yaml, X-dev.yaml.tpl, runbook"]
  C --> D["validate-onboarding.py"]
  D -->|"fail"| C
  D -->|"pass"| E["deploy-app.sh X"]
  E --> F["app_env.py X exports APP_* vars"]
  F --> G{"IMAGE_TAG is latest, 0.1.0-local or git-pending?"}
  G -->|"yes"| H["Refuse and exit 1"]
  G -->|"no"| I["create-registry.sh, docker build and push git-SHA image"]
  I --> J["Write helm/solo-app/pilot/X-dev.yaml"]
  J --> K["start-local-git-source.sh unless remote ARGOCD_REPO_URL"]
  K --> L["kubectl apply argocd-apps-project.yaml and rendered X-dev.yaml"]
  L --> M["Poll Argo Application sync and health"]
  M --> N["verify-pilots-regression.sh / verify-pilot-resilience.sh"]
```

Sources: `infra/platform/onboarding/README.md`, `infra/platform/onboarding/scripts/onboard-app.py`, `infra/platform/onboarding/scripts/app_env.py`, `infra/platform/bootstrap/local/deploy-app.sh`

Gap: `deploy-app.sh` ตั้ง `APP_DIR="$ROOT/${APP_SOURCE_PATH}"` โดย `ROOT` คือ root ของ repo นี้ แต่ `source_path` ใน `onboarding/apps/*.yaml` ยังเป็น path ของ solo-empire (`projects/product/engineering/...`) จึงจะหยุดที่ "app source not found" หากไม่ได้รันจาก checkout ที่มี path นั้น (ไม่ได้ทดสอบรันจริง)

## Flow B — ปล่อย image ใหม่ขึ้น Homelab

```mermaid
flowchart TD
  A["Set SOLO_BOOK_DEV_ROOT to the Book Dev folder"] --> B["build-push-booknbook.sh: tag git-SHA of app repo"]
  B --> C["docker push registry.homelab.local:5000/solo-empire/booknbook:git-SHA"]
  C --> D["Set image.tag in gitops/homelab/applications/booknbook-homelab.yaml"]
  D --> E["apply-booknbook-application.sh: sed swaps only a git-pending placeholder, then scp + kubectl apply project, approved-registries, Application over SSH"]
  E --> F["Argo CD syncs helm/solo-app path from main with homelab/booknbook.yaml"]
  F --> G["smoke-booknbook-homelab.sh and verify-homelab-urls.sh"]
```

Sources: `infra/platform/bootstrap/homelab/build-push-booknbook.sh`, `infra/platform/bootstrap/homelab/apply-booknbook-application.sh`, `infra/platform/gitops/homelab/applications/booknbook-homelab.yaml`, `infra/platform/bootstrap/homelab/README.md`

หมายเหตุ: Application CR ถูก apply ด้วยมือ (ไม่มี app-of-apps ที่ให้ Argo ดูแล Application เอง) Argo จึง sync เฉพาะ `source.path`; การเปลี่ยน `image.tag` ต้อง apply Application ใหม่ ขั้น D ทำมือ เพราะ sed ใน script แทนเฉพาะค่า `git-pending` แต่ไฟล์ใน `main` เก็บ tag จริงไว้แล้ว (`git-7f3c6b8…`)

## Flow C — staging IaC (ยังไม่เคย apply)

```mermaid
flowchart TD
  A["preflight-staging.sh"] --> B["pre-apply-audit.sh"]
  B --> C["plan-staging.sh: fmt, hide backend.tf, init, validate, plan provision=false"]
  C --> D{"Owner approves real provisioning?"}
  D -->|"no, default"| E["Stop: scaffold only"]
  D -->|"yes"| F["Copy backend.hcl from example; set PREFLIGHT_PROVISION=1, ALLOW_SSH_CIDRS, SSH_KEY_IDS, HCLOUD_TOKEN"]
  F --> G["apply-staging.sh plan: provision=true plan file"]
  G --> H["apply-staging.sh apply: type APPLY-STAGING-FSN1"]
  H --> I["tofu apply approved plan"]
```

Sources: `infra/platform/iac/README.md` (Commands), `infra/platform/iac/scripts/plan-staging.sh`, `infra/platform/iac/scripts/apply-staging.sh`, `.github/workflows/platform-validate.yml` (job `tofu-fmt`)

## Open questions

- ไม่มี flow สำหรับ rollback ของ Homelab app นอกจากแก้ tag กลับใน Git (ยังไม่มีเอกสาร) — ยืนยันว่าใช้วิธีนี้
