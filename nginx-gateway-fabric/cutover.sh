#!/usr/bin/env bash
# Per-class Phase 6 cutover automation script
#
# Usage:
#   ./cutover.sh <class>
#     <class>: a..j (public class) or default (main nginx to ngf, run last)
#
# Steps:
#   [1] ingress-nginx Deployment → replicas=0
#   [2] ingress-nginx Service type → ClusterIP (release MetalLB real IP)
#   [3] Update IP and comment in the proxy block of manifests/nginxproxies.yaml
#   [4] kubectl diff preview then kubectl apply
#   [5] Wait for NGF Service EXTERNAL-IP (max 30s)
#   [6] Pre-delete ValidatingWebhookConfiguration to avoid blocking Ingress UPDATE and DELETE
#   [7] Smoke test by auto-detecting the first host of an attached HTTPRoute
#
# One user confirmation up front; idempotent during execution (already-applied steps are skipped).
#
# Manual follow-up steps (outside this script's scope):
#   - Toggle ingress.enabled to false in the related app values, then commit and push
#   - After ArgoCD prune, remove the finalizer if Ingress remains:
#       kubectl patch ingress <name> -n <ns> -p '{"metadata":{"finalizers":null}}' --type=merge

set -euo pipefail

# Resolve script path portably across bash and zsh (BASH_SOURCE -> $0 fallback).
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
unset _SCRIPT_PATH
MANIFEST="${SCRIPT_DIR}/manifests/nginxproxies.yaml"
NGF_NS="nginx-gateway"
ING_NS="ingress-nginx"

usage() {
  cat <<'EOF'
Usage: cutover.sh <class>

  <class>:
    a..j     : public class (individual)
    default  : main nginx -> ngf  (.69 -> .55, production critical -- run last)

Class mapping (temp IP -> real IP):
  a       : .70 -> .56    (ingress-nginx-public-a -> ngf-public-a)
  b       : .71 -> .57    (ingress-nginx-public-b -> ngf-public-b)
  c       : .72 -> .58    (ingress-nginx-public-c -> ngf-public-c)
  d       : .73 -> .62    (ingress-nginx-public-d -> ngf-public-d)
  e       : .74 -> .63    (ingress-nginx-public-e -> ngf-public-e)
  f       : .75 -> .64    (ingress-nginx-public-f -> ngf-public-f)
  g       : .76 -> .65    (ingress-nginx-public-g -> ngf-public-g)
  h       : .77 -> .66    (ingress-nginx-public-h -> ngf-public-h)
  i       : .78 -> .67    (ingress-nginx-public-i -> ngf-public-i)
  j       : .79 -> .68    (ingress-nginx-public-j -> ngf-public-j)
  default : .69 -> .55    (ingress-nginx -> ngf  <- last)
EOF
  exit 1
}

log()  { printf '\n\033[1;34m[cutover]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 2; }
confirm() { read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

# Argument parsing and class mapping ─────────────────────────
[[ $# -eq 1 ]] || usage
CLASS="$1"

case "$CLASS" in
  a) REAL=56; TEMP=70; ING_REL="ingress-nginx-public-a"; GW="ngf-public-a" ;;
  b) REAL=57; TEMP=71; ING_REL="ingress-nginx-public-b"; GW="ngf-public-b" ;;
  c) REAL=58; TEMP=72; ING_REL="ingress-nginx-public-c"; GW="ngf-public-c" ;;
  d) REAL=62; TEMP=73; ING_REL="ingress-nginx-public-d"; GW="ngf-public-d" ;;
  e) REAL=63; TEMP=74; ING_REL="ingress-nginx-public-e"; GW="ngf-public-e" ;;
  f) REAL=64; TEMP=75; ING_REL="ingress-nginx-public-f"; GW="ngf-public-f" ;;
  g) REAL=65; TEMP=76; ING_REL="ingress-nginx-public-g"; GW="ngf-public-g" ;;
  h) REAL=66; TEMP=77; ING_REL="ingress-nginx-public-h"; GW="ngf-public-h" ;;
  i) REAL=67; TEMP=78; ING_REL="ingress-nginx-public-i"; GW="ngf-public-i" ;;
  j) REAL=68; TEMP=79; ING_REL="ingress-nginx-public-j"; GW="ngf-public-j" ;;
  default|main|ngf) REAL=55; TEMP=69; ING_REL="ingress-nginx"; GW="ngf" ;;
  -h|--help) usage ;;
  *) echo "Unknown class: $CLASS"; usage ;;
