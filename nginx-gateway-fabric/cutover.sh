#!/usr/bin/env bash
# Per-class Phase 6 cutover automation script
#
# Usage
#   ./cutover.sh <class>
#     <class>: a..j (public class) or default (main nginx to ngf, run last)
#
# Steps
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

# Resolve script path portably across bash and zsh
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
    a..j     : public 클래스 (개별)
    default  : main nginx → ngf  (.69 → .55, 프로덕션 핵심 — 마지막 실행)

클래스 매핑 (임시 IP → 실 IP):
  a       : .70 → .56    (ingress-nginx-public-a → ngf-public-a)
  b       : .71 → .57    (ingress-nginx-public-b → ngf-public-b)
  c       : .72 → .58    (ingress-nginx-public-c → ngf-public-c)
  d       : .73 → .62    (ingress-nginx-public-d → ngf-public-d)
  e       : .74 → .63    (ingress-nginx-public-e → ngf-public-e)
  f       : .75 → .64    (ingress-nginx-public-f → ngf-public-f)
  g       : .76 → .65    (ingress-nginx-public-g → ngf-public-g)
  h       : .77 → .66    (ingress-nginx-public-h → ngf-public-h)
  i       : .78 → .67    (ingress-nginx-public-i → ngf-public-i)
  j       : .79 → .68    (ingress-nginx-public-j → ngf-public-j)
  default : .69 → .55    (ingress-nginx → ngf  ← 마지막)
EOF
  exit 1
}

