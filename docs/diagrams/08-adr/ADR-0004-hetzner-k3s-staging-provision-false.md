# ADR-0004 — Staging บน Hetzner fsn1 + k3s ผ่าน OpenTofu, `provision=false` เป็นค่าเริ่มต้น

- Status: accepted (retro-documented; decision record dated 2026-08-02 in `operations/platform/PROVIDER-DECISION.md`)
- Date: retro-documented 2026-11-04

## Context

ต้องมีเส้นทางสำหรับ staging/production หลัง local pilots โดยคุมงบ (PRODUCTION-GAPS: staging policy €80, scaffold estimate €105.85)

## Decision

"Staging provider path: B — VPS + k3s on Hetzner Cloud, region `fsn1` only" (PROVIDER-DECISION) ทำเป็น OpenTofu root `iac/envs/staging/fsn1` ใช้ provider `hetznercloud/hcloud`, `random`, `tls`, `local`; ตัวแปร `provision` ค่าเริ่มต้น `false`; มี `check` blocks (SSH keys/CIDRs เมื่อ provision, single region `fsn1`, workers ≤ `max_worker_nodes`, registry internal-ca TLS) remote state เป็น S3-compatible (Hetzner Object Storage) ผ่าน `backend.hcl` ที่ gitignore ไว้ production ไม่มี root module

## Evidence

- `operations/platform/PROVIDER-DECISION.md` ("Working decision … 2026-08-02")
- `infra/platform/iac/README.md`, `envs/staging/fsn1/{main,variables,versions,providers}.tf`, `envs/production/README.md`
- `infra/platform/iac/docs/STATE-BACKEND.md`, `backend.tf.example`

## Consequences

- cloud resources ใน modules (`hcloud_*`, `tls_*`, `random_*`) ผูก `count` กับ `var.enabled` (ซึ่ง staging root ส่ง `var.provision`) และมี `terraform_data "scaffold"` เมื่อปิด; modules `dns`, `object-storage`, `cost`, `monitoring` มีแค่ `terraform_data` / `local_file` (ไม่มี cloud resource จริง); `dns` และ `object_storage` ถูกตั้ง `enabled = false` ตายตัวใน root
- CI ทำ plan ได้โดยไม่มี credential จริง (dummy token ใน `providers.tf`)
- ยังไม่เคย apply: ไม่มี staging cluster, DB หรือ state จริง
