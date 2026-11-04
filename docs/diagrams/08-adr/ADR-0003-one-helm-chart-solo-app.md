# ADR-0003 — Helm chart เดียว `solo-app` และไม่มี DB ใน chart

- Status: accepted (retro-documented)
- Date: retro-documented 2026-11-04

## Context

เป้าหมายใน `infra/platform/README.md` คือรองรับ "approximately 100 applications" ด้วยรูปแบบเดียว

## Decision

แอปทุกตัวใช้ chart `solo-app` (version 0.1.0) ต่างกันแค่ values ค่าเริ่มต้นเน้นความปลอดภัย: `runAsNonRoot`, UID 65532, `readOnlyRootFilesystem: true`, drop ALL capabilities, probes `/healthz` `/readyz`, NetworkPolicy, PDB, HPA, `automount: false` ของ ServiceAccount และ helper ที่ `fail` เมื่อ `image.tag` เป็น `latest` chart ไม่สร้าง PostgreSQL/Redis/vector store; data อยู่นอก chart

## Evidence

- `infra/platform/helm/solo-app/Chart.yaml` (ไม่มี `dependencies`), `values.yaml`, `templates/_helpers.tpl` (บรรทัด 74–76)
- `infra/platform/DATA-CONTRACT.md` "Separation from the application chart"
- `validate-data-contract.py` `validate_solo_app_chart_boundary`

## Consequences

- NetBox ซึ่งต้องมี Postgres/Valkey จึงเขียนเป็น manifests ตรง (`gitops/homelab/netbox/`) ไม่ผ่าน `solo-app`
- Homelab ai-doc-assistant ใช้ `emptyDir` สำหรับ chroma/uploads (DEMO_ONLY) เพราะ chart ไม่ให้ data store
