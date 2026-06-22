# MetalLB Helm Chart

Manages the [MetalLB](https://metallb.universe.tf/) load balancer on a Kubernetes cluster using Helmfile.

<br/>

## Directory Structure

```
metallb/
├── Chart.yaml                  # Version tracking (no local templates)
├── helmfile.yaml               # Helmfile release definitions (metallb + metallb-cr)
├── values.yaml                 # Upstream default values (auto-managed by upgrade.py)
├── values/
│   ├── dev-metallb.yaml        # Upstream chart overrides (ServiceMonitor, speaker scheduling)
│   └── dev-metallb-cr.yaml     # IPAddressPool + L2Advertisement config (somaz94/metallb-cr chart)
├── upgrade.py                  # Version upgrade script
├── backup/                     # Auto-backup on upgrade
├── README.md                   # Korean documentation
└── README-en.md                # English documentation
```

The upstream `metallb/metallb` chart does not template config CRs, so the
IPAddressPool / L2Advertisement resources are rendered by the `somaz94/metallb-cr`
chart as a second helmfile release (replacing the former out-of-band
`kubectl apply -f metallb-config.yaml` postsync hook).

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

# Deploy (MetalLB + config CRs applied automatically)
helmfile apply

# Destroy
helmfile destroy
```

> **Note:** `helmfile apply` deploys two releases — the upstream MetalLB chart and `metallb-cr` (config CRs).
> The `needs:` ordering plus the metallb release's `wait: true` apply the config CRs only after the controller Pod is ready, so the validating-webhook timing race does not occur.

<br/>

## MetalLB Config

Configure IP pools and L2 mode in `values/dev-metallb-cr.yaml` (rendered by the `somaz94/metallb-cr` chart).

```yaml
ipAddressPools:
  - name: ip-pool
    addresses:
      - 192.168.1.55-192.168.1.58
      - 192.168.1.62-192.168.1.75
    autoAssign: true

l2Advertisements:
  - name: l2-network
    ipAddressPools:
      - ip-pool
```

The CRs are applied automatically by `helmfile apply`. To inspect:

```bash
kubectl get ipaddresspool,l2advertisement -n metallb
```

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.py

# Preview changes only
./upgrade.py --dry-run

# Upgrade to a specific version
./upgrade.py --version 0.16.0
```

upgrade.py automatically performs the following:
1. Check current/latest version
2. Download Chart.yaml, values.yaml and compare diffs
3. Create backup then update files

### Rollback

```bash
./upgrade.py --list-backups
./upgrade.py --rollback
./upgrade.py --cleanup-backups
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
