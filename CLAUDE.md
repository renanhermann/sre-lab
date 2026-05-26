# SRE Lab — Contexto do Projeto

Laboratório pessoal de SRE com Kubernetes, observabilidade completa e agents Claude Code.
Construído para demonstrar operação sênior: SLO, runbooks executáveis, chaos test e GitOps.

## Stack

| Camada | Tecnologia |
|---|---|
| K8s local | Minikube (profile: `sre-lab`, driver: docker) |
| Métricas | Prometheus + Grafana + AlertManager |
| Logs | Loki + Alloy (coleta via K8s API) |
| App de teste | `traffic-simulator` (Go) — gera carga, erros, latência |
| Agents | Claude Code (SRE Specialist, K8s Specialist, Git Specialist) |

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

# Dispara alertas:
curl -X POST http://localhost:8080/stress/error          # força HTTP 500 → HighErrorRate
curl -X POST "http://localhost:8080/stress/latency?ms=2000"  # latência alta → HighLatencyP99
curl -X POST "http://localhost:8080/stress/cpu?seconds=30"   # queima CPU → HPA escala
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

## Estrutura de diretórios

```
sre-lab/
├── app/                  # código Go do traffic-simulator
├── cluster/              # scripts start.sh e expose.sh
├── helm/                 # values dos Helm charts
├── manifests/app/        # K8s manifests da app
├── docs/runbooks/        # runbooks executáveis por agent
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

## Próximos passos (roadmap)

- [ ] SLO formal com error budget e burn rate alerts
- [ ] Migração pra Oracle Cloud (OKE) via Terraform
- [ ] Chaos test com endpoints de stress automatizados
- [ ] FinOps dashboard (custo por namespace)
- [ ] Postmortem automatizado via Git Specialist
