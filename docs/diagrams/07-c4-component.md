# 07 — C4 Component (validation toolkit)

ส่วนที่เป็นโค้ดจริงของ repo คือ Python validators และ onboarding helpers ภาพนี้แยก component ภายใน container "Validators and tests" + "Onboarding toolkit"

```mermaid
C4Component
  title Components - validators and onboarding
  Container_Boundary(v, "infra/tests/platform + infra/platform validators") {
    Component(pvt, "platform_validation_test.py", "Python, --strict-platform", "Checker; test_helm_chart, test_gitops, test_policies, test_platform_no_secrets_or_latest, test_gitignore_env, test_onboarding_workflow, test_url_catalog_workflow, test_multinode_readiness_workflow, test_observability_workflow, test_data_contract_workflow")
    Component(vonb, "validate-onboarding.py", "Python", "definitions, values, catalog + inventory, Argo templates, secrets, expected pilots, staging readiness, docs")
    Component(vdc, "validate-data-contract.py", "Python", "docs, inventory data_contract, homelab DEMO_ONLY, staging ai-doc, chart boundary, secret scan")
    Component(vobs, "validate-observability.py", "Python", "docs, verify script, design-only alerts, platform refs")
    Component(vurl, "validate-url-catalog.py", "Python", "URL catalog, hosts fragment, DNS scripts, controller docs")
    Component(vmn, "validate-multinode-readiness.py", "Python", "docs, audit script, secrets and update notes")
    Component(vsc, "validate-image-policy.py", "Python", "image refs, latest, staging gate, secret-like assignments, signing not claimed")
    Component(gfm, "git_file_mode.py", "Python", "has_executable_bit via stat or git ls-files")
    Component(gfmt, "git_file_mode_test.py", "unittest", "4 tests")
  }
  Container_Boundary(o, "infra/platform/onboarding/scripts") {
    Component(lib, "lib_yaml.py", "Python", "load_yaml, dump_yaml, load_pilot_app")
    Component(env, "app_env.py", "Python CLI", "PilotApp to shell exports")
    Component(onb, "onboard-app.py", "Python CLI", "scaffold from templates, --dry-run, --force")
    Component(ost, "onboarding_scripts_test.py", "unittest", "5 tests")
  }
  Rel(pvt, vonb, "subprocess")
  Rel(pvt, vdc, "subprocess")
  Rel(pvt, vobs, "subprocess")
  Rel(pvt, vurl, "subprocess")
  Rel(pvt, vmn, "subprocess")
  Rel(gfmt, gfm, "imports")
  Rel(vobs, gfm, "imports")
  Rel(vurl, gfm, "imports")
  Rel(vmn, gfm, "imports")
  Rel(env, lib, "imports")
  Rel(ost, env, "runs")
  Rel(ost, lib, "imports")
```

Sources: `infra/tests/platform/platform_validation_test.py` (function list lines 88–654, subprocess calls at 399, 454, 507, 563, 618), `infra/platform/onboarding/scripts/*.py`, `infra/platform/observability/validate-observability.py`, `infra/platform/homelab/validate-*.py`, `infra/platform/supply-chain/validate-image-policy.py`, `infra/platform/git_file_mode.py`, `infra/tests/platform/git_file_mode_test.py`, `infra/tests/platform/onboarding_scripts_test.py`

ผลรัน (2026-11-04, ในเครื่อง): platform 432 passed / 0 failures; onboarding 149; data-contract 68; observability 59; URL-catalog 52; multinode 48; supply-chain 10; unittest 4 + 5 OK

`validate-image-policy.py` ไม่ถูกเรียกจาก `platform_validation_test.py` (รันแยกใน job `supply-chain-contract`) `infra/scripts/platform/platform_output.py` (`configure_utf8_stdio`) ถูก import โดย `platform_validation_test.py`, `validate-onboarding.py`, `validate-data-contract.py`, `validate-observability.py` และ homelab validators ทั้งสอง (ไม่ได้วาดเส้นเพื่อลดความรก); `git_file_mode.py` ใช้ตรวจ exec bit ของ scripts ใน observability และ homelab validators

## Open questions

- ไม่มี
