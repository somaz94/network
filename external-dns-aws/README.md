# External-DNS (AWS Route53) Helm Chart (`_optional/`)

> **Status**: `_optional/` component. Enable only when the cluster fronts AWS-managed DNS zones (Route53). When promoting to active use, move to `network/external-dns-aws/` so it is included in sync drift checks.

Helmfile-managed deployment of [ExternalDNS](https://github.com/kubernetes-sigs/external-dns/) that synchronizes Kubernetes Service / Ingress hostnames into AWS Route53 records. Authentication is IRSA-based (IAM Role for Service Account on EKS).

<br/>

## Directory Structure

```
external-dns-aws/
├── Chart.yaml              # Version tracking only (no local templates)
├── helmfile.yaml           # Helmfile release definition (upstream chart)
├── values.yaml             # Upstream defaults (managed by upgrade.sh)
├── values.schema.json      # Values schema (shipped by upstream)
├── values/
│   └── mgmt.yaml           # Operational values (domain filter, IRSA Role ARN)
├── upgrade.sh              # Version bump script
├── backup/                 # Auto-generated backups (rollback trail)
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster (EKS recommended for IRSA)
- Helm 3, Helmfile
- AWS Route53 hosted zone (`example-app.secondary-projectsvc.com` or per-environment domain)
- IAM Role with `ChangeResourceRecordSets` / `ListResourceRecordSets` on the target zone, plus an IRSA trust policy
- A system nodegroup label (`eks.amazonaws.com/nodegroup` is used for placement)

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply

# Tear down
helmfile destroy
```

<br/>

## Configuration Highlights

- `domainFilters` — allow-list of domains under management. Defaults to `example-app.secondary-projectsvc.com`.
- `policy: upsert-only` — create when missing, update when present; deletion is left to humans.
- `registry: txt`, `txtOwnerId`, `txtPrefix` — ownership markers to avoid clobbering records owned by another ExternalDNS instance.
- `serviceAccount.annotations.eks.amazonaws.com/role-arn` — IRSA-bound IAM Role ARN. Replace per environment.
- `nodeSelector` — pins the pod to the system nodegroup.
- `extraArgs.--annotation-filter` — only objects carrying the matching annotation are reconciled.

<br/>

## Upgrade

```bash
# Check and bump to the latest version
./upgrade.sh

# Preview only
./upgrade.sh --dry-run

# Pin to a specific version
./upgrade.sh --version 1.20.0
```

`upgrade.sh` automates:
1. Resolving current and latest versions
2. Downloading and diffing `Chart.yaml` / `values.yaml`
3. Creating a backup before writing the new files

### Rollback

```bash
# List backups
./upgrade.sh --list-backups

# Restore from a backup
./upgrade.sh --rollback

# Prune old backups (keep the last 5)
./upgrade.sh --cleanup-backups
```

### After upgrading

```bash
helmfile diff
helmfile apply
kubectl get pods -n example-app -l app.kubernetes.io/name=external-dns
```

<br/>

## Helmfile Commands Reference

```bash
helmfile lint           # Validate
helmfile diff           # Preview
helmfile apply          # Apply
helmfile destroy        # Remove
helmfile status         # Status
```

<br/>

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Route53 records are not created | Verify the IRSA Role ARN matches and the IAM policy grants `Change/ListResourceRecordSets` |
| `AccessDenied: not authorized to perform: route53:ChangeResourceRecordSets` | Confirm the IAM policy Resource ARN matches the target zone |
| Pod Pending | Check that the `nodeSelector` label is present on the system nodegroup |
| Hostname not picked up | Confirm `domainFilters` matches the hosted zone domain |
| Record collisions with another instance | Ensure `txtOwnerId` / `txtPrefix` are unique per environment |

<br/>

## References

- https://kubernetes-sigs.github.io/external-dns/
- https://github.com/kubernetes-sigs/external-dns
- https://artifacthub.io/packages/helm/external-dns/external-dns
- [IRSA setup guide](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
