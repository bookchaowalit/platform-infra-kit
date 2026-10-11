---
title: Homelab and Portfolio Platform Plan
status: durable
tags: [durable, operations, runbook]
updated: 2026-08-04
---

# Homelab and Portfolio Platform Plan

**Purpose:** run development, demonstrations, DevSecOps practice, and
portfolio applications without monthly cloud infrastructure cost.

**Boundary:** this is a non-production lab. Do not use it for customer data,
payments, public SaaS traffic, contractual uptime, or irreplaceable backups.

The first read-only inventory and applied K3s node are recorded in
[HOMELAB-INVENTORY.md](HOMELAB-INVENTORY.md). It confirms two current Proxmox
nodes, one standalone Ubuntu workstation that replaced the removed third
Proxmox host, and one Fedora workstation. The single-node K3s VM on `beelink`
is now configured as an always-on portfolio runtime with `onboot=1`; the
2026-08-20 live check confirmed the node `Ready` and private probes healthy.

## Current approved hardware roles

The four available machines can be used as independent failure domains:

| Machine | Suggested role | Notes |
|---------|----------------|-------|
| Proxmox host 01 (`beelink`) | Existing K3s server VM and platform services | Current single-node portfolio baseline |
| Proxmox host 02 | Worker capacity candidate only | No VM created; SSH inventory BLOCKED; not joined |
| Ubuntu workstation (`bookchaowalit-MS-7D98`) | Operator/development workstation | Former third Proxmox host; not a Proxmox or K3s node |
| Fedora machine | Private registry only | Not a K3s node; Docker lab services remain local-only |

**Current decision:** Option A — keep the Homelab single-node. Future workers
are optional capacity exercises, not required to complete the platform baseline.

## Future multi-node options (not selected)

If CPU, RAM, and SSD capacity are sufficient, a future lab may run three k3s server nodes,
one per physical machine, for a more realistic HA exercise. Otherwise use one
k3s server and two agents and label the cluster **non-HA**.

Do not treat two Proxmox hosts as a reliable Proxmox HA cluster. Proxmox
documents that reliable quorum for HA requires at least three nodes. The two
hosts may remain standalone, or a third quorum design can be evaluated later.

## What should run free on the homelab

- Docker Compose learning lab and shared DevSecOps tools;
- Argo CD, Kyverno, External Secrets, cert-manager, ingress-nginx;
- `ai-doc-assistant` and `booknbook` portfolio deployments;
- MinIO for S3 API learning and demo uploads;
- synthetic data pipelines and data-engineering experiments;
- local registry, CI runners, Prometheus/Grafana, logs, and traces.

In the current plan, Prometheus/Grafana/logs/traces remain Docker Compose Lab
services unless a separate monitoring decision is approved.

The local MinIO/PostgreSQL services are for demos and test data. Each project
should still use a separate database, schema, or namespace boundary rather
than sharing one application credential across projects.

## What must not run as production on the homelab

- real customer or freelance-client data;
- payment, authentication, or public SaaS workloads;
- contractual uptime or production DNS;
- only-copy backups;
- secrets that cannot be rotated or recovered;
- workloads requiring provider SLA, managed backups, or multi-region failover.

## Kubernetes sizing rule

K3s documents a baseline of 2 CPU cores/2 GB RAM for a server and 1 CPU
core/512 MB RAM for an agent, excluding workloads. SSD storage is recommended
for the K3s datastore. Treat these as minimums, not a target for the platform
stack; reserve additional RAM for Argo CD, observability, CI, and applications.

## Paid production boundary

When a product or SaaS is ready to sell, create a separate paid environment:

1. build immutable OCI images from CI;
2. push to a private registry;
3. use managed or separately operated PostgreSQL;
4. use managed S3-compatible object storage for assets/backups;
5. use managed vector storage when RAG data is durable;
6. enable backups/PITR, TLS, monitoring, alerting, and DNS;
7. deploy with Argo CD to a provider-backed cluster.

The homelab remains the development and portfolio environment; production
cost is paid only for products that need public availability or customer data.

## Cost model

| Tier | Cloud cost | Suitable use |
|------|------------:|--------------|
| Laptop/local k3d | €0 | Fast development and tests |
| Three-machine homelab | €0 cloud spend | Portfolio, demos, DevSecOps/data-engineering practice |
| Hetzner staging | Planned monthly spend | Shared pre-production validation |
| Product production | Variable monthly spend | Paying customers, SLA, backups, public traffic |

The homelab still has electricity, hardware depreciation, disk replacement,
network, and operator-time costs; these are not included in the cloud estimate.

The first K3s installation is applied manually on one disposable VM. It remains
a non-production lab until the inventory checklist, firewall, backup, and
recovery design are approved. It is not managed by OpenTofu yet.

See [HOMELAB-K3S-RUNBOOK.md](HOMELAB-K3S-RUNBOOK.md) for the current access,
controller-installation order, and safety gates.
