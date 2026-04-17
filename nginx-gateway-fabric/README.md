# NGINX Gateway Fabric (NGF)

[NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric) — official NGINX implementation of the Kubernetes Gateway API. Replaces the legacy `ingress-nginx` deployment.

Maps the 11 IngressClasses (`nginx`, `nginx-public-a~j`) 1:1 to 11 GatewayClasses (`ngf`, `ngf-public-a~j`); each Gateway gets its own LoadBalancer IP.

<br/>

## Directory Structure

```
nginx-gateway-fabric/
├── Chart.yaml                   # NGF chart version tracking (version + appVersion = single source)
├── helmfile.yaml.gotmpl         # helmfile go template (reads Chart.yaml)
├── values.yaml                  # Upstream NGF defaults (managed by upgrade.sh, placeholder)
├── values/
│   └── mgmt.yaml                # Controller custom settings (replicas, metrics, etc.)
├── manifests/                   # Raw CRs applied via postsync hook
│   ├── gatewayclasses.yaml      # 11 GatewayClass
│   ├── gateways.yaml            # 11 Gateway (Phase 1: HTTP listener only)
│   └── nginxproxies.yaml        # 11 NginxProxy (pins LoadBalancer IP)
├── upgrade.sh                   # external-oci canonical (auto-detects latest via GitHub Releases API)
├── README.md / README-en.md
└── backup/
```

<br/>

## Architecture

- **Single controller**: one NGF install in `nginx-gateway` namespace
- **Per-Gateway data plane**: NGF 2.x auto-provisions an independent nginx Deployment per Gateway CR
- **GatewayClass = tenancy boundary**: 11 classes preserve tenant separation
- **NginxProxy CR**: per-Gateway data plane settings (LoadBalancer IP, etc.)

### Single Source of Truth

`Chart.yaml`'s `version` and `appVersion` are the single source of truth.

- `version` (chart version) → `helmfile.yaml.gotmpl` `releases[].version`
- `appVersion` (NGF software = git tag) → `helmfile.yaml.gotmpl` hook URL `?ref=v...`

helmfile reads both via `readFile "Chart.yaml" | fromYaml`. **Bump Chart.yaml only — helmfile.yaml.gotmpl needs no edit; everything stays in sync.**

<br/>

## Documentation

| Topic | Document |
|---|---|
| TLS wildcard certificate setup (self-signed, 10 years) | [docs/tls-wildcard-setup-en.md](docs/tls-wildcard-setup-en.md) |

<br/>

## Prerequisites

- Kubernetes 1.25+
- Helm 3.8+ (OCI registry support)
- Helmfile
- MetalLB (pool: `192.168.1.55-58, 62-79`)

> **Note:** `192.168.1.80` is reserved/unusable. NGF Phase 1 temporary IPs are constrained to `.69-.79` (all 11 Gateways covered).

<br/>

## Quick Start

```bash
helmfile lint
helmfile diff

# Apply (3 stages auto-executed):
#   1. presync: Gateway API standard CRDs (pinned by NGF appVersion)
#   2. release: NGF Helm chart
#   3. postsync: GatewayClass / Gateway / NginxProxy from manifests/
helmfile apply

helmfile destroy
# Note: manifests/ resources and Gateway API CRDs aren't owned by the helm release;
# clean up separately:
#   kubectl delete -f manifests/
#   kubectl delete -f https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v<APP_VER>
```

<br/>

## Verification

```bash
kubectl get pods -n nginx-gateway
kubectl get crd | grep -E 'gateway.networking.k8s.io|gateway.nginx.org'
kubectl get gatewayclass
kubectl get gateway -n nginx-gateway -o wide
kubectl get svc -n nginx-gateway -o custom-columns=\
NAME:.metadata.name,TYPE:.spec.type,IP:.status.loadBalancer.ingress[0].ip
```

<br/>

## Phase 1 Temporary IPs

