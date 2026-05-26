# SRE Lab

Laboratório pessoal de SRE com Kubernetes, observabilidade completa e agents Claude Code.
Construído para demonstrar operação sênior: SLO, runbooks executáveis, GitOps e chaos test.

## Arquitetura

![Arquitetura do SRE Lab](docs/architecture.svg)

## Stack

| Camada | Tecnologia |
|---|---|
| K8s local | Minikube (profile: `sre-lab`, driver: docker) |
| Métricas | kube-prometheus-stack (Prometheus + Grafana + AlertManager) |
| Logs | Grafana Loki + Alloy (coleta via Kubernetes API) |
| App de teste | `traffic-simulator` — Go, ~8MB, endpoints RED + stress |
| Automação | Claude Code (agents: SRE Specialist, K8s Specialist, Git Specialist) |

## Como subir

```bash
# Sobe o cluster Minikube
./cluster/start.sh

# Expõe os serviços localmente (manter aberto)
./cluster/expose.sh
```

Após o `expose.sh`:

| Serviço | URL | Credenciais |
|---|---|---|
| Grafana | http://localhost:3000 | admin / srelab123 |
| Prometheus | http://localhost:9090 | — |
| AlertManager | http://localhost:9093 | — |
| App de teste | http://localhost:8080 | — |

## Gerando carga e alertas

```bash
# Inicia gerador de tráfego (5 req/s)
curl -X POST "http://localhost:8080/traffic/start?rps=5"

# Para o gerador
curl -X POST http://localhost:8080/traffic/stop

# Dispara alertas:
curl -X POST http://localhost:8080/stress/error              # → HighErrorRate
curl -X POST "http://localhost:8080/stress/latency?ms=2000"  # → HighLatencyP99
curl -X POST "http://localhost:8080/stress/cpu?seconds=30"   # → HPA escala
```

## Agents Claude Code

| Agent | Responsabilidade |
|---|---|
| `sre-specialist` | Analisa RED (Rate/Errors/Duration) + USE, consulta Prometheus e Loki, gera relatório com causa raiz |
| `k8s-specialist` | Monitora pods, HPA, eventos, uso de recursos e recomenda rightsizing |
| `git-specialist` | Commits atômicos, branches por feature, histórico GitOps limpo |

## Runbooks

- [HighErrorRate](docs/runbooks/high-error-rate.md) — erro rate > 5% por 1 minuto
- [HighLatencyP99](docs/runbooks/high-latency.md) — P99 > 1s por 2 minutos

## Estrutura

```
sre-lab/
├── app/                  # traffic-simulator em Go
│   ├── main.go           # servidor HTTP + métricas Prometheus
│   ├── Dockerfile        # multi-stage build (scratch ~8MB)
│   └── go.mod
├── cluster/              # start.sh + expose.sh
├── helm/                 # values: kube-prometheus-stack, loki, alloy
├── manifests/app/        # Deployment, Service, HPA, PDB, ServiceMonitor, PrometheusRule
├── docs/
│   ├── architecture.svg  # diagrama da arquitetura
│   └── runbooks/         # runbooks executáveis por agent
└── .claude/agents/       # definições dos agents Claude Code
```

## Roadmap

- [x] Fase 1 — Cluster local + observabilidade (Prometheus, Loki, Grafana, Alloy)
- [x] Fase 1 — App de teste em Go com métricas RED e endpoints de stress
- [x] Fase 1 — Alertas, HPA, PDB e runbooks operacionais
- [x] Fase 1 — Agents Claude Code (SRE, K8s, Git Specialist)
- [ ] Fase 2 — SLO formal com error budget e burn rate alerts
- [ ] Fase 2 — Migração para Oracle Cloud (OKE) via Terraform
- [ ] Fase 3 — Chaos test automatizado
- [ ] Fase 3 — FinOps dashboard (custo por namespace)
