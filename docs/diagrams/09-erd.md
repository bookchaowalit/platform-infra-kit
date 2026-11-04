# 09 — ERD / data model

repo นี้ไม่มี database ของตัวเอง data ที่มีจริงแบ่งเป็นสองแบบ
1. **Config schema ใน Git** (YAML ที่ validators และ Argo CD อ่าน) — ภาพที่ 1
2. **Persisted stores ที่ manifests ของ repo นี้สร้างบน Homelab** (NetBox) — ภาพที่ 2

## 1. Config schema (YAML in Git)

```mermaid
erDiagram
  APP_INVENTORY_ENTRY ||--o| PILOT_APP : "approved becomes"
  PILOT_APP ||--|| CATALOG_ENTRY : "onboard-app.py appends"
  PILOT_APP ||--|| DEV_VALUES : "values/dev/name.yaml"
  PILOT_APP ||--|| ARGO_TEMPLATE : "name-dev.yaml.tpl"
  CATALOG_ENTRY ||--o{ ENV_VALUES : "per valuesDir dev, staging, production"
  HOMELAB_APPLICATION }o--|| HELM_CHART : "source.path solo-app"
  HOMELAB_APPLICATION ||--|| HOMELAB_VALUES : "helm/solo-app/homelab/name.yaml"

  APP_INVENTORY_ENTRY {
    string id
    string source_boundary
    string source_path
    string status "candidate approved excluded retired"
    bool deployable
    string image_repository
    string image_tag
    string namespace
    string data_contract "pilot-local or pending"
  }
  PILOT_APP {
    string apiVersion "solo.empire/v1"
    string kind "PilotApp"
    string metadata_name
    string team
    string component
    string mode
    string source_path
    string image_name
    string data_contract
    int target_port
    string ingress_hostname
    string runbook
    bool values_customized
  }
  CATALOG_ENTRY {
    string name
    string namespace
    string team
    string component
    string mode
    string image_repository
    string image_tag "git-pending in Git"
    int replicas
    string ingress_hostname
    bool autoscaling_enabled
  }
  ENV_VALUES {
    string environment
    int replicaCount
    bool deploymentEnabled "staging false"
    string dataContract "staging-durable-planned"
  }
  HOMELAB_APPLICATION {
    string name
    string repoURL
    string targetRevision "main"
    string image_tag "git-SHA"
    string namespace
    bool selfHeal
    bool prune
  }
  HELM_CHART {
    string name "solo-app"
    string version "0.1.0"
  }
  DEV_VALUES {
    string path
  }
  ARGO_TEMPLATE {
    string path
  }
  HOMELAB_VALUES {
    string SOLO_DATA_CONTRACT
    string SOLO_VECTOR_STORE
  }
```

Sources: `infra/platform/APP-INVENTORY.yaml`, `infra/platform/onboarding/apps/*.yaml`, `infra/platform/onboarding/scripts/onboard-app.py` (`write_definition`, `ensure_catalog_entry`), `infra/platform/gitops/applications/catalog/apps.yaml`, `infra/platform/gitops/applications/values/{dev,staging,production}/*.yaml`, `infra/platform/gitops/homelab/applications/*.yaml`, `infra/platform/helm/solo-app/Chart.yaml`, `infra/platform/helm/solo-app/homelab/ai-doc-assistant.yaml`

ตัวเลขปัจจุบัน: inventory มี approved 2 (`ai-doc-assistant`, `booknbook`) ที่เหลือ `candidate`; catalog มี 2 entries; `onboarding/apps/` มี 2 definitions

## 2. Persisted stores on Homelab (NetBox)

```mermaid
erDiagram
  NETBOX_WEB }o--|| NETBOX_POSTGRES : "5432"
  NETBOX_WORKER }o--|| NETBOX_POSTGRES : "5432"
  NETBOX_WEB }o--|| NETBOX_REDIS : "6379 tasks"
  NETBOX_WEB }o--|| NETBOX_REDIS_CACHE : "6379 cache"
  NETBOX_WEB ||--|| PVC_NETBOX_MEDIA : "mounts"
  NETBOX_WORKER ||--|| PVC_NETBOX_MEDIA : "mounts"
  NETBOX_POSTGRES ||--|| PVC_PGDATA : "volumeClaimTemplate postgres-data"
  NETBOX_REDIS ||--|| PVC_NETBOX_REDIS_DATA : "mounts"
  NETBOX_REDIS_CACHE ||--|| PVC_NETBOX_REDIS_CACHE_DATA : "mounts"
  SECRET_NETBOX_RUNTIME ||--o{ NETBOX_WEB : "secretKeyRef"

  NETBOX_POSTGRES {
    string image "postgres 17-alpine"
    string kind "StatefulSet replicas 1"
  }
  PVC_PGDATA {
    string storageClass "local-path"
    string size "4Gi"
  }
  PVC_NETBOX_MEDIA {
    string storageClass "local-path"
    string size "2Gi"
  }
  PVC_NETBOX_REDIS_DATA {
    string size "1Gi local-path"
  }
  PVC_NETBOX_REDIS_CACHE_DATA {
    string size "512Mi local-path"
  }
  NETBOX_REDIS {
    string image "valkey 9.1-alpine"
  }
  NETBOX_REDIS_CACHE {
    string image "valkey 9.1-alpine"
  }
  NETBOX_WEB {
    string image "netbox v4.6.7-5.0.2"
  }
  NETBOX_WORKER {
    string image "netbox v4.6.7-5.0.2"
  }
  SECRET_NETBOX_RUNTIME {
    string origin "bootstrap-netbox.sh, not in Git"
  }
```

Sources: `infra/platform/gitops/homelab/netbox/netbox.yaml`, `postgres.yaml`, `valkey.yaml`, `networkpolicy.yaml`, `infra/platform/gitops/homelab/README.md` ("Boundary"), `operations/platform/HOMELAB-URL-CATALOG.md` ("5 devices + 1 VM seeded")

ตาราง NetBox ภายใน Postgres เป็น schema ของ NetBox upstream ไม่ได้นิยามใน repo นี้ จึงไม่วาด

## Stores อื่นที่ repo นี้อ้างถึง (ไม่ใช่ schema ของ repo)

| Store | ที่อยู่ | สถานะ |
|---|---|---|
| ai-doc-assistant chroma + uploads (Homelab) | `emptyDir` | DEMO_ONLY, หายเมื่อ pod restart (DATA-CONTRACT) |
| Homelab registry images | Fedora `REGISTRY_DATA_DIR` ค่าเริ่มต้น `/var/lib/solo-empire-registry` (credentials ใน `/etc/solo-empire-registry/`) | live ตาม URL catalog |
| Staging Postgres `ai_doc_assistant` | `iac/modules/database` บน Hetzner volume | not provisioned |
| OpenTofu state | local (scaffold) / S3 Hetzner Object Storage (design) | not provisioned |

## Open questions

- นโยบายลบ image เก่าใน Homelab registry ไม่มีใน repo
