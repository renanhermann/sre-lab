#!/usr/bin/env bash
#
# install-oke-stack.sh — sobe OKE com a stack completa do SRE Lab
#
# Sequência:
#   1. terraform apply (01-oke) → cluster + node pool
#   2. kubeconfig em ~/.kube/config-oci
#   3. kube-prometheus-stack (monitoring)
#   4. loki + alloy (logging)
#   5. ImagePullSecret OCIR
#   6. App + SLO manifests
#   7. ingress-nginx (Fase 5) → LB OCI Always Free
#   8. cert-manager + ClusterIssuers Let's Encrypt
#   9. Grafana Ingress com hostname nip.io + TLS
#   10. OpenCost + FinOps recording rules + dashboard + alertas (Fase 6)
#
# Uso:
#   ./cluster/install-oke-stack.sh                     # tudo (~25 min)
#   ./cluster/install-oke-stack.sh --skip-terraform    # assume cluster já up
#   ./cluster/install-oke-stack.sh --skip-ingress      # pula Fase 5 (sem URL pública)
#   ./cluster/install-oke-stack.sh --skip-finops       # pula Fase 6
#
# Pré-requisitos:
#   - terraform, oci-cli, kubectl, helm, docker instalados
#   - ~/.oci/config configurado
#   - Foundation (00-foundation) já aplicada
#   - Imagem traffic-simulator:latest já pushada pro OCIR
#
# Exit codes:
#   0  sucesso
#   1  pré-requisito faltando
#   2  terraform apply falhou
#   3  helm install falhou
#   10 timeout esperando recurso

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }

# ── Flags ───────────────────────────────────────────────────────────────
SKIP_TERRAFORM=false
SKIP_INGRESS=false
SKIP_FINOPS=false
OCI_USER_ID="${OCI_USER_ID:-}"
OCIR_USERNAME="${OCIR_USERNAME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-terraform) SKIP_TERRAFORM=true; shift ;;
    --skip-ingress)   SKIP_INGRESS=true;   shift ;;
    --skip-finops)    SKIP_FINOPS=true;    shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "flag desconhecida: $1"; exit 1 ;;
  esac
done

export KUBECONFIG="${HOME}/.kube/config-oci"

# ── Pré-checagens ───────────────────────────────────────────────────────
log "verificando pré-requisitos..."
for cmd in terraform oci kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd não instalado"; exit 1
  fi
done
ok "ferramentas ok"

# ─────────────────────────────────────────────────────────────────────────
# 1. Terraform apply (cluster + node pool)
# ─────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_TERRAFORM" == "false" ]]; then
  log "==> [1/10] terraform apply (cluster OKE + node pool) — ~10min"
  cd "${REPO_ROOT}/terraform/01-oke"
  terraform init -upgrade >/dev/null 2>&1 || { err "terraform init"; exit 2; }
  terraform apply -auto-approve -no-color || { err "terraform apply"; exit 2; }

  CLUSTER_ID=$(terraform output -raw cluster_id)
  ok "cluster criado: ${CLUSTER_ID:0:50}..."

  log "==> gerando kubeconfig"
  oci ce cluster create-kubeconfig \
    --cluster-id "$CLUSTER_ID" \
    --file "$KUBECONFIG" \
    --region sa-saopaulo-1 \
    --token-version 2.0.0 \
    --overwrite >/dev/null 2>&1
else
  warn "==> [1/10] terraform apply: SKIPPED"
fi

