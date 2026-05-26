#!/usr/bin/env bash
# ============================================================
# destroy-cluster.sh
# Destroi APENAS o cluster OKE (mantém VCN intacta)
# Use quando não estiver usando o lab pra parar de gastar crédito
# ============================================================
#
# Custo: cluster destruído = $0/hora
# VCN, gateways, subnets = continuam (todos Always Free)
#
# Para subir de novo: cd 01-oke && terraform apply -auto-approve
# Tempo: ~10 minutos pra cluster + node pool
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Destruindo cluster OKE (mantém VCN) ==="
echo ""
echo "Custo enquanto destruído: $0/hora"
echo "Recriar leva ~10 minutos"
echo ""
read -p "Confirma destroy? [y/N] " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Cancelado."
  exit 0
fi

cd "$SCRIPT_DIR/01-oke"
SUPPRESS_LABEL_WARNING=True terraform destroy -auto-approve

echo ""
echo "✅ Cluster destruído. VCN preservada."
echo "Pra subir de novo: cd terraform/01-oke && terraform apply -auto-approve"
