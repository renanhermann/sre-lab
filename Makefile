# SRE Lab — targets utilitários
#
# Atalhos pros fluxos do dia-a-dia. Roda `make help` pra lista completa.

.DEFAULT_GOAL := help
.PHONY: help cluster-up cluster-down expose \
        chaos-baseline chaos-quick chaos-test chaos-clean \
        app-build app-restart \
        slo-apply slo-status

# ── Cluster ─────────────────────────────────────────────────────────────

cluster-up:    ## sobe o Minikube (idempotente)
	@./cluster/start.sh

cluster-down:  ## para o Minikube (libera RAM/CPU)
	@minikube -p sre-lab stop

expose:        ## abre port-forwards de Grafana/Prom/AlertManager/app
	@./cluster/expose.sh

# ── Chaos test (Fase 4) ─────────────────────────────────────────────────

chaos-baseline:  ## valida que o sistema está saudável e sai (~5s)
	@./scripts/chaos-test.sh --baseline-only

chaos-quick:     ## chaos test sem aguardar recuperação (~5min)
	@./scripts/chaos-test.sh --skip-recovery \
		--fault-rate=50 --load-rps=15 --timeout-firing=360

chaos-test:      ## chaos test completo: fault → firing → recovery (~10-15min)
	@./scripts/chaos-test.sh \
		--fault-rate=50 --load-rps=15 \
		--timeout-firing=360 --timeout-recovery=600

chaos-clean:     ## desliga fault em todos os pods (rede de segurança)
	@./scripts/chaos-test.sh --baseline-only > /dev/null 2>&1 || true
	@echo "fault desativado (se estava ativo)"

# ── App ─────────────────────────────────────────────────────────────────

app-build:     ## rebuild da imagem do traffic-simulator no daemon do Minikube
	@eval $$(minikube -p sre-lab docker-env) && \
		cd app && docker build -t sre-lab/traffic-simulator:latest .

app-restart:   ## rollout restart do traffic-simulator
	@kubectl rollout restart deployment/traffic-simulator
	@kubectl rollout status deployment/traffic-simulator --timeout=60s

# ── SLO ─────────────────────────────────────────────────────────────────

slo-apply:     ## aplica/atualiza os PrometheusRules e dashboard de SLO
	@kubectl apply -f manifests/slo/

slo-status:    ## resumo do estado atual dos SLOs (SLI 30d, budget, alertas firing)
	@kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 > /dev/null 2>&1 & \
		PF=$$! ; sleep 2 ; \
		echo "── SLO availability ──" ; \
		printf "  SLI 30d:         " ; curl -sf -G --data-urlencode 'query=slo:traffic_simulator_availability:ratio_rate30d' http://localhost:19090/api/v1/query | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(f'{float(r[0][\"value\"][1])*100:.2f}%' if r else 'NaN')" ; \
		printf "  Budget restante: " ; curl -sf -G --data-urlencode 'query=slo:traffic_simulator_availability:error_budget_remaining' http://localhost:19090/api/v1/query | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(f'{float(r[0][\"value\"][1])*100:.2f}%' if r else 'NaN')" ; \
		echo "── Alertas SLO firing ──" ; \
		curl -sf http://localhost:19090/api/v1/alerts | python3 -c "import sys,json; [print(f'  🔴 {a[\"labels\"][\"alertname\"]}') for a in json.load(sys.stdin)['data']['alerts'] if a['labels'].get('slo') and a['state']=='firing'] or print('  (nenhum)')" ; \
		kill $$PF 2>/dev/null ; wait $$PF 2>/dev/null || true

# ── Help ────────────────────────────────────────────────────────────────

help:          ## mostra esta ajuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
