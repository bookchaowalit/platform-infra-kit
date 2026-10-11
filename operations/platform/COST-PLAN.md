---
title: Solo Empire Cost Plan
status: evidence
tags: [evidence, operations]
updated: 2026-08-12
---

# Solo Empire Cost Plan

**Last updated:** 2026-08-12
**Currency:** EUR, excluding VAT
**Status:** Planning only; no cloud resources are currently provisioned.

> **2026-08-12 re-price:** Hetzner's price-adjustment table (effective
> 15 June 2026) no longer lists `cpx11`/`cpx21`, the server types this
> plan's defaults assumed. The figures below use the nearest listed
> successor tier by price position (`cpx11`-class → `cx23`, `cpx21`-class →
> `cpx22`) as a **planning estimate only** — this is inferred from price-tier
> position, not a confirmed spec match. At these prices the default staging
> topology totals **~€105.85/month**, which **exceeds the €80 soft budget**.
> Before `provision=true`: confirm the exact current replacement type and
> specs in the Hetzner Console, then either raise the budget guard or shrink
> the topology (see `infra/platform/iac/modules/cost/variables.tf`).

## Cost at a glance

| Area | Current cost | What it includes |
|------|--------------|------------------|
| Local Docker lab | €0 cloud spend | Docker Compose services, MinIO, PostgreSQL, observability, and DevSecOps tools on the existing workstation |
| Local k3d cluster | €0 cloud spend | K3s, Argo CD, Kyverno, ESO, cert-manager, ingress-nginx, and two pilot apps on the existing workstation |
| Four-machine homelab | €0 cloud spend | Two Proxmox hosts, one Ubuntu workstation, and one Fedora machine for portfolio/dev workloads |
| Planned Hetzner staging | IaC model: **€105.85/month** (re-priced 2026-08-12; **exceeds** budget guard) | One fsn1 control plane, two workers, registry VM, PostgreSQL VM, volumes, object-storage allowance, optional LB, and contingency |
| Staging budget guard | €80/month | Soft budget with labels, node caps, and manual alerts — **currently under the re-priced estimate; raise the budget or shrink the topology before provisioning** |
| Production | Not estimated | Provider, HA topology, managed data, traffic, backups, and observability are not selected |

Local has no additional cloud bill, but it still consumes workstation CPU,
RAM, disk, electricity, and operator time. The local Docker MinIO is a learning
service, not a production storage service.

The three-machine homelab can replace most early cloud usage for portfolio and
development work. See [HOMELAB-PLAN.md](HOMELAB-PLAN.md). It is not a
production HA substitute, and a two-host Proxmox setup should not be treated as
reliable HA quorum.

## Planned Hetzner staging line items

The current OpenTofu cost module contains this **planning estimate**:

| Component | IaC estimate/month | Current role | Provisioned now? |
|-----------|------------------:|-------------|------------------|
| k3s control plane | €19.49 | One control-plane VPS (`cpx21` planning → `cpx22`, unverified) | No |
| General workers | €38.98 | Two worker VPSs (`cpx21` planning → `cpx22`, unverified) | No |
| Private registry | €5.49 | Registry VM with TLS + volume (`cpx11` planning → `cx23`, unverified) | No |
| PostgreSQL | €19.49 | Private PostgreSQL VM (`cpx21` planning → `cpx22`, unverified) | No |
| Volumes | €4.00 | Registry/database storage allowance — not in the re-priced table, unverified | No |
| S3-compatible object storage | €5.00 | Assets, backups, and logs allowance — not in the re-priced table, unverified | No |
| Load balancer | €5.40 | Optional public ingress LB — not in the re-priced table, unverified | No; DNS/LB disabled |
| DNS | €0.00 | Disabled until a real domain is approved | No |
| Contingency | €8.00 | Traffic, snapshots, and small price variance | N/A |
| **Total** | **€105.85** | **Exceeds** the €80 planning budget by ~€25.85 | **No cloud resources** |

