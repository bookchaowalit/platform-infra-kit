# 11 — State machines

ไม่มี entity ที่มี status ใน database แต่มี lifecycle fields ใน config ที่ validators บังคับใช้

## 1. Application lifecycle (`APP-INVENTORY.yaml` `status`)

```mermaid
stateDiagram-v2
  [*] --> candidate: listed for discovery
  candidate --> approved: review gate + explicit data_contract
  candidate --> excluded: review rejects
  approved --> retired: removed from platform
  approved --> approved: onboard-app.py adds catalog entry, deployable true
  excluded --> [*]
  retired --> [*]
```

Sources: `infra/platform/APP-INVENTORY.yaml` (`status_values`: candidate, approved, excluded, retired; header comment "Add an app to gitops/applications/catalog/apps.yaml only after its review gate and data contract are complete"), `infra/platform/DATA-CONTRACT.md` ("Approval gate"), `infra/platform/onboarding/README.md` ("Prerequisites")

ไม่มี script ที่เปลี่ยน `status` อัตโนมัติ การเปลี่ยนคือแก้ YAML มือ; ปัจจุบันมีเฉพาะ `approved` และ `candidate` ในไฟล์

## 2. Data contract promotion

```mermaid
stateDiagram-v2
  [*] --> pilot_local: local k3d dev
  pilot_local --> demo_ephemeral: Homelab K3s, DEMO_ONLY
  demo_ephemeral --> staging_durable_planned: staging values only, deploymentEnabled false
  staging_durable_planned --> staging_durable: provision + app integration + restore drill
  staging_durable --> production_durable: separate production gate
  note right of staging_durable_planned
    Current max for ai-doc-assistant staging values
  end note
```

Sources: `infra/platform/DATA-CONTRACT.md` ("Named data contracts", "Application integration gate"), `infra/platform/helm/solo-app/homelab/ai-doc-assistant.yaml` (`SOLO_DATA_CONTRACT: demo-ephemeral`), `infra/platform/gitops/applications/values/staging/ai-doc-assistant.yaml`

`staging_durable` และ `production_durable` เป็น **gap** (ยังไม่มี environment)

## 3. Kyverno policy mode

```mermaid
stateDiagram-v2
  [*] --> Audit: all 9 policies today
  Audit --> Enforce: planned, not implemented
  state Placeholder {
    [*] --> rules_empty: image-provenance-placeholder rules []
  }
```

Sources: `infra/platform/policies/kyverno/*.yaml` (`validationFailureAction: Audit` on 8 policies; `image-provenance-placeholder.yaml` has `rules: []`), `infra/platform/README.md` ("Kyverno policies start in Audit mode")

## 4. Staging IaC provisioning flag

```mermaid
stateDiagram-v2
  [*] --> scaffold: provision false default
  scaffold --> planned_real: apply-staging.sh plan with PREFLIGHT_PROVISION=1
  planned_real --> applied: typed APPLY-STAGING-FSN1 then tofu apply
  planned_real --> scaffold: abort
  applied --> [*]
```

Sources: `infra/platform/iac/envs/staging/fsn1/variables.tf`, `infra/platform/iac/scripts/apply-staging.sh`

`applied` ไม่เคยเกิดขึ้น

## Open questions

- มีแผนเปลี่ยน Kyverno เป็น Enforce บน Homelab เมื่อไร (README บอกเพียง "Audit → Enforce")