log()  { printf '\n\033[1;34m[cutover]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 2; }
confirm() { read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

# Argument parsing and class mapping
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

REAL_IP="192.168.1.${REAL}"
TEMP_IP="192.168.1.${TEMP}"
ING_DEP="${ING_REL}-controller"
ING_SVC="${ING_REL}-controller"
PROXY="${GW}-proxy"
NGF_SVC="${GW}-ngf"
VWC="${ING_REL}-admission"

# Dependency check
for bin in kubectl jq sed curl; do
  command -v "$bin" >/dev/null 2>&1 || die "필수 도구 없음: ${bin}"
done
[[ -f "$MANIFEST" ]] || die "manifest 없음: ${MANIFEST}"

# Preflight checks
log "사전 검증: class=${CLASS} (${TEMP_IP} → ${REAL_IP})"
log "  ingress-nginx release : ${ING_REL}"
log "  NGF gateway           : ${GW} (service: ${NGF_SVC})"
log "  NginxProxy CR         : ${PROXY}"
log "  VWC                   : ${VWC}"

# Verify ingress-nginx Deployment exists
if ! kubectl get deploy "$ING_DEP" -n "$ING_NS" >/dev/null 2>&1; then
  die "ingress-nginx Deployment '${ING_DEP}' 없음 — 이미 destroy 됐거나 잘못된 클래스"
fi
ING_REPLICAS=$(kubectl get deploy "$ING_DEP" -n "$ING_NS" -o jsonpath='{.spec.replicas}')
ING_SVC_TYPE=$(kubectl get svc "$ING_SVC" -n "$ING_NS" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
NGF_CUR_IP=$(kubectl get svc "$NGF_SVC" -n "$NGF_NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
GW_PROG=$(kubectl get gateway "$GW" -n "$NGF_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")

log "  현재 상태: ing-replicas=${ING_REPLICAS}, ing-svc-type=${ING_SVC_TYPE:-없음}, ngf-ip=${NGF_CUR_IP:-없음}, gw-programmed=${GW_PROG:-없음}"

# Exit if everything is already done
if [[ "$ING_REPLICAS" == "0" && "$ING_SVC_TYPE" == "ClusterIP" && "$NGF_CUR_IP" == "$REAL_IP" ]]; then
  log "이 클래스는 이미 cutover 완료 상태입니다. 아무 작업 없이 종료."
  exit 0
fi

# Validate that the state allows proceeding
[[ "$GW_PROG" == "True" ]] || die "Gateway '${GW}' Programmed=${GW_PROG:-없음} — 진행 불가"

# Validate manifest structure
grep -q "name: ${PROXY}\$" "$MANIFEST" || die "${MANIFEST} 에 ${PROXY} 항목 없음"

# Collect attached HTTPRoutes and pick the smoke-test host
ROUTES_JSON=$(kubectl get httproute -A -o json)
ATTACHED_LIST=$(echo "$ROUTES_JSON" | jq -r --arg gw "$GW" --arg ns "$NGF_NS" \
  '.items[] | select(.spec.parentRefs[]? | .name == $gw and ((.namespace // $ns) == $ns)) | "\(.metadata.namespace)/\(.metadata.name)  hosts=\(.spec.hostnames // [] | join(","))"')
SMOKE_HOST=$(echo "$ROUTES_JSON" | jq -r --arg gw "$GW" --arg ns "$NGF_NS" \
  '[.items[] | select(.spec.parentRefs[]? | .name == $gw and ((.namespace // $ns) == $ns))][0].spec.hostnames[0] // empty')

if [[ -n "$ATTACHED_LIST" ]]; then
  log "이 Gateway 에 부착된 HTTPRoute (values ingress.enabled:false 토글 대상):"
  echo "$ATTACHED_LIST" | sed 's/^/    /'
  log "스모크 테스트 호스트: ${SMOKE_HOST:-없음}"
else
  warn "이 Gateway 에 부착된 HTTPRoute 없음 — 스모크 테스트는 직접 실행 필요"
fi

# Change summary and confirmation
echo ""
log "변경 요약:"
log "  [1] kubectl scale deploy/${ING_DEP} -n ${ING_NS} --replicas=0"
log "  [2] kubectl patch svc ${ING_SVC} -n ${ING_NS} → ClusterIP (${REAL_IP} 해제)"
log "  [3] sed: manifest 내 ${PROXY} 블록 ${TEMP_IP} → ${REAL_IP} + 주석 갱신"
log "  [4] kubectl diff -f manifests/nginxproxies.yaml  (프리뷰)"
log "  [5] kubectl apply -f manifests/nginxproxies.yaml"
log "  [6] wait: ${NGF_SVC} EXTERNAL-IP → ${REAL_IP}"
log "  [7] kubectl delete vwc ${VWC}"
log "  [8] smoke: curl --resolve ${SMOKE_HOST:-<없음>}:80:${REAL_IP}"
log ""
log "예상 다운타임: ~30초-1분 (step [2] ~ step [5] 구간)"
echo ""
confirm "진행하시겠습니까?" || { log "사용자 취소"; exit 0; }

# Execution
if [[ "$ING_REPLICAS" == "0" ]]; then
  log "[1/8] scale=0 이미 적용됨, 스킵"
else
  log "[1/8] ingress-nginx Deployment 스케일 다운"
  kubectl scale deploy/"$ING_DEP" -n "$ING_NS" --replicas=0
fi

if [[ "$ING_SVC_TYPE" == "ClusterIP" ]]; then
  log "[2/8] Service 이미 ClusterIP, 스킵"
else
  log "[2/8] ingress-nginx Service → ClusterIP (MetalLB IP 해제)"
  kubectl patch svc "$ING_SVC" -n "$ING_NS" --type=json \
    -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"},{"op":"remove","path":"/spec/loadBalancerIP"}]'
fi

log "[3/8] manifest 편집: ${TEMP_IP} → ${REAL_IP} (${PROXY} 블록)"
# BSD sed compatible (macOS); block range spans from the name line through that block's loadBalancerIP line.
sed -i '' \
  -e "/name: ${PROXY}\$/,/loadBalancerIP/ s|\"${TEMP_IP}\"|\"${REAL_IP}\"|" \
  -e "/name: ${PROXY}\$/,/loadBalancerIP/ s|# Phase 1 임시 (cutover 시 ${REAL_IP})|# Phase 6 cutover 완료 (was ${TEMP_IP})|" \
  "$MANIFEST"

log "[4/8] kubectl diff 프리뷰 (exit 1은 diff 있음을 의미, 정상)"
kubectl diff -f "$MANIFEST" || true

log "[5/8] kubectl apply"
kubectl apply -f "$MANIFEST"

log "[6/8] NGF Service EXTERNAL-IP 대기 (max 30s)"
CUR=""
for i in $(seq 1 15); do
  CUR=$(kubectl get svc "$NGF_SVC" -n "$NGF_NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ "$CUR" == "$REAL_IP" ]]; then
    log "  ✓ ${NGF_SVC} EXTERNAL-IP = ${REAL_IP}"
    break
  fi
  sleep 2
done
[[ "$CUR" == "$REAL_IP" ]] || warn "타임아웃: 현재 EXTERNAL-IP=${CUR:-없음} (MetalLB announcement 지연일 수 있음)"

log "[7/8] VWC 삭제: ${VWC}"
kubectl delete validatingwebhookconfiguration "$VWC" --ignore-not-found

log "[8/8] 스모크 테스트"
if [[ -n "$SMOKE_HOST" ]]; then
  # curl: on failure -w still prints 000 and exits non-zero; instead of appending `|| echo`,
  # suppress stderr and check success and failure separately.
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 --resolve "${SMOKE_HOST}:80:${REAL_IP}" "http://${SMOKE_HOST}/" 2>/dev/null)
  CODE="${CODE:-000}"
  if [[ "$CODE" != "000" && "$CODE" != "0" ]]; then
    log "  ✓ HTTP ${CODE}  host=${SMOKE_HOST}  →  ${REAL_IP}  (백엔드 도달 성공)"
  else
    warn "  curl 연결 실패 — ARP 캐시 또는 네트워크 경로 확인"
  fi
else
  warn "  호스트 미검출 — 수동 확인 필요"
fi

# Follow-up guidance
echo ""
log "✓ Cutover 완료: class=${CLASS}  ${TEMP_IP} → ${REAL_IP}"
echo ""
log "남은 수동 작업:"
log "  1) 위 'Gateway 부착 HTTPRoute' 각각의 소스 values에서 \`ingress.enabled: false\`:"
log "     - ApplicationSet  : argocd-applicationset/values/<project>/<service>/<env>.values.yaml"
log "     - kuberntes-infra : 해당 컴포넌트의 values/mgmt.yaml 또는 manifest"
log "     - 별도 레포       : git-bridge, slack-qr-bot 등 해당 레포 k8s/deployment.yaml"
log "  2) 커밋·푸시 후 ArgoCD/helmfile sync"
log "  3) 만약 Ingress 가 잔존한다면 (finalizer stuck):"
log "       kubectl patch ingress <name> -n <ns> -p '{\"metadata\":{\"finalizers\":null}}' --type=merge"
log "  4) 이 클래스의 helm release 는 ~1주 관측 후 일괄 'helmfile destroy' 대상"
