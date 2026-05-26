#!/usr/bin/env bash
#
# Sobe o cluster Minikube do SRE Lab.
# Idempotente: se já estiver rodando, só mostra status.

set -euo pipefail

PROFILE="sre-lab"
K8S_VERSION="v1.30.0"
CPUS="6"
MEMORY="8192"     # 8 GB — folga pra kube-prometheus-stack + Loki + apps
DISK="30g"

echo "==> Verificando se cluster '${PROFILE}' já existe..."
if minikube status -p "${PROFILE}" >/dev/null 2>&1; then
    echo "    Cluster já existe. Status:"
    minikube status -p "${PROFILE}"
    echo ""
    echo "==> Pra recriar do zero: minikube delete -p ${PROFILE}"
    exit 0
fi

echo "==> Subindo cluster '${PROFILE}' (driver=docker, ${CPUS} CPUs, ${MEMORY}MB RAM)..."
minikube start \
    -p "${PROFILE}" \
    --driver=docker \
    --kubernetes-version="${K8S_VERSION}" \
    --cpus="${CPUS}" \
    --memory="${MEMORY}" \
    --disk-size="${DISK}" \
    --addons=metrics-server \
    --addons=ingress \
    --addons=storage-provisioner

echo ""
echo "==> Setando contexto kubectl..."
kubectl config use-context "${PROFILE}"

echo ""
echo "==> Cluster pronto. Sanity check:"
kubectl get nodes
kubectl get pods -A

echo ""
echo "==> Próximos passos:"
echo "    - Instalar kube-prometheus-stack: helm upgrade --install ... (Fase 1.4)"
echo "    - Acessar dashboard: minikube dashboard -p ${PROFILE}"