All 11 Gateways use **temporary IPs** during Phase 1 so they are fully isolated from the live ingress-nginx. Cutover (Phase 6) swaps them for the real IPs.

| GatewayClass | Phase 1 temp IP | Phase 6 real IP |
|---|---|---|
| ngf | 192.168.1.69 | 192.168.1.55 |
| ngf-public-a | 192.168.1.70 | 192.168.1.56 |
| ngf-public-b | 192.168.1.71 | 192.168.1.57 |
| ngf-public-c | 192.168.1.72 | 192.168.1.58 |
| ngf-public-d | 192.168.1.73 | 192.168.1.62 |
| ngf-public-e | 192.168.1.74 | 192.168.1.63 |
| ngf-public-f | 192.168.1.75 | 192.168.1.64 |
| ngf-public-g | 192.168.1.76 | 192.168.1.65 |
| ngf-public-h | 192.168.1.77 | 192.168.1.66 |
| ngf-public-i | 192.168.1.78 | 192.168.1.67 |
| ngf-public-j | 192.168.1.79 | 192.168.1.68 |

No LB IP conflict with ingress-nginx → both can coexist throughout Phase 1-5.

<br/>

## Upgrade

NGF is shipped as an **OCI Helm chart**, so `helm search repo` does not work. The `external-oci.sh` canonical instead queries the GitHub Releases API (`api.github.com/repos/nginx/nginx-gateway-fabric/releases/latest`) to discover the latest tag.

```bash
# Auto-detect (latest release tag → strip 'v' prefix → chart version)
./upgrade.sh --dry-run
./upgrade.sh

# Pin a specific version
./upgrade.sh --version 2.6.0
```

> **GitHub API rate limit**: 60 req/h anonymous. For CI or high-frequency use, set `GITHUB_TOKEN=ghp_...` for authenticated calls (5,000 req/h).

`./upgrade.sh` updates `Chart.yaml`'s `version` and `appVersion`. The helmfile.yaml.gotmpl needs no edit — helmfile picks up the new versions on the next `helmfile diff`/`apply`.

```bash
helmfile diff
helmfile apply
```

### Rollback

```bash
./upgrade.sh --list-backups
./upgrade.sh --rollback
helmfile diff
helmfile apply
```

<br/>

## NGF Version → Gateway API CRD Version Mapping

The NGF repo provides a Gateway API CRD bundle pinned to its own version at `config/crd/gateway-api/standard?ref=v<NGF_VER>`. The `helmfile.yaml.gotmpl` references this automatically, so no separate Gateway API CRD chart/release is needed.

For the exact Gateway API version used, see `https://github.com/nginx/nginx-gateway-fabric/blob/v<APP_VER>/config/crd/gateway-api/standard/`.

<br/>

## Troubleshooting

| Symptom | Resolution |
|---------|-----------|
| `Gateway PROGRAMMED=False, ListenerInvalidCertificateRef` | Phase 1 has only HTTP listeners; n/a. After HTTPS is added in Phase 3+, verify the cert Secret |
| `NginxProxy not found` | Confirm the `manifests/` postsync hook ran. `kubectl get nginxproxy -n nginx-gateway` |
| `LoadBalancer Service Pending` | Check MetalLB pool (`kubectl -n metallb get ipaddresspool`). Must contain the requested IP within `.55-58, .62-75` |
| LB IP collision in Phase 1 | The IP is currently held by ingress-nginx. Switch to a temp IP (`.69-.75`) or scale down the conflicting ingress-nginx release first |
| `helmfile.yaml.gotmpl` not recognized | Requires helmfile 0.140+. Check with `helmfile --version` |

<br/>

## References

- https://docs.nginx.com/nginx-gateway-fabric/
- https://github.com/nginx/nginx-gateway-fabric/releases
- https://gateway-api.sigs.k8s.io/
- Migration plan: `~/.claude/plans/humming-frolicking-giraffe.md`
