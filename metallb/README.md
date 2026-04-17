# MetalLB Helm Chart

Manages the [MetalLB](https://metallb.universe.tf/) load balancer on a Kubernetes cluster using Helmfile.

<br/>

## Directory Structure

```
metallb/
├── Chart.yaml              # Version tracking (no local templates)
├── helmfile.yaml           # Helmfile release definition (uses remote chart)
├── values.yaml             # Upstream default values (auto-managed by upgrade.sh)
├── metallb-config.yaml     # IPAddressPool + L2Advertisement CRD configuration
├── upgrade.sh              # Version upgrade script
├── backup/                 # Auto-backup on upgrade
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- `strictARP: true` required when using kube-proxy ipvs mode

### kube-proxy strictARP Configuration (ipvs mode)

```bash
kubectl get configmap kube-proxy -n kube-system -o yaml | \
sed -e "s/strictARP: false/strictARP: true/" | \
kubectl apply -f - -n kube-system

kubectl rollout restart -n kube-system daemonset kube-proxy
```

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy (MetalLB + CRD config applied automatically)
helmfile apply

# Destroy
helmfile destroy
```

> **Note:** When running `helmfile apply`, the postsync hook automatically applies `metallb-config.yaml`.
> With the `wait: true` setting, it is applied after the controller Pod is ready, so webhook timing issues do not occur.

<br/>

## MetalLB Config

Configure IP pools and L2 mode in `metallb-config.yaml`.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ip-pool
  namespace: metallb
spec:
  addresses:
    - 192.168.1.55-192.168.1.58
    - 192.168.1.62-192.168.1.65
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-network
  namespace: metallb
spec:
  ipAddressPools:
    - ip-pool
```

If manual application is needed:

```bash
kubectl apply -f metallb-config.yaml
kubectl get ipaddresspool,l2advertisement -n metallb
```

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 0.16.0
```

upgrade.sh automatically performs the following:
1. Check current/latest version
2. Download Chart.yaml, values.yaml and compare diffs
3. Create backup then update files

### Rollback

```bash
./upgrade.sh --list-backups
./upgrade.sh --rollback
./upgrade.sh --cleanup-backups
```

### Deploy After Upgrade

```bash
helmfile diff
helmfile apply
kubectl get pods -n metallb
```

<br/>

## Verification

```bash
# Pod status
kubectl get pods -n metallb

# Check IP Pool
kubectl get ipaddresspool -n metallb

# Check L2 configuration
kubectl get l2advertisement -n metallb

# Webhook status
kubectl get validatingwebhookconfigurations | grep metallb
```

<br/>

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| IPAddressPool apply fails (webhook error) | Verify controller Pod is ready and retry, or use `helmfile apply` for automatic handling |
| LoadBalancer IP not assigned | Check IP pool with `kubectl get ipaddresspool -n metallb` |
| Speaker Pod CrashLoop | Check `kubectl logs -n metallb -l app.kubernetes.io/component=speaker` |

<br/>

## References

- https://metallb.universe.tf/
- https://github.com/metallb/metallb
- https://metallb.universe.tf/configuration/
