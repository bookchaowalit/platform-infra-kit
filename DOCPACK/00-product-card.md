---
title: solo-platform-kit — Product Card
doc_id: CARD-solo-platform-kit
doc_type: product-card
verdict: showcase
version: 0.1
date: 2026-10-11
status: ร่างเพื่อพิจารณา
owner: Product owner (Book Dev)
---

# solo-platform-kit — Product Card

## 1. สรุปคุณค่าในหนึ่งประโยค

ช่วยเจ้าของ Solo Empire มีชุด IaC/GitOps/policy สำหรับ homelab และ PaaS ที่ตรวจสอบแบบ offline ได้ โดยไม่ deploy อะไรเอง

## 2. ปัญหาและผู้ใช้เป้าหมาย

- ปัญหา: สินทรัพย์แพลตฟอร์มปนอยู่ใน `solo-empire/infra/platform/` ทำให้ repo หลักใหญ่และ owner ไม่ชัด
- ผู้ใช้: เจ้าของ Solo Empire และ agent ที่ดูแลโครงสร้างพื้นฐาน

## 3. สิ่งที่ทำได้จริงตอนนี้

- เก็บ IaC (OpenTofu), GitOps (Argo CD), Helm chart `solo-app`, Kyverno policies, onboarding workflow, observability, supply-chain policy และแผน PaaS ตาม README
- มี validator แบบ offline (เช่น `validate-onboarding.py`, `validate-observability.py`, `validate-image-policy.py`) และ CI `platform-validate.yml`
- ไม่ได้รันตรวจในรอบนี้

## 4. หลักฐานสถานะ

| รายการ | ค่า (ตรวจจาก repository) |
|---|---|
| Stack | YAML / Python validators / OpenTofu / Helm |
| Commits | 52 (แรก 2026-08-02 → ล่าสุด 2026-10-11) |
| Source | ประมาณ 3,221 บรรทัดใน 14 ไฟล์ (ไม่รวมเทสต์) |
| Tests | 2 ไฟล์ |
| CI | 1 workflow |
| Deploy config | ไม่ deploy เอง (ตาม README); CI `platform-validate.yml` |
| Live URL | ไม่มี (ไม่ได้ตรวจ) |
| README | 29 บรรทัด |

## 5. คุณค่าและจุดต่าง

- โครง path `infra/platform/...` คงเดิมเพื่อให้ validator และ GitOps path ทำงานเหมือนเดิม
- มุมรายได้: ไม่มี — ใช้ภายในหรือเป็นหลักฐานงาน platform engineering **[สมมติฐาน]**

## 6. ช่องว่างสำคัญ

- `operations/{platform,ai,runbooks}/` เป็นสำเนา snapshot ต้องแก้สองที่จนกว่าจะเลือกเจ้าของเดียว (README)
- registry ทั้ง repo บางไฟล์ยังอยู่ใน solo-empire
- เทสต์ในไฟล์มี 2 ไฟล์ โดยส่วนใหญ่เป็น validator

## 7. คำตัดสิน

**`showcase`** — เป็นหลักฐานงาน platform/GitOps ที่ใช้งานภายในและมี CI แต่ไม่ใช่ธุรกิจ จะเปลี่ยนเมื่อมี module ที่แยกเป็นผลิตภัณฑ์ใช้ซ้ำได้

## 8. ขั้นต่อไป

1. เลือกเจ้าของเดียวของเอกสาร `operations/` เพื่อเลิกทำสำเนาซ้ำ
2. ยืนยันว่า CI `platform-validate.yml` ผ่านใน repo นี้ (Actions quota อาจหมด)

## การอนุมัติ

| บทบาท | สถานะ | วันที่ | ลงนาม |
|---|---|---|---|
| Product owner (Book Dev) | รอพิจารณา | — | ________ |

## แหล่งข้อมูล

- `README.md`
- `infra/`, `operations/`, `.github/workflows/platform-validate.yml`
