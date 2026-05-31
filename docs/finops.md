# FinOps — Custo por namespace, idle e budget alerts (Fase 6)

Stack de observabilidade financeira pro SRE Lab. Calcula custo de cada
namespace em tempo real usando rates reais do OCI, identifica recursos
ociosos e dispara alertas de budget — tudo via Prometheus + Grafana, sem
agente extra de cloud.

> **Por que isso importa pro pitch.** Toda apresentação de plataforma
> sobrevive em duas perguntas: "funciona?" e "**quanto custa?**". Sem
> FinOps no painel, a segunda pergunta te pega de surpresa.

---

## Arquitetura

```
  kube-state-metrics ─┐
                      ├──► Prometheus ──► Recording rules ──► Grafana dashboard
  cAdvisor (kubelet) ─┤                       (finops:*)            │
                      │                              │              ▼
  node-exporter ──────┤                              │       AlertManager
                      │                              │
  OpenCost ───────────┘                              │
   │                                                 │
   └─► pricing custom OCI                            ▼
       (ConfigMap)                              PrometheusRules
                                                (budget alerts)
```

**OpenCost** consome métricas do `kube-state-metrics`, `cAdvisor` e
`node-exporter`, aplica o pricing config (rates OCI custom) e expõe
métricas próprias (`node_cpu_hourly_cost`, `container_cpu_allocation`,
etc.). Recording rules combinam essas métricas pra gerar agregações
prontas pra dashboard e alertas.

---

## Pré-requisitos

- Cluster Kubernetes (Minikube ou OKE)
- `kube-prometheus-stack` instalado (Prom + Grafana + AlertManager + operator)
- Helm 3.x

---

## 1. Instalar OpenCost

```bash
helm repo add opencost https://opencost.github.io/opencost-helm-chart
helm repo update opencost

kubectl create namespace opencost
helm install opencost opencost/opencost \
  -n opencost \
  -f helm/finops/opencost-values.yaml \
  --wait --timeout 3m
```

### Pricing custom OCI — pegadinha importante

**OpenCost interpreta `CPU` e `RAM` como rate MENSAL** e divide por 730
internamente pra obter hourly. Os rates publicados pela OCI são em
$/hora — precisa converter:

| Recurso | Rate OCI publicado | Rate pro values |
|---|---|---|
| CPU (Standard3.Flex) | $0.0255/OCPU/h | **$18.615/OCPU/mês** (× 730) |
| RAM | $0.00255/GB/h | **$1.8615/GB/mês** (× 730) |
| Block Volume Balanced | $0.0255/GB/mês | $0.0255 (já mensal) |
| Internet Egress | $0.0085/GB | $0.0085 (sem conversão) |

Validar que aplicou: `node_cpu_hourly_cost` deve retornar `$0.0255/h`.

---

## 2. Recording rules

`manifests/finops/finops-recording-rules.yaml` cria 5 grupos:

| Grupo | Métricas |
|---|---|
| `finops.container.recording` | custo por container (CPU + RAM) via join `on(node)` |
| `finops.namespace.recording` | agregação por namespace + projeção mensal |
| `finops.workload.recording` | agregação por workload (regex no nome do pod) |
| `finops.cluster.recording` | cluster total + overhead/unallocated |
| `finops.idle.recording` | recursos pagos mas não usados (idle %) |

### Detalhe: idle calculation com cAdvisor sem label `container`

Em alguns clusters (notadamente Minikube e algumas distros), o cAdvisor
não popula o label `container` nas métricas de uso (`container_cpu_usage_seconds_total`).
Isso quebra qualquer `sum by (..., container)` envolvendo essas métricas.

**Mitigação adotada:** agregar idle direto por `namespace` em vez de
tentar manter granularidade de container. Trade-off: perde visão por
container, mas funciona em qualquer cluster. Pra OKE em produção real,
container label deve existir e dá pra ter granularidade fina.

---

