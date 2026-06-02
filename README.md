# network

Kubernetes networking components — ingress controllers, load balancers, gateway implementations, and DNS automation.

<br/>

## Components

| Component | Purpose | Type |
|---|---|---|
| [metallb](./metallb/) | Bare-metal `LoadBalancer` Service implementation (L2/BGP) | Helm |
| [ingress-nginx](./ingress-nginx/) | Ingress controller (NGINX). Multi-class deployment (mgmt + public-a..j) | Helm |
| [nginx-gateway-fabric](./nginx-gateway-fabric/) | Gateway API implementation (NGF) with local CR chart and per-class cutover automation | Helm + local CR chart |
| [external-dns-aws](./external-dns-aws/) | external-dns synced against AWS Route53 (IRSA) | Helm |
| [haproxy](./haproxy/) | Standalone HAProxy manifests (multipath examples) | Raw manifests |

<br/>

## Layout convention

Each Helm-based component follows the same shape:

```
<component>/
├── Chart.yaml          # Local chart wrapper (pins upstream version)
├── helmfile.yaml       # Helmfile release definition
├── values.yaml         # Upstream chart values (vendored for reference/diff)
├── values/             # Per-environment override files (mgmt.yaml, mgmt-public-*.yaml, ...)
├── upgrade.sh          # Idempotent upgrade helper
└── README.md           # Component-specific docs
```

Subdirectories that are not part of the runtime chart:

- `backup/` — versioned snapshots produced by `upgrade.sh` (kept across syncs).
- `docs/` — topic-specific guides (TLS setup, troubleshooting, migration notes).
- `cr-chart/` — local custom-resource chart (used by `nginx-gateway-fabric` for tenant-level Gateway/NginxProxy resources).