esac

REAL_IP="192.0.2.${REAL}"
TEMP_IP="192.0.2.${TEMP}"
ING_DEP="${ING_REL}-controller"
ING_SVC="${ING_REL}-controller"
PROXY="${GW}-proxy"
NGF_SVC="${GW}-ngf"
VWC="${ING_REL}-admission"

# Dependency check ──────────────────────────────────
for bin in kubectl jq sed curl; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: ${bin}"
done
[[ -f "$MANIFEST" ]] || die "manifest not found: ${MANIFEST}"

# Preflight checks ───────────────────────────────────────
log "preflight: class=${CLASS} (${TEMP_IP} -> ${REAL_IP})"
log "  ingress-nginx release : ${ING_REL}"
log "  NGF gateway           : ${GW} (service: ${NGF_SVC})"
log "  NginxProxy CR         : ${PROXY}"
log "  VWC                   : ${VWC}"

# Verify ingress-nginx Deployment exists.
if ! kubectl get deploy "$ING_DEP" -n "$ING_NS" >/dev/null 2>&1; then
  die "ingress-nginx Deployment '${ING_DEP}' not found -- already destroyed or wrong class"
fi
ING_REPLICAS=$(kubectl get deploy "$ING_DEP" -n "$ING_NS" -o jsonpath='{.spec.replicas}')
ING_SVC_TYPE=$(kubectl get svc "$ING_SVC" -n "$ING_NS" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
NGF_CUR_IP=$(kubectl get svc "$NGF_SVC" -n "$NGF_NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
GW_PROG=$(kubectl get gateway "$GW" -n "$NGF_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")

log "  current state: ing-replicas=${ING_REPLICAS}, ing-svc-type=${ING_SVC_TYPE:-none}, ngf-ip=${NGF_CUR_IP:-none}, gw-programmed=${GW_PROG:-none}"

# Exit if everything is already done.
if [[ "$ING_REPLICAS" == "0" && "$ING_SVC_TYPE" == "ClusterIP" && "$NGF_CUR_IP" == "$REAL_IP" ]]; then
  log "this class is already cutover-complete. exiting with no action."
  exit 0
fi

# Validate that the state allows proceeding.
[[ "$GW_PROG" == "True" ]] || die "Gateway '${GW}' Programmed=${GW_PROG:-none} -- cannot proceed"

# Validate manifest structure.
grep -q "name: ${PROXY}\$" "$MANIFEST" || die "${PROXY} entry not found in ${MANIFEST}"

# Collect attached HTTPRoutes and pick the smoke-test host ──────
ROUTES_JSON=$(kubectl get httproute -A -o json)
ATTACHED_LIST=$(echo "$ROUTES_JSON" | jq -r --arg gw "$GW" --arg ns "$NGF_NS" \
  '.items[] | select(.spec.parentRefs[]? | .name == $gw and ((.namespace // $ns) == $ns)) | "\(.metadata.namespace)/\(.metadata.name)  hosts=\(.spec.hostnames // [] | join(","))"')
SMOKE_HOST=$(echo "$ROUTES_JSON" | jq -r --arg gw "$GW" --arg ns "$NGF_NS" \
  '[.items[] | select(.spec.parentRefs[]? | .name == $gw and ((.namespace // $ns) == $ns))][0].spec.hostnames[0] // empty')

if [[ -n "$ATTACHED_LIST" ]]; then
  log "HTTPRoutes attached to this Gateway (toggle ingress.enabled:false in their values):"
  echo "$ATTACHED_LIST" | sed 's/^/    /'
  log "smoke test host: ${SMOKE_HOST:-none}"
else
  warn "no HTTPRoute attached to this Gateway -- smoke test must be run manually"
fi

# Change summary and confirmation ────────────────────────────────
echo ""
log "change summary:"
log "  [1] kubectl scale deploy/${ING_DEP} -n ${ING_NS} --replicas=0"
log "  [2] kubectl patch svc ${ING_SVC} -n ${ING_NS} -> ClusterIP (release ${REAL_IP})"
log "  [3] sed: ${PROXY} block in manifest ${TEMP_IP} -> ${REAL_IP} + update comment"
log "  [4] kubectl diff -f manifests/nginxproxies.yaml  (preview)"
log "  [5] kubectl apply -f manifests/nginxproxies.yaml"
log "  [6] wait: ${NGF_SVC} EXTERNAL-IP -> ${REAL_IP}"
log "  [7] kubectl delete vwc ${VWC}"
log "  [8] smoke: curl --resolve ${SMOKE_HOST:-<none>}:80:${REAL_IP}"
log ""
log "expected downtime: ~30s-1min (between step [2] and step [5])"
echo ""
confirm "proceed?" || { log "cancelled by user"; exit 0; }

# Execution ────────────────────────────────────────────
if [[ "$ING_REPLICAS" == "0" ]]; then
  log "[1/8] scale=0 already applied, skip"
else
  log "[1/8] scale down ingress-nginx Deployment"
  kubectl scale deploy/"$ING_DEP" -n "$ING_NS" --replicas=0
fi

if [[ "$ING_SVC_TYPE" == "ClusterIP" ]]; then
  log "[2/8] Service already ClusterIP, skip"
else
  log "[2/8] ingress-nginx Service -> ClusterIP (release MetalLB IP)"
  kubectl patch svc "$ING_SVC" -n "$ING_NS" --type=json \
    -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"},{"op":"remove","path":"/spec/loadBalancerIP"}]'
fi

log "[3/8] edit manifest: ${TEMP_IP} -> ${REAL_IP} (${PROXY} block)"
# BSD sed compatible (macOS); block range spans from the name line through that block's loadBalancerIP line.
sed -i '' \
  -e "/name: ${PROXY}\$/,/loadBalancerIP/ s|\"${TEMP_IP}\"|\"${REAL_IP}\"|" \
  -e "/name: ${PROXY}\$/,/loadBalancerIP/ s|# Phase 1 temporary (will become ${REAL_IP} at cutover)|# Phase 6 cutover complete (was ${TEMP_IP})|" \
  "$MANIFEST"

log "[4/8] kubectl diff preview (exit 1 means diff present, normal)"
kubectl diff -f "$MANIFEST" || true

log "[5/8] kubectl apply"
kubectl apply -f "$MANIFEST"

log "[6/8] wait for NGF Service EXTERNAL-IP (max 30s)"
CUR=""
for i in $(seq 1 15); do
  CUR=$(kubectl get svc "$NGF_SVC" -n "$NGF_NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ "$CUR" == "$REAL_IP" ]]; then
    log "  ✓ ${NGF_SVC} EXTERNAL-IP = ${REAL_IP}"
    break
  fi
  sleep 2
done
[[ "$CUR" == "$REAL_IP" ]] || warn "timeout: current EXTERNAL-IP=${CUR:-none} (may be MetalLB announcement delay)"

log "[7/8] delete VWC: ${VWC}"
kubectl delete validatingwebhookconfiguration "$VWC" --ignore-not-found

log "[8/8] smoke test"
if [[ -n "$SMOKE_HOST" ]]; then
  # curl: on failure -w still prints 000 and exits non-zero; instead of appending `|| echo`,
  # suppress stderr and check success and failure separately.
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 --resolve "${SMOKE_HOST}:80:${REAL_IP}" "http://${SMOKE_HOST}/" 2>/dev/null)
  CODE="${CODE:-000}"
  if [[ "$CODE" != "000" && "$CODE" != "0" ]]; then
    log "  ✓ HTTP ${CODE}  host=${SMOKE_HOST}  ->  ${REAL_IP}  (backend reachable)"
  else
    warn "  curl connection failed -- check ARP cache or network path"
  fi
else
  warn "  no host detected -- manual verification required"
fi

# Follow-up guidance ───────────────────────────────────────
echo ""
log "✓ Cutover complete: class=${CLASS}  ${TEMP_IP} -> ${REAL_IP}"
echo ""
log "remaining manual steps:"
log "  1) Set \`ingress.enabled: false\` in the source values of each 'Gateway-attached HTTPRoute' above:"
log "     - ApplicationSet  : argocd-applicationset/values/<project>/<service>/<env>.values.yaml"
log "     - kuberntes-infra : values/dev.yaml or manifest of the component"
log "     - separate repos  : git-bridge, slack-qr-bot, etc. -- their k8s/deployment.yaml"
log "  2) commit + push, then ArgoCD/helmfile sync"
log "  3) If Ingress remains (finalizer stuck):"
log "       kubectl patch ingress <name> -n <ns> -p '{\"metadata\":{\"finalizers\":null}}' --type=merge"
log "  4) After ~1 week of observation, bulk 'helmfile destroy' this class's helm releases"