log "==> verificando nodes ready"
until [[ $(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ") -ge 2 ]]; do
  sleep 5
done
ok "$(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes ready"

# ─────────────────────────────────────────────────────────────────────────
# 2. kube-prometheus-stack
# ─────────────────────────────────────────────────────────────────────────
log "==> [2/10] kube-prometheus-stack"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo update prometheus-community >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f "${REPO_ROOT}/helm/oke/kube-prometheus-stack-values.yaml" \
  --wait --timeout 8m >/dev/null || { err "helm install kube-prom-stack"; exit 3; }
ok "observabilidade instalada"

# ─────────────────────────────────────────────────────────────────────────
# 3. Loki + Alloy
# ─────────────────────────────────────────────────────────────────────────
log "==> [3/10] Loki + Alloy"
kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1
helm repo update grafana >/dev/null
helm upgrade --install loki grafana/loki -n logging \
  -f "${REPO_ROOT}/helm/oke/loki-values.yaml" --wait --timeout 5m >/dev/null || { err "loki"; exit 3; }
helm upgrade --install alloy grafana/alloy -n logging \
  -f "${REPO_ROOT}/helm/oke/alloy-values.yaml" --wait --timeout 3m >/dev/null || { err "alloy"; exit 3; }
ok "logging instalado"

# ─────────────────────────────────────────────────────────────────────────
# 4. ImagePullSecret OCIR
# ─────────────────────────────────────────────────────────────────────────
log "==> [4/10] ImagePullSecret OCIR"
if kubectl -n default get secret ocirsecret >/dev/null 2>&1; then
  warn "secret 'ocirsecret' já existe — pulando criação"
else
  if [[ -z "$OCI_USER_ID" ]]; then
    OCI_USER_ID=$(oci iam user list --query 'data[0].id' --raw-output 2>/dev/null)
  fi
  if [[ -z "$OCIR_USERNAME" ]]; then
    NS=$(oci os ns get --query 'data' --raw-output 2>/dev/null)
    EMAIL=$(oci iam user get --user-id "$OCI_USER_ID" --query 'data.name' --raw-output 2>/dev/null)
    OCIR_USERNAME="${NS}/${EMAIL}"
  fi

  log "criando auth token (cuidado: cada user OCI tem limite de 2 tokens)"
  TOKEN_FILE=$(mktemp)
  trap "rm -f $TOKEN_FILE" EXIT

  oci iam auth-token create \
    --user-id "$OCI_USER_ID" \
    --description "OCIR install-stack $(date +%s)" \
    --query 'data.token' --raw-output 2>/dev/null > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  kubectl create secret docker-registry ocirsecret \
    --docker-server=sa-saopaulo-1.ocir.io \
    --docker-username="$OCIR_USERNAME" \
    --docker-password="$(cat $TOKEN_FILE)" \
    -n default >/dev/null
  rm -f "$TOKEN_FILE"
  ok "ocirsecret criado"
fi

# ─────────────────────────────────────────────────────────────────────────
# 5. App + SLO
# ─────────────────────────────────────────────────────────────────────────
log "==> [5/10] App + SLO manifests"
kubectl apply \
  -f "${REPO_ROOT}/manifests/oke/app/deployment.yaml" \
  -f "${REPO_ROOT}/manifests/app/service.yaml" \
  -f "${REPO_ROOT}/manifests/app/hpa.yaml" \
  -f "${REPO_ROOT}/manifests/app/pdb.yaml" \
  -f "${REPO_ROOT}/manifests/app/servicemonitor.yaml" \
  -f "${REPO_ROOT}/manifests/app/prometheusrule.yaml" \
  -f "${REPO_ROOT}/manifests/slo/" >/dev/null
ok "app + SLO aplicados"

# ─────────────────────────────────────────────────────────────────────────
# 6. ingress-nginx (Fase 5)
# ─────────────────────────────────────────────────────────────────────────
LB_IP=""
if [[ "$SKIP_INGRESS" == "false" ]]; then
  log "==> [6/10] ingress-nginx + LB OCI"
  kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1
  helm repo update ingress-nginx >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    -f "${REPO_ROOT}/helm/oke/ingress-nginx-values.yaml" \
    --wait --timeout 5m >/dev/null || { err "ingress-nginx"; exit 3; }

  log "==> esperando LB ter EXTERNAL-IP (até 5min)"
  for i in $(seq 1 60); do
    LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [[ -n "$LB_IP" ]] && break
    sleep 5
  done
  if [[ -z "$LB_IP" ]]; then
    err "LB não recebeu IP em 5min"; exit 10
  fi
  ok "LB IP: $LB_IP"

  # ── 7. cert-manager + Issuers
  log "==> [7/10] cert-manager + Let's Encrypt"
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1
  helm repo update jetstack >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager \
    -f "${REPO_ROOT}/helm/oke/cert-manager-values.yaml" \
    --wait --timeout 4m >/dev/null || { err "cert-manager"; exit 3; }
  kubectl apply -f "${REPO_ROOT}/manifests/oke/ingress/clusterissuer-letsencrypt.yaml" >/dev/null
  ok "cert-manager + 2 ClusterIssuers (staging + prod)"

  # ── 8. Grafana Ingress com TLS
  log "==> [8/10] Grafana Ingress (grafana.${LB_IP//./-}.nip.io)"
  LB_HYPHEN="${LB_IP//./-}"
  sed "s/__LB_IP__/${LB_HYPHEN}/g" \
    "${REPO_ROOT}/manifests/oke/ingress/grafana-ingress.yaml" | kubectl apply -f - >/dev/null
  ok "ingress aplicado — aguarde ~1min pro cert ser emitido"
else
  warn "==> [6-8/10] ingress + cert-manager + grafana ingress: SKIPPED"
fi

# ─────────────────────────────────────────────────────────────────────────
# 9-10. FinOps (Fase 6)
# ─────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_FINOPS" == "false" ]]; then
  log "==> [9/10] OpenCost"
  kubectl create namespace opencost --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null 2>&1
  helm repo update opencost >/dev/null
  helm upgrade --install opencost opencost/opencost \
    -n opencost \
    -f "${REPO_ROOT}/helm/finops/opencost-values.yaml" \
    --wait --timeout 3m >/dev/null || { err "opencost"; exit 3; }
  ok "OpenCost instalado"

  log "==> [10/10] FinOps recording rules + dashboard + alerts"
  kubectl apply -f "${REPO_ROOT}/manifests/finops/" >/dev/null
  ok "FinOps configurado"
else
  warn "==> [9-10/10] FinOps: SKIPPED"
fi

# ─────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Stack instalada com sucesso${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Comandos úteis:"
echo "  kubectl --kubeconfig $KUBECONFIG get pods -A"
echo "  KUBECONFIG=$KUBECONFIG make chaos-test"
echo ""
if [[ -n "$LB_IP" ]]; then
  echo "URLs públicas:"
  echo "  Grafana:  https://grafana.${LB_IP//./-}.nip.io"
  echo "    user:   admin"
  echo "    pass:   okesrelab-2026"
  echo ""
  echo "  (aguarde ~1-3min pro cert Let's Encrypt ser emitido)"
fi
echo ""
echo "Pra destruir tudo: make oke-down"
