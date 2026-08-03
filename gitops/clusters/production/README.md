# Cluster: production

| Field | Value |
|-------|-------|
| Environment | `production` |
| Regions | Separate cluster **per region** (example: `ap-southeast-1`, `us-east-1`) |
| Purpose | Customer-facing workloads |
| Data | Managed PostgreSQL + object storage preferred |

## Multi-region rules

- **No stretched Kubernetes control plane** across regions.
- Argo CD (management) deploys the same ApplicationSet to each regional cluster.
- Stateful services use regional managed services; apps stay stateless.
- Failover is DNS / traffic management, not multi-region etcd.
