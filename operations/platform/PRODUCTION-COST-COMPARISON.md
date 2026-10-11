---
title: Production deployment and cost comparison
status: evidence
tags: [evidence, operations]
updated: 2026-08-04
---

# Production deployment and cost comparison

**Last updated:** 2026-08-02  
**Status:** Portfolio and planning comparison; no production infrastructure
has been provisioned.

## Decision in one sentence

Build a portfolio that demonstrates every relevant deployment model, but do
not keep every model running as a paid production environment. Keep local and
homelab workloads free, use short-lived cloud environments for provider
demonstrations, and pay for one production path only when a product has real
users, customer data, or a service-level requirement.

This document compares deployment models rather than every cloud vendor. The
same application image and GitOps contract should remain portable across the
models.

## Comparison

Prices are indicative starting points, before tax, exchange-rate conversion,
usage, backups, email, domain names, model/API calls, and operator time. USD
and EUR values are intentionally not converted into one currency. Re-check the
provider console before buying; prices and included quotas change.

| Option | Best portfolio demonstration | Indicative infrastructure cost | Operational burden | Value for Solo Empire | Decision |
|---|---|---:|---|---|---|
| Laptop Docker Compose | Shared DevSecOps/data tools, local development | **€0 cloud**; uses local CPU/RAM/disk/electricity | Low | Essential foundation | Keep always available |
| Laptop k3d | Argo CD, Helm, policies, app onboarding, GitOps | **€0 cloud** | Low–medium | Best zero-cost Kubernetes rehearsal | Keep always available |
| Three-machine homelab | Proxmox, Fedora, self-hosted networking, multi-node K3s | **€0 cloud**; hardware/electricity are real costs | Medium–high | Strong infrastructure portfolio without a monthly bill | Add gradually; not customer production |
| Hetzner VPS + k3s | Portable self-managed single-region staging | Existing IaC guard: **€105.85/month estimate** (re-priced 2026-08-12, **exceeds** the €80 budget guard); server types are unverified successors, confirm in Console before apply | High | Best low-cost cloud/k3s parity | Use for staging or a time-boxed public demo — raise budget or shrink topology first |
| Civo managed Kubernetes | Managed K8s with a small worker pool | Control plane free; worker from about **$5.43/month**; add-ons extra | Medium | Excellent inexpensive managed-K8s portfolio | Use temporarily for a K8s demo |
| DigitalOcean Kubernetes | Managed K8s, node pools, LB, volumes | Control plane free; Basic worker from **$12/month**, LB **$12/month**, block storage from **$10/month** | Medium | Clear pricing and easy customer-demo environment | Good second managed-K8s comparison |
| Vercel | Next.js deployment, preview environments, serverless frontend | Hobby for eligible personal/non-commercial demos; Pro announcement lists **$20/month usage credit per plan** plus usage/seats | Low | Best fit for `booknbook`-style Next.js apps | Use for a frontend deployment demo, not every backend |
| Cloudflare Workers | Edge/serverless API, routing, CDN, lightweight jobs | Free/usage-based tiers; exact bill depends on requests, CPU, storage, and add-ons | Low–medium | Shows edge architecture and global delivery | Use for one focused edge demo |
| AWS EKS | Enterprise cloud, IAM, VPC, managed control plane, autoscaling | EKS standard control-plane fee **$0.10/hour ≈ $73/month**, before EC2, EBS, IPs, traffic, and add-ons | High | Strong enterprise interview signal | Time-boxed lab only; poor always-on portfolio economics |
| Managed K8s + managed data for real SaaS | Public product with HA, backups, PITR, observability, and support | Usually the highest recurring cost; quote cluster, DB, storage, egress, logs, and support together | Medium | Best customer-production default when requirements justify it | Pay per real product, one region first |

