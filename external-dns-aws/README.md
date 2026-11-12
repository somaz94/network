# External-DNS (AWS Route53) Helm Chart

> **Status**: Active component. Manages the Route53 zone `example.com` for the `example-app-prod` cluster (EKS Auto Mode, eu-central-1, account 123456789012). Authentication uses an EKS Pod Identity association (namespace `external-dns` / SA `external-dns`).

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns/) synchronizes Kubernetes Service / Ingress hostnames into AWS Route53 records. Authentication is via an EKS Pod Identity association (no `role-arn` annotation on the SA).

> **ArgoCD-managed**: delivered by ArgoCD. The chart-version SSOT is `chart.version` in `argocd-example-app-prod/external-dns.yaml`, which `upgrade.py` bumps (`CONFIG.ARGOCD_PIN_FILES`). The helmfile section below is **bootstrap only**.
>
> The marker and `values/prod.yaml` for the old `prod-example-app-v1` cluster were retired on 2026-11-10 and are kept under `_deprecated/network/external-dns-aws/`.

<br/>

## Directory Structure

```
external-dns-aws/
├── Chart.yaml                    # Version tracking only (no local templates)
├── argocd-example-app-prod/
│   └── external-dns.yaml         # example-app-prod ArgoCD release metadata (chart-version SSOT, autoSync)
├── helmfile.yaml.gotmpl          # 🔴 BOOTSTRAP-ONLY release definition (bringing up a new cluster)
├── values.yaml                   # Upstream defaults (managed by upgrade.py)
├── values.schema.json            # Values schema (shipped by upstream)
├── values/
│   └── example-app-prod.yaml     # Operational values (domain filter, Pod Identity auth, txtOwnerId / annotation-filter)
├── upgrade.py                    # Version bump script (bumps the marker pin)
├── backup/                       # Auto-generated backups (rollback trail)
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster (EKS recommended for Pod Identity)
- Helm 3, Helmfile
- AWS Route53 hosted zone (`example.com` or per-environment domain)
- IAM Role with `ChangeResourceRecordSets` / `ListResourceRecordSets` on the target zone, plus a Pod Identity trust policy (`pods.eks.amazonaws.com`)
- The Karpenter NodePool `platform` (label `nodegroup-workload=platform`, **taint `dedicated=platform:NoSchedule`**) — placement target. A Karpenter pool scales, so it is tainted, and `values/example-app-prod.yaml` therefore sets a **toleration** as well as the selector.

<br/>

## Quick Start

ArgoCD owns the deployment. Merge the change and the Application `example-app-prod-infra-external-dns`
picks it up — sync behaviour follows `autoSync` in the marker file.

```bash
kubectl get pods -n external-dns -l app.kubernetes.io/name=external-dns
```

### helmfile — bootstrap only

`helmfile.yaml.gotmpl` is used only when bringing up a **new cluster that has no ArgoCD yet** (something
has to publish the DNS record for ArgoCD's own ingress first). The template reads `.Values.valuesFile`,
which exists only under `environments.<env>`, so **always pass both `--kube-context` and `-e <env>`** — a
bare invocation renders nil. Picking the wrong pair points a second external-dns at the same Route53 zone
with the wrong ownership id.
Do not apply the `example-app-prod` environment: ArgoCD has already adopted that release, and the block stays only as the recipe for the next new cluster (see the `helmfile.yaml.gotmpl` header).

```bash
helmfile --kube-context <new-cluster> -e <new-cluster> diff
helmfile --kube-context <new-cluster> -e <new-cluster> apply
```

<br/>

## Configuration Highlights

- `domainFilters` — allow-list of domains under management. Defaults to `example.com`.
- `policy: upsert-only` — create when missing, update when present; deletion is left to humans.
- `registry: txt`, `txtOwnerId`, `txtPrefix` — ownership markers to avoid clobbering records owned by another ExternalDNS instance.
- `serviceAccount` — authenticated via a Pod Identity association, so no `eks.amazonaws.com/role-arn` annotation is needed. The IAM Role binding is owned by the Terraform `aws_eks_pod_identity_association`.
- `nodeSelector` + `tolerations` — pins the pod to the Karpenter `platform` pool.
- `extraArgs.--annotation-filter` — only objects carrying the matching annotation are reconciled.

<br/>

## Upgrade

```bash
# Check and bump to the latest version
./upgrade.py

# Preview only
./upgrade.py --dry-run

# Pin to a specific version
./upgrade.py --version <chart-version>
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
# upgrade.py rewrites chart.version in the marker file -> commit -> merge -> ArgoCD syncs
kubectl get pods -n external-dns -l app.kubernetes.io/name=external-dns
```

<br/>

## ArgoCD Release Reference

| Cluster | ArgoCD Application | Release metadata | Values |
|---|---|---|---|
| `example-app-prod` | `example-app-prod-infra-external-dns` | `argocd-example-app-prod/external-dns.yaml` | `values/example-app-prod.yaml` |

```bash
argocd app get  example-app-prod-infra-external-dns    # status
argocd app diff example-app-prod-infra-external-dns    # preview changes
```

<br/>

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Route53 records are not created | Verify the Pod Identity association is attached and the IAM policy grants `Change/ListResourceRecordSets` |
| `AccessDenied: not authorized to perform: route53:ChangeResourceRecordSets` | Confirm the IAM policy Resource ARN matches the target zone |
| Pod Pending | Check that a `platform` pool node comes up and the values carry both the `nodeSelector` and the toleration |
| Hostname not picked up | Confirm `domainFilters` matches the hosted zone domain |
| Record collisions with another instance | Ensure `txtOwnerId` / `txtPrefix` are unique per environment |

<br/>

## References

- https://kubernetes-sigs.github.io/external-dns/
- https://github.com/kubernetes-sigs/external-dns
- https://artifacthub.io/packages/helm/external-dns/external-dns
- [IRSA setup guide](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
