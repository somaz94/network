# External-DNS (AWS Route53) Helm Chart

> **Status**: Active component. Manages the Route53 zone `example.com` for the `prod-example-app-v1` cluster (eu-central-1, account 123456789012). Authentication uses an EKS Pod Identity association (namespace `external-dns` / SA `external-dns`).

Helmfile-managed deployment of [ExternalDNS](https://github.com/kubernetes-sigs/external-dns/) that synchronizes Kubernetes Service / Ingress hostnames into AWS Route53 records. Authentication is via an EKS Pod Identity association (no `role-arn` annotation on the SA).

<br/>

## Directory Structure

```
external-dns-aws/
├── Chart.yaml              # Version tracking only (no local templates)
├── helmfile.yaml           # Helmfile release definition (upstream chart)
├── values.yaml             # Upstream defaults (managed by upgrade.py)
├── values.schema.json      # Values schema (shipped by upstream)
├── values/
│   └── prod.yaml          # Operational values (domain filter, Pod Identity auth)
├── upgrade.py              # Version bump script
├── backup/                 # Auto-generated backups (rollback trail)
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster (EKS recommended for Pod Identity)
- Helm 3, Helmfile
- AWS Route53 hosted zone (`example.com` or per-environment domain)
- IAM Role with `ChangeResourceRecordSets` / `ListResourceRecordSets` on the target zone, plus a Pod Identity trust policy (`pods.eks.amazonaws.com`)
- A system nodegroup label (`nodegroup-workload=system` is used for placement)

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

- `domainFilters` — allow-list of domains under management. Defaults to `example.com`.
- `policy: upsert-only` — create when missing, update when present; deletion is left to humans.
- `registry: txt`, `txtOwnerId`, `txtPrefix` — ownership markers to avoid clobbering records owned by another ExternalDNS instance.
- `serviceAccount` — authenticated via a Pod Identity association, so no `eks.amazonaws.com/role-arn` annotation is needed. The IAM Role binding is owned by the Terraform `aws_eks_pod_identity_association`.
- `nodeSelector` — pins the pod to the system nodegroup.
- `extraArgs.--annotation-filter` — only objects carrying the matching annotation are reconciled.

<br/>

## Upgrade

```bash
# Check and bump to the latest version
./upgrade.py

# Preview only
./upgrade.py --dry-run

# Pin to a specific version
./upgrade.py --version 1.20.0
```

`upgrade.py` automates:
1. Resolving current and latest versions
2. Downloading and diffing `Chart.yaml` / `values.yaml`
3. Creating a backup before writing the new files

### Rollback

```bash
# List backups
./upgrade.py --list-backups

# Restore from a backup
./upgrade.py --rollback

# Prune old backups (keep the last 5)
./upgrade.py --cleanup-backups
```

### After upgrading

```bash
helmfile diff
helmfile apply
kubectl get pods -n external-dns -l app.kubernetes.io/name=external-dns
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
| Route53 records are not created | Verify the Pod Identity association is attached and the IAM policy grants `Change/ListResourceRecordSets` |
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