Reference pricing: [Hetzner current cloud pricing](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/), [Civo pricing](https://www.civo.com/pricing), [DigitalOcean Kubernetes pricing](https://www.digitalocean.com/pricing/kubernetes), [AWS EKS pricing](https://aws.amazon.com/eks/pricing/), and [Vercel's Pro plan announcement](https://community.vercel.com/t/updated-pro-plan/18608).

## What is actually worth paying for?

### Free or nearly free portfolio layer

- Run Docker Compose and k3d on the current workstation.
- Move suitable workloads to the three-machine homelab when the machines are
  available.
- Use synthetic data and non-production secrets.
- Demonstrate the same two pilot apps through local ingress, Argo CD, Helm,
  policy checks, recovery drills, and observability.

This layer proves engineering ability without creating a cloud bill. It does
not provide public uptime, a contractual SLA, or safe storage for customer
data.

### Short-lived paid demonstration layer

Use one provider at a time and destroy it after the demonstration or test:

1. Hetzner VPS + k3s for self-managed infrastructure and cost optimization.
2. Civo or DigitalOcean for managed Kubernetes and provider-managed control
   planes.
3. AWS EKS for an enterprise-style IAM/VPC/managed-Kubernetes case study.
4. Vercel for a Next.js preview/production-style frontend deployment.
5. Cloudflare Workers for one edge/API use case.

The portfolio can contain architecture diagrams, IaC, deployment logs,
failure drills, and cost reports for all five. They do not need to be online
simultaneously.

### Real production layer

When an app becomes a product or SaaS that customers depend on, choose one
production path per product:

- public Next.js site with little state: Vercel or an equivalent frontend
  platform;
- stateful API/RAG product: managed Kubernetes or a simpler managed app
  runtime plus managed PostgreSQL, object storage, and vector storage;
- regulated or enterprise requirement: managed Kubernetes on the provider
  required by the customer, with managed data and centralized IAM;
- self-managed VPS+k3s: only when the owner accepts the operational burden and
  the business case values lower fixed cost over managed operations.

Do not use the €80 staging guard as a production budget. Production must be
priced from expected traffic, data size, backup retention, RTO/RPO, logs,
egress, and on-call requirements. For AI applications, model/API usage is a
separate variable cost and can exceed the container cost.

## Recommended learning route

| Stage | Runtime | What to learn | Spend rule |
|---|---|---|---|
| 1 | Docker Compose + local k3d | Containers, GitOps, security, app onboarding | No cloud spend |
| 2 | Proxmox/Fedora homelab | Multi-node operations, storage, networking, failure drills | Hardware/electricity only |
| 3 | Hetzner fsn1 k3s | IaC, private networking, registry TLS, backups, cost limits | One staging bill; destroy when idle |
| 4 | Civo or DigitalOcean | Managed control plane and provider-specific integrations | One short-lived comparison lab |
| 5 | Vercel + Cloudflare | Frontend/serverless/edge trade-offs | Free tier or short paid test |
| 6 | AWS EKS | Enterprise cloud patterns | Short-lived lab; avoid always-on |
| 7 | One selected production provider | Real customer workload and SLOs | Pay only when justified by the product |

## Guardrails

- Never put real customer data or production credentials in the local lab,
  homelab, or short-lived provider demos.
- Keep PostgreSQL, object storage, and vector data outside the reusable app
  chart; use managed or separately operated services with per-app identities.
- Use immutable image tags, GitOps, backups, restore drills, and cost alerts
  in every cloud demonstration.
- Delete idle clusters, load balancers, volumes, public IPs, snapshots, and
  registries; stopping a VM does not necessarily stop billing.
- Record a small cost report for each demo: fixed cost, variable cost, data
  egress, operator time, and what would be different at production scale.
- Multi-cloud is a portfolio exercise first. Do not duplicate a live SaaS
  across providers until availability, compliance, or customer demand makes
  the extra cost and operational complexity worthwhile.

## Current Solo Empire decision

1. **Now:** local Docker/k3d remains the default and costs €0 in cloud spend.
2. **Homelab:** use the two Proxmox machines, standalone Ubuntu workstation,
   and Fedora machine for portfolio infrastructure once they are available.
3. **Staging:** keep the existing Hetzner `fsn1` OpenTofu path plan-only until
   the owner approves a re-priced budget and secure state.
4. **Portfolio expansion:** add Vercel, one managed-K8s provider, Cloudflare,
   and one AWS EKS exercise as separate, time-boxed demonstrations.
5. **Production:** select one provider per real product; do not provision
   production from this repository yet.

Related documents: [Cost Plan](COST-PLAN.md),
[Homelab Plan](HOMELAB-PLAN.md), [Provider Decision](PROVIDER-DECISION.md),
[Portfolio Execution Plan](../evidence/PORTFOLIO-EXECUTION-PLAN.md),
[Production Gaps](PRODUCTION-GAPS.md), and
[Kubernetes Platform Readiness](KUBERNETES-PLATFORM-READINESS.md).
