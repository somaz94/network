# Ingress-Nginx Helm Chart (`_optional/` archive)

> **Status**: Retired on 2026-04-17. Fully replaced by [nginx-gateway-fabric](../../nginx-gateway-fabric/) (NGF 2.x).
> This directory is kept for rollback reference and Git history only.

Helmfile-based Ingress-Nginx controller configuration that was previously deployed on the cluster.

<br/>

## NGF migration complete (Phase 6/7 · 2026-04-17)

All 11 Helm releases (main `ingress-nginx` + `ingress-nginx-public-{a..j}`) and their associated Services, Deployments, VWCs, ServiceMonitors and the `ingress-nginx` Namespace were removed via `helmfile destroy`. MetalLB IPs `.55-.68` are now owned by the NGF `ngf` / `ngf-public-{a..j}` Gateways.

### Final cutover outcome

| # | Release | Real IP | Target app | Cutover · Destroy date |
|---|---|---|---|---|
| 1 | `ingress-nginx-public-a` | 192.168.1.56 | dev-example-project-game | 2026-04-17 |
| 2 | `ingress-nginx-public-b` | 192.168.1.57 | static-file-server | 2026-04-17 |
| 3 | `ingress-nginx-public-c` | 192.168.1.58 | staging-example-project-game | 2026-04-17 |
| 4 | `ingress-nginx-public-d` | 192.168.1.62 | staging-example-project-admin | 2026-04-17 |
| 5 | `ingress-nginx-public-e` | 192.168.1.63 | dev-example-project-app-admin | 2026-04-17 |
| 6 | `ingress-nginx-public-f` | 192.168.1.64 | dev-example-project-admin | 2026-04-17 |
| 7 | `ingress-nginx-public-g` | 192.168.1.65 | qa-example-project-game | 2026-04-17 |
| 8 | `ingress-nginx-public-h` | 192.168.1.66 | qa-example-project-admin | 2026-04-17 |
| 9 | `ingress-nginx-public-i` | 192.168.1.67 | qa-example-project-app-admin | 2026-04-17 |
| 10 | `ingress-nginx-public-j` | 192.168.1.68 | git-bridge | 2026-04-17 |
| 11 | `ingress-nginx` (main) | 192.168.1.55 | harbor/argocd/vaultwarden/observability stack/etc. (13 apps) | 2026-04-17 |

### Rollback (helm re-install)

This directory is an archive, so rolling back means moving the directory back to `network/ingress-nginx/` and running `helmfile apply`. Flip the NGF-side `manifests/nginxproxies.yaml` `loadBalancerIP` entries back to the temporary range (`.69-.75`) and `kubectl apply` as well.

Note: the MetalLB pool may have been narrowed (currently `.55-.75`, 21 addresses). Expand it via `../metallb/metallb-config.yaml` + `kubectl apply -f` if needed.

### Cutover lessons captured at the time (automated by `../../nginx-gateway-fabric/cutover.sh`)

- `kubectl scale --replicas=0` alone does not release the MetalLB IP → the Service must also be patched to `ClusterIP` with `spec.loadBalancerIP` removed.
- Delete the `<release>-admission` ValidatingWebhookConfiguration upfront, otherwise Ingress UPDATE/DELETE (including ArgoCD pruning) times out on the dead admission endpoint.
- `foregroundDeletion` finalizer could leave Ingress stuck → `kubectl patch ingress <name> -p '{"metadata":{"finalizers":null}}' --type=merge` (does not recur once the VWC is deleted upfront).
- NGF defaults to `externalTrafficPolicy: Local` → internal pod → LB-IP calls fail. All 11 NginxProxy CRs must explicitly set `Cluster`.

<br/>

## Directory Structure

```
ingress-nginx/
├── Chart.yaml              # Version tracking (no local templates)
├── helmfile.yaml           # Helmfile release definition (uses remote chart)
├── values.yaml             # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   ├── mgmt.yaml                # Default management release values
│   ├── mgmt-public-a.yaml      # Public release A values
│   ├── mgmt-public-b.yaml      # Public release B values
│   ├── mgmt-public-c.yaml      # Public release C values
│   ├── mgmt-public-d.yaml      # Public release D values
│   ├── mgmt-public-e.yaml      # Public release E values
│   ├── mgmt-public-f.yaml      # Public release F values
│   ├── mgmt-public-g.yaml      # Public release G values
│   ├── mgmt-public-h.yaml      # Public release H values
│   ├── mgmt-public-i.yaml      # Public release I values
│   └── mgmt-public-j.yaml      # Public release J values
├── upgrade.sh              # Version upgrade script
├── backup/                 # Auto-backup on upgrade
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- MetalLB or cloud LoadBalancer (for Service type: LoadBalancer)

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy (all 11 releases)
helmfile apply

# Deploy a specific release only
helmfile -l name=ingress-nginx apply

# Destroy
helmfile destroy
```

<br/>

## Releases

Composed of 11 Helm releases in total:

| Release | Values File | Description |
|---------|-------------|-------------|
| `ingress-nginx` | `values/mgmt.yaml` | Default management |
| `ingress-nginx-public-a` | `values/mgmt-public-a.yaml` | Public release A |
| `ingress-nginx-public-b` | `values/mgmt-public-b.yaml` | Public release B |
| `ingress-nginx-public-c` | `values/mgmt-public-c.yaml` | Public release C |
| `ingress-nginx-public-d` | `values/mgmt-public-d.yaml` | Public release D |
| `ingress-nginx-public-e` | `values/mgmt-public-e.yaml` | Public release E |
| `ingress-nginx-public-f` | `values/mgmt-public-f.yaml` | Public release F |
| `ingress-nginx-public-g` | `values/mgmt-public-g.yaml` | Public release G |
| `ingress-nginx-public-h` | `values/mgmt-public-h.yaml` | Public release H |
| `ingress-nginx-public-i` | `values/mgmt-public-i.yaml` | Public release I |
| `ingress-nginx-public-j` | `values/mgmt-public-j.yaml` | Public release J |

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 4.15.1
```

upgrade.sh automatically performs the following:
1. Check current/latest version
2. Download Chart.yaml, values.yaml and compare diffs
3. Create backup then update files

### Rollback

```bash
# List backups
./upgrade.sh --list-backups

# Restore from backup
./upgrade.sh --rollback

# Clean up old backups (keep latest 5)
./upgrade.sh --cleanup-backups
```

### Deploy After Upgrade

```bash
helmfile diff
helmfile apply
kubectl get pods -n ingress-nginx
```

<br/>

## Helmfile Commands Reference

```bash
helmfile lint           # Validate configuration
helmfile diff           # Preview changes
helmfile apply          # Apply
helmfile destroy        # Destroy
helmfile status         # Check status
```

<br/>

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| LoadBalancer IP not assigned | Check MetalLB configuration, `kubectl get svc -n ingress-nginx` |
| 404 Not Found | Verify ingressClassName in Ingress resource |
| Pod not starting | Check `kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller` |
| Admission webhook error | Check `kubectl get validatingwebhookconfigurations` and delete if necessary |

<br/>

## References

- https://kubernetes.github.io/ingress-nginx/
- https://github.com/kubernetes/ingress-nginx
- https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx
- [Grafana Dashboard 14314](https://grafana.com/grafana/dashboards/14314)
