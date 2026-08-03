# Bootstrap state root (fsn1)

Records **encrypted remote state** policy for Solo Empire staging.  
Does not provision Kubernetes or registry.

## Separation

| Root | State key |
|------|-----------|
| This bootstrap | `bootstrap/fsn1/terraform.tfstate` |
| Staging infra | `staging/fsn1/terraform.tfstate` |

Same bucket, different keys. Never mix.

## Usage

```bash
cp backend.hcl.example backend.hcl   # edit; do not commit
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
tofu init -backend-config=backend.hcl
tofu plan
# apply only after owner approval to record policy in remote state
```

See `infra/platform/iac/docs/STATE-BACKEND.md`.
