# 21 — Incident response

ไม่มีช่องทาง alert อัตโนมัติ ("There is **no on-call pager** for Homelab") การตรวจพบมาจาก operator รัน verify script หรือเห็น CI แดง กระบวนการด้านล่างมาจาก `HOMELAB-OBSERVABILITY-RUNBOOK.md` §5 (reused, snapshot copy)

```mermaid
flowchart TD
  D1["Operator runs verify-homelab-observability.sh"] --> T
  D2["CI red on main or PR"] --> CIFIX["Fix in Git, push, CI green"]
  D3["Operator notices app down via browser"] --> T
  T["1. Confirm blast radius: verify-homelab-observability.sh"] --> C{"2. Classify"}
  C --> C1["Argo OutOfSync or Degraded"]
  C --> C2["Pod not Ready or restarts"]
  C --> C3["CrashLoop or ImagePull"]
  C --> C4["Node CPU or memory pressure"]
  C --> C5["Ingress non-200"]
  C --> C6["PolicyReport noise, Audit"]
  C1 --> SEV{"Severity"}
  C2 --> SEV
  C3 --> SEV
  C4 --> SEV
  C5 --> SEV
  C6 --> SEV
  SEV -->|"Sev-3 one app degraded"| E["3. Evidence pack over ssh: nodes, top, argocd apps, bad pods, app namespaces"]
  SEV -->|"Sev-2 node pressure or both apps down"| E
  E --> R["4. Remediate: fix Git and let Argo self-heal; no latest images; no full monitoring stack"]
  R --> ESC{"Escalate?"}
  ESC -->|"single app probe"| RB1["App Homelab runbook"]
  ESC -->|"Argo cannot sync"| RB2["Homelab K3s runbook + deploy key / repo access"]
  ESC -->|"Node NotReady or OOM"| RB3["Reduce demos, host capacity"]
  ESC -->|"needs durable data"| RB4["Durable data plan"]
  ESC -->|"no"| CL["5. Close: re-run observability + platform verify, note WARN vs FAIL"]
  RB1 --> CL
  RB2 --> CL
  RB3 --> CL
  RB4 --> CL
  CL --> PM["Postmortem: GAP, no template or location defined"]
```

Sources: `operations/platform/HOMELAB-OBSERVABILITY-RUNBOOK.md` §5.1–5.3, `infra/platform/observability/alerts/README.md`, `operations/platform/PRODUCTION-GAPS.md` ("Alert ownership / on-call: Design-only rules; not applied")

## Gaps

- ไม่มี alert channel (Sev-1 "Not defined for Homelab")
- ไม่มี postmortem template หรือที่เก็บ incident log ใน repo
- DEMO_ONLY data loss (Chroma emptyDir) ถือเป็น expected ไม่ใช่ incident

## Open questions

- ต้องการต่อ Homelab เข้ากับ Telegram alert ที่ใช้กับ service อื่นหรือไม่
- เก็บบันทึก incident ไว้ที่ใด (knowledge store / repo นี้ / architecture-docs)
