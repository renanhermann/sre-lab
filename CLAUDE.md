# SRE Lab — Contexto do Projeto

Laboratório pessoal de SRE com Kubernetes, observabilidade completa e agents Claude Code.
Construído para demonstrar operação sênior: SLO, runbooks executáveis, chaos test e GitOps.

## Stack

| Camada | Tecnologia |
|---|---|
| K8s local | Minikube (profile: `sre-lab`, driver: docker) |
| K8s cloud | OKE (Oracle Kubernetes Engine) — provisionado via Terraform em `terraform/` |
| Métricas | Prometheus + Grafana + AlertManager (kube-prometheus-stack) |
| Logs | Loki + Alloy (coleta via K8s API) |
| Confiabilidade | SLO formal com burn rate alerts em `manifests/slo/` — ver `docs/slo.md` |
| App de teste | `traffic-simulator` (Go) — RED + endpoints `/stress/*` e `/admin/fault` |
| Agents | Claude Code (SRE Specialist, K8s Specialist, Git Specialist, Postmortem Specialist) |

## Como subir o lab

```bash
./cluster/start.sh    # sobe o Minikube (rodar uma vez)
./cluster/expose.sh   # expõe serviços localmente (manter aberto)
```

Serviços disponíveis após `expose.sh`:
- Grafana: http://localhost:3000 (admin / srelab123)
- Prometheus: http://localhost:9090
- AlertManager: http://localhost:9093
- App de teste: http://localhost:8080

## App de teste — endpoints úteis

```bash
# Inicia gerador de tráfego (5 req/s)
curl -X POST "http://localhost:8080/traffic/start?rps=5"

# Para o gerador e retorna estatísticas
curl -X POST http://localhost:8080/traffic/stop

# Dispara alertas RED do app (paths /stress/* — EXCLUÍDOS do SLI):
curl -X POST http://localhost:8080/stress/error               # força HTTP 500 → HighErrorRate
curl -X POST "http://localhost:8080/stress/latency?ms=2000"   # latência alta → HighLatencyP99
curl -X POST "http://localhost:8080/stress/cpu?seconds=30"    # queima CPU → HPA escala

# Chaos primitive — injeta 5xx em /health (caminho de produção, CONSOME error budget):
curl -X POST "http://localhost:8080/admin/fault?rate=40&duration=10m"
curl -X POST "http://localhost:8080/admin/fault?rate=0"       # desativa
```

## Agentes disponíveis

### SRE Specialist
Analisa saúde dos serviços usando RED (Rate/Errors/Duration) e USE (Utilization/Saturation/Errors).
Consulta Prometheus e Loki, gera relatório estruturado com causa raiz e recomendações.
**Quando usar**: alerta disparou, serviço degradado, revisão de saúde pré-deploy.

### K8s Specialist
Monitora saúde do cluster: pods, HPA, eventos, uso de recursos, rightsizing.
**Quando usar**: pod crashando, HPA não escala, node com pressão de memória.

### Git Specialist
Faz commits atômicos (um por arquivo), cria branches e documenta mudanças.
**Quando usar**: após mudança em manifests, runbook atualizado, dashboard criado.

### Postmortem Specialist
Gera draft de postmortem a partir de janela de tempo + nome do incidente.
Consulta Prometheus (ALERTS firing histórico, RED, SLO burn rate), Loki e
eventos do Kubernetes. Preenche o template marcando fato vs hipótese.
**Quando usar**: incidente mitigado e precisa ser documentado. Output em
`docs/postmortems/YYYY-MM-DD-<slug>.md` — requer revisão humana antes de publicar.

## Estrutura de diretórios

```
sre-lab/
├── .github/workflows/    # chaos-test.yml — CI valida pipeline SLO em PR
├── app/                  # código Go do traffic-simulator
├── cluster/              # scripts start.sh e expose.sh
├── helm/                 # values local + CI + oke/ (variants pro OKE)
├── manifests/
│   ├── app/              # K8s manifests da app
│   ├── slo/              # PrometheusRules SLO + dashboard Grafana
│   └── oke/              # variants do app/SLO pro OKE (ImagePullSecret, OCIR image ref)
├── scripts/
│   ├── chaos-test.sh     # validação automatizada do pipeline de SLO
│   └── lib/              # log/prom/app helpers (bash 3.2-compatível)
├── Makefile              # atalhos cluster/app/SLO/chaos (make help)
├── terraform/
│   ├── 00-foundation/    # VCN, gateways, subnets
│   └── 01-oke/           # cluster OKE + node pool
├── docs/
│   ├── slo.md            # SLO formal, burn rate, error budget policy
│   ├── chaos-testing.md  # validação automatizada do pipeline de SLO
│   ├── oke-deployment.md # guia ponta a ponta da replicação Minikube → OKE
│   ├── ingress-https.md  # guia Ingress + LB free OCI + cert-manager + Let's Encrypt
│   ├── postmortems/      # postmortems de incidentes (TEMPLATE + README)
│   └── runbooks/         # runbooks executáveis por agent
└── .claude/agents/       # definições dos agents
```

## Queries PromQL úteis (RED)

```promql
# Rate
sum(rate(traffic_simulator_requests_total[1m]))

# Error rate %
sum(rate(traffic_simulator_requests_total{status=~"5.."}[1m]))
/ sum(rate(traffic_simulator_requests_total[1m])) * 100

# P99 latência
histogram_quantile(0.99,
  sum(rate(traffic_simulator_request_duration_seconds_bucket[5m])) by (le)
)
```

## Queries PromQL — SLO (Fase 3)

```promql
# SLI atual de disponibilidade (rolling 30d) — target 99.5%
slo:traffic_simulator_availability:ratio_rate30d

# Error budget restante (1.0 = 100% disponível, <= 0 = esgotado)
slo:traffic_simulator_availability:error_budget_remaining

# Estado bruto da expressão do alerta fast burn (sem aguardar 'for:')
slo:traffic_simulator_availability:error_ratio_rate1h > (14.4 * 0.005)
and
slo:traffic_simulator_availability:error_ratio_rate5m > (14.4 * 0.005)
```

## Próximos passos (roadmap)

- [x] Fase 1 — Cluster local + observabilidade + agents
- [x] Fase 2 — Provisionamento OKE via Terraform
- [x] Fase 3 — SLO formal com error budget e burn rate alerts
- [x] Fase 4 — Chaos test automatizado (`make chaos-test`, validação end-to-end)
- [x] Fase 4 — Workflow GitHub Actions executando chaos test em PR
- [x] Fase 4 — Postmortem automatizado via Postmortem Specialist
- [x] Fase 4 — Replicar stack Minikube → OKE (Helm + manifests + SLO + chaos test) — ver `docs/oke-deployment.md`
- [x] Fase 5 — Ingress-nginx + LB free OCI + cert-manager + Let's Encrypt (Grafana em URL pública HTTPS) — ver `docs/ingress-https.md`
- [ ] Fase 4 — FinOps dashboard (custo por namespace)
