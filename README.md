# platform-kit

ชุดสินทรัพย์แพลตฟอร์ม (ไม่ deploy อะไรเอง): IaC (OpenTofu), GitOps (Argo CD), Helm chart `solo-app`, Kyverno policies, onboarding workflow, observability, supply-chain policy, bootstrap สำหรับ homelab/local, PaaS execution/ plan docs

ที่มา: ย้ายจาก `solo-empire/infra/platform/` (2026-10-11) พร้อมประวัติ git (subtree split).
repo นี้คงโครงสร้าง path แบบ `infra/platform/...` เดิมไว้เพื่อให้ validator และ GitOps path ทำงานเหมือนเดิม

## ยังอยู่ใน solo-empire (registry ที่ guard/api อ่าน)

`infra/platform/{building-block-services.yaml, cloud-providers.yaml, domains.yaml, gpu-worker-catalog.json, llm-lab-models.json, media-transcription-routing.json, paas-action-policy.json}` — registry ทั้งrepo ที่ `infra/scripts/platform/*`, API และ dashboard อ่านอยู่ จึงไม่ย้ายมาที่นี่

## ตรวจสอบ (offline)

```bash
python3 infra/tests/platform/platform_validation_test.py --strict-platform
python3 infra/tests/platform/git_file_mode_test.py
python3 infra/tests/platform/onboarding_scripts_test.py
python3 infra/platform/onboarding/scripts/validate-onboarding.py
python3 infra/platform/observability/validate-observability.py
python3 infra/platform/supply-chain/validate-image-policy.py
python3 infra/platform/homelab/validate-url-catalog.py
python3 infra/platform/homelab/validate-multinode-readiness.py
```

CI: `.github/workflows/ci.yml` (shared `platform-ci-workflows` v1.1.1: Ruff + test suites ด้านบน + security scan) และ `.github/workflows/platform-validate.yml` (ย้ายมาจาก solo-empire; job compose-config ย้ายไป homelab).

สิ่งที่ repo นี้เป็นและไม่เป็น: [PRODUCT.md](PRODUCT.md)

## หมายเหตุสำคัญ

- `operations/{platform,ai,runbooks}/` ใน repo นี้เป็นสำเนา snapshot ของเอกสารที่ validator ตรวจ (ต้นฉบับยังอยู่ใน solo-empire); แก้เอกสารที่ validator ตรวจต้องแก้ทั้งสองที่จนกว่าจะเลือกเจ้าของเดียว
- Argo CD Applications ใน `infra/platform/gitops/homelab/applications/` ชี้ `repoURL: git@github.com:bookchaowalit/platform-infra-kit.git` path `infra/platform/...` แล้ว (ยังไม่ได้ apply กับ cluster; ต้อง sync เองหลัง merge)
