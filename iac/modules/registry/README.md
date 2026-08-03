# Module: registry (private TLS + htpasswd)

Private Docker Distribution registry for Solo Empire **staging** on Hetzner.

## Guarantees

| Control | Implementation |
|---------|----------------|
| Not public | Firewall role allows **TCP 5000 from private CIDR only** |
| Bind address | `http.addr = <private_ip>:5000` (never `0.0.0.0`) |
| Authentication | **htpasswd** basic auth (password = `random_password`, not Git) |
| TLS | **Internal CA** + server cert |
| Certificate SANs | `registry_hostname` **and** `private_ip` |
| Node trust | `ca_cert_pem` output → k3s `registries.yaml` + system CA store |

## TLS design

```text
tls_private_key.ca ──► tls_self_signed_cert.ca (is_ca)
                              │
tls_private_key.server ──► CSR (SAN: hostname + private IP)
                              │
                    tls_locally_signed_cert.server
```

- CA and server **private keys** exist only in OpenTofu state when `enabled=true`.
- Never commit keys or passwords.
- Optional later upgrade: replace internal CA with approved public domain cert
  (still keep private bind + htpasswd).

## Node trust (k3s / containerd)

Root module passes `ca_cert_pem` into `k3s-cluster` and `node-pools` cloud-init:

1. Write `/usr/local/share/ca-certificates/solo-registry-ca.crt` + `update-ca-certificates`
2. Write `/etc/rancher/k3s/registry-ca.crt`
3. Write `/etc/rancher/k3s/registries.yaml` with:
   - mirror for `registry_hostname:5000` → `https://private_ip:5000`
   - `tls.ca_file` pointing at the CA
   - `auth` username/password (from secret outputs; not Git)

## Outputs for Argo CD / apps

- `image_repository_prefix` → `registry.staging…:5000/solo-empire`
- `argocd.tls_required = true`, `insecure_http = false`
- `registry_password` (sensitive) → External Secrets / secret manager

## Enablement

Requires root `provision=true` + `ssh_key_ids` + `allow_ssh_cidrs`.  
See `docs/operations/STAGING-INFRA-RUNBOOK.md`.