## 3. Dashboard Grafana

ConfigMap `grafana-dashboard-finops` com label `grafana_dashboard: "1"`
— sidecar do kube-prometheus-stack auto-importa.

**8 painéis:**

1. Cluster $/h (stat com gradient verde-amarelo-vermelho)
2. Cluster $/mês projetado
3. Desperdício mensal (sum de idle costs)
4. Namespaces ativos (count)
5. Bar chart horizontal — custo mensal por namespace (sorted desc)
6. Donut chart — distribuição visual
7. Tabela — breakdown com colunas Custo/mês, Idle %, Desperdício/mês (cores)
8. Timeseries stacked — evolução custo por namespace ao longo do tempo

Acesso (port-forward Minikube):
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000  →  Dashboards  →  FinOps — Custo por Namespace
```

Em OKE com Ingress (Fase 5): `https://grafana.<ip>.nip.io/d/finops-namespace`.

---

## 4. Budget alerts

`manifests/finops/finops-alerts.yaml` — 5 alertas, todos `severity: warning`
e `page: "false"` (ticket, não acordar oncall):

| Alerta | Condição | For |
|---|---|---|
| `NamespaceBudgetExceeded` | namespace > $20/mês projetado | 15m |
| `ClusterBudgetExceeded` | cluster total > $200/mês | 30m |
| `WorkloadHighIdleResources` | namespace > 80% idle AND > $5/mês custo | 1h |
| `HighClusterOverhead` | > 50% do cluster sem workload alocado | 1h |
| `ClusterCostSpike` | custo /h dobrou vs hora anterior | 10m |

**Por que tudo `ticket` e não `page`:** desperdício de cloud raramente é
urgência operacional — é trabalho de revisão semanal/mensal. Acordar
oncall pra alerta de FinOps é anti-pattern.

---

## Queries úteis (PromQL)

```promql
# Top 5 namespaces mais caros (projeção mensal)
topk(5, finops:namespace:monthly_projected_cost)

# Custo total acumulado nas últimas 24h
sum_over_time(finops:cluster:hourly_cost[24h])

# Desperdício projetado total mensal
sum(finops:namespace:idle_cost_monthly)

# Namespaces com mais de 80% idle
finops:namespace:cpu_idle_pct > 80

# Custo por workload (top 10)
topk(10, finops:workload:hourly_cost * 730)
```

---

## Valor pra apresentação ao gestor

Frases-âncora pra puxar quando perguntarem sobre custo:

> "**Mediu, não é opinião.**" → toda decisão de rightsizing tem número.

> "**$24/mês de desperdício num cluster de $130** — é 19% do gasto em
> recurso pago mas não usado." (números mudam por execução, mas o ratio
> de 15-25% é típico em K8s sem rightsizing)

> "**FinOps não é page, é ticket.**" → desperdício é trabalho de
> revisão, não emergência.

> "**Stack 100% open source, sem agente proprietário.**" — OpenCost é
> CNCF Sandbox, evolução do Kubecost. Sem vendor lock-in.

---

## Limitações conhecidas

- Pricing é aproximação razoável, não bill exato da OCI (não consome
  Billing API). Pra exatidão, plugar `OCIRawConfigProvider` nativo do
  OpenCost com credentials reais.
- Idle calculation considera CPU; RAM idle exige métrica
  `container_memory_working_set_bytes` que não está nas recording rules
  atuais (próxima iteração).
- Em cluster sem cAdvisor com label `container`, granularidade fica em
  nível de namespace, não container.

---

## Próximos passos (Fase 6.5+ futura)

- Plugin `OCIRawConfigProvider` com Billing API real (custo exato vs
  projeção)
- RAM idle calculation
- Custo por workload com label de team/squad (label
  `cost-center: team-X` no Deployment)
- Forecast com `predict_linear` (custo previsto pros próximos 30 dias)
- Dashboard separado de **economia realizada** após rightsizing
