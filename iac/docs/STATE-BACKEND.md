# OpenTofu remote state backend (staging)

**Scope:** Hetzner `fsn1` staging only.  
**No production. No multi-cloud.**  
**Default:** local backend is allowed only for `provision=false` scaffold plans.

---

## Goals

| Control | Requirement |
|---------|-------------|
| Encryption at rest | Object storage SSE (AES-256) on state bucket |
| Versioning | Bucket versioning **enabled** (point-in-time state recovery) |
| Restricted access | Dedicated credentials / IAM-style keys; no public ACL |
| State locking | OpenTofu S3 **native lockfile** (`use_lockfile = true`) |
| Backup / recovery | Versioned objects + documented restore |
| Separation | **Bootstrap state** ≠ **staging infra state** |

---

## Two state trees

```text
┌─────────────────────────────────────┐
│  bootstrap/fsn1                     │  state key: bootstrap/fsn1/terraform.tfstate
│  (bucket, versioning, encryption    │  backend config: backend.hcl (gitignored)
│   policies — once)                  │
└─────────────────┬───────────────────┘
                  │ creates / documents
                  ▼
┌─────────────────────────────────────┐
│  Object Storage bucket              │  e.g. solo-empire-tfstate-staging
│  + versioning + SSE + private ACL   │
└─────────────────┬───────────────────┘
                  │ used by
                  ▼
┌─────────────────────────────────────┐
│  staging/fsn1                       │  state key: staging/fsn1/terraform.tfstate
│  (network, k3s, registry, DB, …)    │  backend config: backend.hcl (gitignored)
└─────────────────────────────────────┘
```

Bootstrap never stores k3s tokens, registry TLS keys, or app passwords.  
Staging state **will** contain sensitive values when `provision=true` — hence encryption + access control.

---

## Backend configuration (S3-compatible / Hetzner Object Storage)

Staging and bootstrap use the same **bucket**, different **keys**.

`backend.hcl` (gitignored; copy from `backend.hcl.example`):

```hcl
bucket     = "solo-empire-tfstate-staging"
key        = "staging/fsn1/terraform.tfstate"   # or bootstrap/fsn1/terraform.tfstate
region     = "fsn1"
endpoint   = "https://fsn1.your-objectstorage.com"
encrypt    = true
use_lockfile = true

# Hetzner / custom S3:
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true
use_path_style              = true
```

Credentials via env (never Git):

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
# Optional: AWS_ENDPOINT_URL=https://fsn1.your-objectstorage.com
```

Init (provision path):

```bash
cp backend.tf.example backend.tf     # enables backend "s3" {} (gitignored)
cp backend.hcl.example backend.hcl   # encrypt + lockfile + key (gitignored)
tofu init -backend-config=backend.hcl
```

Scaffold (`provision=false` via `plan-staging.sh`) hides `backend.tf` and uses **local** state only.  
**Never** use local state for `provision=true`.

---

## Encryption at rest

1. Enable **default encryption** on the state bucket (SSE-S3 AES-256 minimum).
2. OpenTofu `encrypt = true` requests encrypted PUT of state objects.
3. Prefer customer-managed keys only if the object store supports them; document KMS ID in operator secrets, not Git.

---

## Versioning

- Bucket versioning **On**.
- Retain noncurrent versions ≥ **90 days** (aligns with backup lifecycle).
- MFA delete optional; recommended if account supports it.

---

## Restricted access

| Rule | Detail |
|------|--------|
| Public access | Block all public ACLs / policies |
| Principals | Single staging automation identity + break-glass admin |
| Network | Prefer private object-storage endpoint if available |
| Git | Never commit `backend.hcl`, `*.tfstate`, access keys |

---

## Locking

- `use_lockfile = true` — OpenTofu writes `.tflock` object alongside state.
- Concurrent applies fail cleanly; do not delete lock objects unless a run is proven dead.
- Alternative (not default): external DynamoDB-compatible lock table if you leave Hetzner later.

---

## Backup and recovery

### Routine

- Rely on **bucket versioning** as primary history.
- Weekly: copy latest state object to a second prefix or second bucket  
  `s3://…/backups/staging/fsn1/YYYY-MM-DD.tfstate`.

### Recover previous state

```bash
# List versions (aws cli / s3-compatible tool)
aws s3api list-object-versions --bucket solo-empire-tfstate-staging \
  --prefix staging/fsn1/terraform.tfstate

# Restore a version to current key (or download + tofu state push carefully)
aws s3api get-object --bucket … --key staging/fsn1/terraform.tfstate \
  --version-id VERSION_ID restored.tfstate
```

### Disaster

1. Stop all applies.
2. Restore known-good state version.
3. `tofu plan` (no apply) and reconcile drift.
4. Document incident; rotate credentials if compromise suspected.

See also [STAGING-DATA-BACKUP-RESTORE.md](../../../../docs/operations/STAGING-DATA-BACKUP-RESTORE.md) for Postgres WAL (separate from TF state).

---

## Local state policy

| Mode | Local state allowed? |
|------|----------------------|
| `provision=false` scaffold plan (`plan-staging.sh`) | Yes (`-backend=false`) |
| `provision=true` plan or apply | **No** — remote backend required |
| Commit `terraform.tfstate` | **Never** |

Preflight rejects local state + missing encryption/locking when `PREFLIGHT_PROVISION=1`.

---

## Sensitive data in state

When staging is provisioned, state may include:

- Hetzner API-derived IDs (non-secret)
- `random_password` results (k3s token, registry password, postgres bootstrap)
- TLS private keys (registry CA + server)

All must be `sensitive = true` in OpenTofu where exposed as attributes/outputs.  
Never print with `tofu output -json` in CI logs without redaction.
