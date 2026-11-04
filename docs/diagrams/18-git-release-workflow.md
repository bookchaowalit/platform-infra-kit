# 18 — Git & release workflow

- Branch เดียวที่ใช้ปล่อยคือ `main`; ไม่มี tag หรือ GitHub release
- History ก่อน 2026-10-11 มาจาก `git subtree split` ของ `solo-empire/infra/platform/` (README "พร้อมประวัติ git") repo แยกตัวที่ `e06bf74`
- หลังแยก: ส่วนใหญ่ commit ตรงเข้า `main`; มี PR ที่ merge แล้ว 1 อัน (#2, squash บน GitHub → `7e1b450`, committer `GitHub`) และ PR เปิดค้าง 1 อัน (#1)
- `main` ไม่มี branch protection / ruleset (ดู [13](13-threat-model.md))
- "Release" = Argo CD Homelab อ่าน `targetRevision: main` ทันทีที่ sync รอบถัดไป

```mermaid
gitGraph
  commit id: "fa2904d homelab gitops 08-02"
  commit id: "... solo-empire history"
  commit id: "56b10c0 10-11"
  commit id: "e06bf74 standalone repo"
  commit id: "5ff8962 decouple"
  commit id: "155df13 rename"
  commit id: "57e4b75 Apache-2.0"
  commit id: "788e8dd renames"
  commit id: "42f5053 Revert" type: REVERSE
  commit id: "ed91c4f renames again"
  commit id: "856a6ec org renames"
  branch codex-shared-infrastructure
  checkout codex-shared-infrastructure
  commit id: "PR 1 open since 10-15"
  checkout main
  branch ci-devsecops-phase1
  checkout ci-devsecops-phase1
  commit id: "7a93304"
  commit id: "e2de8d8"
  checkout main
  commit id: "7e1b450 squash PR 2" type: HIGHLIGHT
  commit id: "25a0838 CI red"
  commit id: "f80262a fix EXE001"
```

Sources: `git log --first-parent origin/main`, `git log --merges origin/main` (1 merge, `a727d66` from solo-empire era), `gh pr list --state all` (PR #1 OPEN `codex/shared-infrastructure-20261015`; PR #2 MERGED 2026-10-17T09:44:12Z), `gh run list` (head SHAs of PR #2 runs), `README.md`

## Path to Homelab

```mermaid
flowchart LR
  C["Commit"] --> P{"Direct push or PR"}
  P -->|"push main"| M["main"]
  P -->|"PR"| CI["ci.yml + platform-validate.yml on PR"] --> SQ["squash merge"] --> M
  M --> CIM["CI on push main, not a gate"]
  M --> A["Argo CD Homelab syncs path at main, selfHeal"]
  M -.->|"image tag change"| OP["Operator re-applies Application over SSH"]
```

Sources: `.github/workflows/*.yml`, `infra/platform/gitops/homelab/applications/*.yaml`, `infra/platform/bootstrap/homelab/apply-*-application.sh`

CI บน push `main` ไม่ได้กั้นอะไร: Argo CD ไม่รอผล CI (ไม่มี config ใดเชื่อมสองอย่างนี้)

## Open questions

- ต้องการให้ Homelab ใช้ tag/branch แยก (เช่น `homelab`) แทน `main` เพื่อให้ CI เป็น gate หรือไม่
