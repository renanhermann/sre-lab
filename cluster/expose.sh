#!/usr/bin/env bash
# Expõe serviços do lab localmente via port-forward.
# Roda em foreground — deixa esse terminal aberto enquanto usar o lab.

set -euo pipefail

echo "==> Iniciando port-forwards do SRE Lab..."
echo ""
echo "    Grafana      → http://localhost:3000  (admin / srelab123)"
echo "    Prometheus   → http://localhost:9090"
echo "    AlertManager → http://localhost:9093"
echo ""
echo "    Ctrl+C para parar tudo."
echo ""

# Mata port-forwards anteriores pra evitar conflito de porta
pkill -f "port-forward.*monitoring" 2>/dev/null || true
sleep 1

kubectl port-forward svc/kube-prometheus-stack-grafana      3000:80    -n monitoring &
kubectl port-forward svc/kube-prometheus-stack-prometheus   9090:9090  -n monitoring &
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9090  -n monitoring &

wait