The OpenTofu cost guard scales the general-worker line item with
`general_node_count`. A plan-only one-worker scenario (`TF_VAR_general_node_count=1`)
is **€86.36/month**, so it remains over the €80 policy; no topology or budget
change is approved by this evidence.

For decision-making only, excluding the optional load-balancer (€5.40) and
object-storage (€5.00) allowances from that one-worker scenario would produce
an arithmetic **€75.96/month** core-only preview. That is not a deployable
staging profile: it omits the object-storage/PITR boundary and public edge
allowance, so it must not be promoted as production-ready.

The €105.85 figure is not an invoice or a current provider quote, and it is
not a confirmed spec match either — it substitutes the nearest priced tier
for a server type that no longer appears in Hetzner's catalog. It is the
repository's re-priced baseline guard as of 2026-08-12. Hetzner changed cloud
server pricing from 15 June 2026; the current table lists CPX22 in FSN/NBG/HEL
at €19.49/month and CX23 at €5.49/month, and does not list the old CPX21 or
CPX11 in that regional table. Re-price the exact server types, IPv4, volumes,
load balancer, and traffic in the Hetzner Console before setting
`provision=true` — and either raise `monthly_budget_eur` or reduce the node
count/type to fit €80 if the budget ceiling itself does not change.
[Hetzner's current price-adjustment table](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)

Object Storage is planned as managed S3-compatible storage rather than MinIO
inside the staging cluster. Hetzner documents FSN1 availability, S3 API access,
and an included storage/egress quota; the exact current base price and excess
usage must be confirmed in the account before activation. [Hetzner Object Storage](https://www.hetzner.com/storage/object-storage)

## What is shared and where it runs

| Service | Local learning | Staging target | Production direction |
|---------|----------------|----------------|----------------------|
| Docker Compose tools | Workstation | Not copied wholesale | Replace with managed/platform services where needed |
| Argo CD / Kyverno / ESO / cert-manager | Local k3d | k3s cluster | Managed or self-operated per provider |
| Application containers | Local k3d | k3s workloads | Kubernetes workloads |
| PostgreSQL | Compose lab only | Separate private data service | Managed PostgreSQL preferred |
| MinIO | Compose lab only | Not selected for staging | S3-compatible managed storage preferred |
| Vector store | Chroma in-memory/emptyDir demo | Durable managed vector store required | Managed Qdrant/pgvector/equivalent |
| Registry | Local k3d registry | Private registry VM | Managed/private registry with signing |
| Observability | Compose Prometheus/Grafana/Loki/Tempo | To be provisioned/connected | Managed or dedicated observability |

## Cost optimization choices

1. Keep local development on Docker/k3d: no cloud spend while the platform is
   being validated.
2. Keep staging single-region and one control plane until restore and load
   data justify more nodes.
3. Do not run MinIO, PostgreSQL, or vector storage per application.
4. Use one private S3-compatible object-storage account with separate buckets
   and secret boundaries.
5. Keep the optional load balancer and DNS disabled until public staging is
   needed.
6. Delete the staging cluster when it is not needed; a Hetzner server remains
   billable while it exists, even if powered off.
7. Re-price before apply and review actual spend after 30 days.
8. Use the homelab for portfolio apps and synthetic data; pay for production
   infrastructure only when a product needs public availability or customer
   data.

## Approval gate

No cost is incurred by the current repository state. Before staging spending:

- approve the monthly budget;
- confirm exact Hetzner server types and current prices;
- create the encrypted remote state bucket;
- configure real SSH key IDs and restricted admin CIDRs;
- review `provision=true` plan;
- apply only through `infra/platform/iac/scripts/apply-staging.sh`.

Production cost approval is a separate decision and cannot use the €80 staging
budget as a proxy.

For the full production and portfolio comparison—including VPS+k3s, managed
Kubernetes, Vercel, Cloudflare Workers, AWS EKS, and the homelab—see
[PRODUCTION-COST-COMPARISON.md](PRODUCTION-COST-COMPARISON.md).
