#!/usr/bin/env bash
#
# destroy-oke-stack.sh — derruba cluster OKE de forma rápida e garantida
#
# Estratégia (aprendida na marra): terraform destroy paciente trava no
# detach de Block Volumes. Forçamos via OCI CLI direto, depois limpamos
# state. Custo zera no momento que VMs são terminadas.
#
# Pra preservar Foundation (VCN, NAT, subnets — todos Always Free), passar
# --keep-foundation (default). Pra destruir tudo, --destroy-foundation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*"; }

DESTROY_FOUNDATION=false
[[ "${1:-}" == "--destroy-foundation" ]] && DESTROY_FOUNDATION=true

# Compartment OCID — pega do tfvars
COMP_ID=$(grep -E '^compartment_ocid' "${REPO_ROOT}/terraform/01-oke/terraform.tfvars" 2>/dev/null \
  | sed 's/.*= *"\(.*\)".*/\1/' || echo "")
if [[ -z "$COMP_ID" ]]; then
  COMP_ID=$(grep -E 'compartment_ocid' "${REPO_ROOT}/terraform/01-oke/terraform.tfvars" 2>/dev/null \
    | head -1 | sed 's/.*= *"\(.*\)".*/\1/')
fi

# 1. Termina TODAS as VMs RUNNING (custo zera aqui)
log "==> terminando VMs RUNNING..."
oci compute instance list --compartment-id "$COMP_ID" --lifecycle-state RUNNING \
  --query 'data[].id' --raw-output 2>/dev/null | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))" \
  | while read -r id; do
    [[ -z "$id" ]] && continue
    log "  terminating $id"
    oci compute instance terminate --instance-id "$id" --force --preserve-boot-volume false 2>&1 \
      | grep -v "Warning\|FutureWarning\|warnings.warn" | grep opc-work-request-id | head -1 || true
  done
ok "VMs em terminação (custo zerou)"

# 2. Delete cluster OKE via CLI (mais rápido que terraform destroy)
log "==> deletando cluster OKE..."
CLUSTER_ID=$(cd "${REPO_ROOT}/terraform/01-oke" && terraform output -raw cluster_id 2>/dev/null || echo "")
if [[ -n "$CLUSTER_ID" ]]; then
  oci ce cluster delete --cluster-id "$CLUSTER_ID" --force 2>&1 \
    | grep -v "Warning\|FutureWarning\|warnings.warn" | grep opc-work-request-id | head -1 || true
  ok "cluster delete disparado"
fi

# 3. Delete Load Balancers órfãos
log "==> deletando LBs órfãos..."
oci lb load-balancer list --compartment-id "$COMP_ID" --lifecycle-state ACTIVE \
  --query 'data[].id' --raw-output 2>/dev/null | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))" \
  | while read -r id; do
    [[ -z "$id" ]] && continue
    log "  deleting LB $id"
    oci lb load-balancer delete --load-balancer-id "$id" --force 2>&1 \
      | grep -v "Warning\|FutureWarning\|warnings.warn" | tail -1 || true
  done
ok "LBs removidos"

# 4. Delete Block Volumes órfãos
log "==> deletando Block Volumes órfãos..."
oci bv volume list --compartment-id "$COMP_ID" --lifecycle-state AVAILABLE \
  --query 'data[].id' --raw-output 2>/dev/null | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))" 2>/dev/null \
  | while read -r id; do
    [[ -z "$id" ]] && continue
    oci bv volume delete --volume-id "$id" --force 2>&1 \
      | grep -v "Warning\|FutureWarning\|warnings.warn" | grep opc-work-request-id | head -1 || true
  done
ok "Block Volumes removidos"

# 5. Limpar terraform state (cluster + node_pool)
log "==> limpando terraform state (01-oke)..."
cd "${REPO_ROOT}/terraform/01-oke"
terraform state list 2>/dev/null | xargs -I{} terraform state rm "{}" 2>&1 | tail -2 || true

# 6. Foundation (opcional)
if [[ "$DESTROY_FOUNDATION" == "true" ]]; then
  warn "==> destruindo Foundation (VCN, NAT, subnets)..."
  cd "${REPO_ROOT}/terraform/00-foundation"
  terraform destroy -auto-approve
  ok "Foundation destruída"
else
  log "Foundation PRESERVADA (Always Free, sem custo)"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Stack destruída — custo: \$0/h${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
