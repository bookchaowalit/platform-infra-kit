# 16 — Deployment

repo นี้ไม่มี hosted runtime ของตัวเอง ภาพแสดง environment ที่ repo นี้เป็น source of desired state

```mermaid
flowchart TB
  subgraph GH["GitHub"]
    R["bookchaowalit/platform-infra-kit main"]
  end
  subgraph LAN["Homelab private LAN"]
    subgraph FED["Fedora 192.168.152.12"]
      REG["registry.homelab.local:5000 TLS + htpasswd, Docker Distribution"]
    end
    subgraph K3S["solo-k3s-server-01 192.168.152.114, single node"]
      ARGO["argocd ns: Argo CD"]
      ING["ingress-nginx class nginx"]
      A1["apps-ai-doc-assistant-homelab: ai-doc-assistant git-3bd4563"]
      A2["apps-booknbook-homelab: booknbook git-7f3c6b8"]
      A3["apps-netbox-homelab: netbox, worker, postgres, valkey x2"]
      A4["platform-smoke: busybox 1.36.1"]
    end
  end
  subgraph WS["Operator workstation"]
    K3D["k3d-solo-dev: 1 server + 2 agents, traefik disabled"]
    LREG["k3d-solo-registry:5000, host localhost:5111"]
    CTRL["argocd, cert-manager, kyverno, external-secrets, metrics-server via install-platform.sh"]
  end
  subgraph HZ["Hetzner fsn1, NOT provisioned"]
    CP["k3s control plane 10.10.1.10"]
    RG["registry 10.10.1.20"]
    DB["postgres 10.10.1.30"]
    NP["node pools general + system"]
  end
  R -->|"SSH deploy key, targetRevision main"| ARGO
  ARGO --> A1
  ARGO --> A2
  ARGO --> A3
  ARGO --> A4
  ING --> A1
  ING --> A2
  ING --> A3
  ING --> A4
  A1 -->|"pull"| REG
  A2 -->|"pull"| REG
  K3D --> LREG
  K3D --> CTRL
```

Sources: `infra/platform/gitops/homelab/applications/*.yaml` (namespaces, image tags), `infra/platform/gitops/homelab/netbox/*.yaml`, `infra/platform/gitops/homelab/platform-smoke/*.yaml`, `infra/platform/helm/solo-app/homelab/*.yaml` (`className: nginx`, hosts), `infra/platform/bootstrap/homelab/README.md`, `infra/platform/bootstrap/local/create-cluster.sh`, `infra/platform/bootstrap/local/install-platform.sh`, `infra/platform/ENVIRONMENT-CONTRACT.md` §2 (registry host port 5111), `infra/platform/iac/envs/staging/fsn1/main.tf` (private IPs)

## Domains / hosts

| Host | Target | TLS |
|---|---|---|
| `ai-doc-assistant.homelab.local` | K3s ingress `192.168.152.114:80` | none (`tls: []`) |
| `booknbook.homelab.local` | same | none |
| `netbox.homelab.local` | same | none in manifest |
| `platform-smoke.local` | same | none |
| `registry.homelab.local` | `192.168.152.12:5000` | TLS (internal CA) |
| `<app>.dev.local` | k3d host port 18080 | optional / none |
| `<app>.staging.<domain>` | planned | cert-manager issuer placeholder |

Sources: `infra/platform/gitops/homelab/README.md` (Boundary), `operations/platform/HOMELAB-URL-CATALOG.md`, `infra/platform/ENVIRONMENT-CONTRACT.md` §4

## Environments

| Env | Status (from repo) | Deploy mechanism |
|---|---|---|
| local / dev (k3d) | disposable, operator-created | `deploy-app.sh` → Argo Application `NAME-dev` |
| homelab | live per URL catalog (healthz 200, FAIL=0) | Argo CD from this repo `main`; Applications applied by SSH |
| staging | not provisioned; values `deploymentEnabled: false` | none |
| production | disabled (`iac/envs/production/README.md`, ApplicationSet element commented out) | none |

## Open questions

- Argo CD UI เข้าถึงด้วย port-forward เท่านั้น (URL catalog) — ยังเป็นเช่นนั้นหรือไม่
- Homelab ingress-nginx ติดตั้งด้วยวิธีใด (ไม่มี script ใน repo สำหรับ Homelab)
