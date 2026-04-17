# TLS Wildcard Setup (self-signed, 10 years)

Management guide for the single wildcard certificate used to terminate HTTPS traffic in the NGF Gateway API architecture.

<br/>

## Background

- The `example.com` domain is managed by Wix, which does not expose a DNS API
- → cert-manager ACME DNS-01 challenge is not possible (automatic Let's Encrypt wildcard issuance unavailable)
- → HTTP-01 does not support wildcards per the ACME specification
- **Decision**: manually generate a self-signed wildcard certificate and maintain it long-term (10 years)

<br/>

## Design Principles

- **Single centrally managed Secret**: one `wildcard-example-tls` in the `nginx-gateway` namespace covers cluster-wide HTTPS
- **Start with minimal SANs**: currently only `example.com` + `*.example.com` (covers Phase 4 Harbor/Vault and other core apps). Subdomains like `*.pm.example.com` are added on-demand — see "Subdomain Expansion" below
- **Gateway-layer ownership**: app charts know nothing about TLS — only the Gateway references the Secret
- **Forward-compatible migration**: Secret name/namespace are fixed so future cert-manager adoption swaps only the Secret content — Gateway and apps stay unchanged

<br/>

## Wildcard Depth Constraint

Same rules as ACME (Let's Encrypt) wildcards:

| SAN | Coverage | Example |
|---|---|---|
| `example.com` | Bare domain only | `example.com` ✓ |
| `*.example.com` | One subdomain level | `harbor.example.com` ✓, `foo.bar.example.com` ✗ |
| `*.pm.example.com` | Under `pm.example.com` only | `dev-admin.pm.example.com` ✓ |

→ A second-level wildcard (`*.pm.example.com`) requires a separate SAN. With self-signed, multiple SANs can live in a single certificate — so one cert can cover everything once expanded.

**Note**: To use the `*.pm.example.com` SAN, each `<X>.pm.example.com` DNS record must exist. The apex record `pm.example.com` is not required (TLS SAN matching operates on FQDNs). ApplicationSet hosts such as `dev-admin.pm.example.com` are already managed in Wix.

<br/>

## Certificate Generation (one-time or on expiry)

Current version — 2 SANs (`example.com` + `*.example.com`):

```bash
mkdir -p /tmp/wildcard-cert && cd /tmp/wildcard-cert

openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -subj "/CN=*.example.com/O=example/C=KR" \
  -addext "subjectAltName=DNS:example.com,DNS:*.example.com" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth,clientAuth" \
  -keyout wildcard.key -out wildcard.crt

# Verify
openssl x509 -in wildcard.crt -noout -subject -issuer -dates -ext subjectAltName
```

Expected output:
```
subject=CN=*.example.com, O=example, C=KR
issuer=CN=*.example.com, O=example, C=KR  (self-signed)
notBefore=Apr 17 03:02:09 2026 GMT
notAfter=Apr 14 03:02:09 2036 GMT
X509v3 Subject Alternative Name:
    DNS:example.com, DNS:*.example.com
```

To reissue with additional subdomain SANs, see "Subdomain Expansion" below.

<br/>

## Secret Creation (cluster deployment)

Assumes the `nginx-gateway` namespace already exists (after NGF helmfile apply).

```bash
kubectl -n nginx-gateway create secret tls wildcard-example-tls \
  --cert=wildcard.crt \
  --key=wildcard.key
```

Verify the Secret:
```bash
kubectl -n nginx-gateway get secret wildcard-example-tls
# NAME                   TYPE                DATA   AGE
# wildcard-example-tls   kubernetes.io/tls   2      0s
```

<br/>

## Local File Cleanup

Once the Secret is registered, delete local key/crt files — the cluster is the sole authoritative source.

```bash
cd /tmp/wildcard-cert
rm wildcard.key                   # private key must be deleted
# wildcard.crt may be kept for reference (not sensitive) or deleted
```

> **Security note**: Never commit `wildcard.key` to any git repository. It should live in `.gitignore` or, ideally, only exist in a temp directory like `/tmp` in the first place.

<br/>

## Gateway Integration

The `ngf` Gateway in `manifests/gateways.yaml` has one HTTPS listener referencing this Secret (current state):

```yaml
listeners:
  - name: https                     # covers *.example.com
    protocol: HTTPS
    port: 443
    hostname: "*.example.com"
    tls:
      mode: Terminate
      certificateRefs:
        - kind: Secret
          name: wildcard-example-tls
    allowedRoutes: { namespaces: { from: All } }
```

Apps attach via `parentRefs[*].sectionName: https` in their HTTPRoute:

| App host | sectionName |
|---|---|
| `harbor.example.com`, `grafana.example.com`, `kibana.example.com`, ... | `https` |

→ Subdomains (`*.pm.example.com`, etc.) are added via the expansion procedure below.

<br/>

## Browser Trust (self-signed → warning)

- User browsers will show a "Not Secure" warning because the cert chain is not trusted
- Internal users register a one-time exception or trust the CA on the client side
- Adding `wildcard.crt` to macOS Keychain, the Windows certificate store, or Firefox's CA store removes the warning
- Same UX as the existing `harbor-tls` and `vaultwarden-tls` (already self-signed)

<br/>

## Subdomain Expansion (adding `*.pm.example.com` etc.)

Example: Phase 5 ApplicationSet app cutover (`dev-admin.pm.example.com`, etc.).

### Step 1 — Reissue cert with additional SAN

```bash
cd /tmp/wildcard-cert

openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -subj "/CN=*.example.com/O=example/C=KR" \
  -addext "subjectAltName=DNS:example.com,DNS:*.example.com,DNS:*.pm.example.com" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth,clientAuth" \
  -keyout wildcard.key -out wildcard.crt

openssl x509 -in wildcard.crt -noout -ext subjectAltName
# → verify 3 SANs
```

### Step 2 — Replace the Secret

```bash
kubectl -n nginx-gateway create secret tls wildcard-example-tls \
  --cert=wildcard.crt --key=wildcard.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

The NGF data plane detects the Secret change and reloads nginx config automatically.

### Step 3 — Add a listener to the Gateway

Append a listener to the `ngf` Gateway in `manifests/gateways.yaml`:

```yaml
listeners:
  # existing listeners retained
  - name: http        { ... }
  - name: https       { ... }
  # new listener
  - name: https-pm
    protocol: HTTPS
    port: 443
    hostname: "*.pm.example.com"
    tls:
      mode: Terminate
      certificateRefs:
        - kind: Secret
          name: wildcard-example-tls      # same Secret, different SAN used
    allowedRoutes:
      namespaces:
        from: All
```

Commit + `helmfile apply` → NGF postsync hook updates the Gateway.

### Step 4 — Update app values

Add `sectionName: https-pm` to the `parentRefs` of HTTPRoutes under `*.pm.example.com`:

```yaml
httproute:
  parentRefs:
    - name: ngf
      namespace: nginx-gateway
      sectionName: https-pm
```

### Generalization for other subdomain zones

For any additional subdomain zone, repeat the same pattern:
1. Add `DNS:*.{zone}` to the cert SAN list → reissue with `openssl`
2. Replace the Secret
3. Add a `name: https-{zone}` listener in the Gateway (same Secret, only hostname differs)
4. Reference `sectionName: https-{zone}` in the app HTTPRoute

**Benefit**: Single Secret stays the source of truth (single rotation point). Only the Gateway listener count grows with the number of zones.

<br/>

## Renewal Procedure (after 10 years)

1. Re-run the "Certificate Generation" step above → new `wildcard.crt` / `wildcard.key`
2. Replace the existing Secret:
   ```bash
   kubectl -n nginx-gateway create secret tls wildcard-example-tls \
     --cert=wildcard.crt --key=wildcard.key \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
3. The NGF data plane detects the Secret change and reloads nginx config (a few seconds)
4. No Gateway/app changes needed

<br/>

## Future cert-manager Migration Path

If a DNS-API-capable provider is adopted later, or an internal CA is set up:

### Option A: Internal CA + cert-manager `ca` issuer
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: internal-ca }
spec:
  ca: { secretName: internal-ca-root }       # self-signed root pre-registered
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-example
  namespace: nginx-gateway
spec:
  secretName: wildcard-example-tls            # ← keep the existing Secret name
  dnsNames:
    - example.com
    - "*.example.com"
    - "*.pm.example.com"
  issuerRef: { kind: ClusterIssuer, name: internal-ca }
```

→ cert-manager overwrites the existing Secret. Zero Gateway/app changes.

### Option B: Let's Encrypt DNS-01 (after domain migration)
Issue via a `letsencrypt-prod-dns` ClusterIssuer against the same Secret name.

<br/>

## Relation to Existing Self-signed Certificates

| Existing Secret | Location | Disposition |
|---|---|---|
| `harbor-tls` | `harbor` ns | Removed during Phase 4 Harbor cutover, wildcard used instead |
| `vaultwarden-tls` | `vaultwarden` ns | Removed during Phase 4 vaultwarden cutover, wildcard used instead |

Two per-app manual rotation points → consolidated into one central wildcard.

<br/>

## References

- `manifests/gateways.yaml` — Gateway resource definition
- `README.md` — NGF overall operations guide
- `docs/tls-wildcard-setup.md` — Korean version of this document
