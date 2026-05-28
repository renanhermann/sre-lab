# SLO formal — traffic-simulator

Documento de referência dos SLOs do serviço, política de error budget,
matemática do burn rate alerting e playbook de validação. Escrito para
servir como base de discussão em revisão de produção e como portfolio
do desenho de confiabilidade do lab.

> Referência primária: Google SRE Workbook, capítulo 5 — *Alerting on SLOs*.
> Toda a matemática de janela/burn rate segue a tabela 5-1.

---

## TL;DR

| | Disponibilidade | Latência |
|---|---|---|
| **SLO** | 99.5% das requests | 99% das requests ≤ 500ms |
| **Janela** | 30 dias (rolling) | 30 dias (rolling) |
| **Error budget** | 0.5% (≈ 3h36min/mês) | 1% (≈ 7h12min/mês de tráfego lento) |
| **Escopo** | `path !~ "/stress/.*"` | `path !~ "/stress/.*"` |
| **Alertas (page)** | Fast burn (14.4×) · Medium burn (6×) | mesma estrutura |
| **Alertas (ticket)** | Slow burn (3×) · Slowest burn (1×) | mesma estrutura |
| **Resposta a budget esgotado** | Freeze de mudanças não-críticas + foco em confiabilidade |

Manifestos:
- `manifests/slo/availability-slo.yaml` — `PrometheusRule` (recording + alerts)
- `manifests/slo/latency-slo.yaml` — `PrometheusRule` (recording + alerts)
- `manifests/slo/grafana-dashboard-slo.yaml` — `ConfigMap` (dashboard `SLO — traffic-simulator`)

---

## 1. Definições

**SLI (Service Level Indicator)** — métrica numérica do que o usuário
experimenta. Aqui usamos *event-based ratios*: fração de boas requests
sobre total de requests.

**SLO (Service Level Objective)** — meta sobre o SLI ao longo de uma
janela. Aqui usamos rolling window de 30 dias — alinhada com a janela
de "compliance" mensal típica.

**Error budget** — o complemento do SLO. Se SLO = 99.5%, o budget é 0.5%:
quanta falha o serviço pode acumular antes de violar o objetivo.

**Burn rate** — velocidade com que o budget está sendo consumido,
medida em múltiplos do consumo nominal. Burn rate = 1 significa que,
mantido o ritmo, o budget de 30 dias é consumido em exatamente 30 dias.
Burn rate = 14.4 significa que seria consumido em 30÷14.4 ≈ 2 dias.

---

## 2. SLO 1 — Disponibilidade

### 2.1 SLI

```promql
SLI_availability =
  sum(rate(traffic_simulator_requests_total{path!~"/stress/.*", status!~"5.."}[W]))
  /
  sum(rate(traffic_simulator_requests_total{path!~"/stress/.*"}[W]))
```

**Por que excluir `/stress/*`** — esses endpoints são *chaos primitives*
declarados (ver `app/main.go`): retornam 5xx, latência alta ou queimam
CPU por design, pra exercitar alertas e auto-scaling. Tráfego de chaos
controlado não deve consumir error budget — senão um teste rotineiro
viraria incidente fictício.

### 2.2 Target e budget

| Item | Valor |
|---|---|
| SLO | 99.5% |
| Error budget | 0.5% |
| Janela | 30d rolling |
| Tempo "permitido" de falha total | ≈ 3h36min/mês |

### 2.3 Implementação

A recording rule efetiva usa o **complemento** (error ratio) porque
é numericamente mais conveniente pra cálculo de burn rate — error rate
é diretamente comparável ao budget:

```promql
slo:traffic_simulator_availability:error_ratio_rate{W} =
  (
    sum(rate(traffic_simulator_requests_total{path!~"/stress/.*", status=~"5.."}[W]))
    or vector(0)
  )
  /
  sum(rate(traffic_simulator_requests_total{path!~"/stress/.*"}[W]))
```

> **`or vector(0)` não é estético — é correção.** Sem ele, quando não
> há nenhum 5xx no range (cenário esperado >99% do tempo), o numerador
> é um vetor vazio. `vetor_vazio / escalar = vetor_vazio` em PromQL,
> e a recording rule fica sem dados. Isso quebra o dashboard ("No Data"
> permanente no estado saudável) e impede o alerta `BudgetExhausted` de
> ser avaliado. O `or vector(0)` força um zero explícito quando não há
> erros — mantendo a série contínua.

---

## 3. SLO 2 — Latência

### 3.1 SLI

```promql
SLI_latency =
  sum(rate(traffic_simulator_request_duration_seconds_bucket{path!~"/stress/.*", le="0.5"}[W]))
  /
  sum(rate(traffic_simulator_request_duration_seconds_count{path!~"/stress/.*"}[W]))
```

### 3.2 Por que bucket `le="0.5"`, não `histogram_quantile(0.99, ...) < 0.5`?

Esta é uma decisão deliberada. As duas formulações *parecem* equivalentes
("P99 < 500ms"), mas têm propriedades diferentes:

| Aspecto | Bucket `le="0.5"` | `histogram_quantile(0.99)` |
|---|---|---|
| Tipo de resultado | Razão exata (0–1) | Estimativa do quantil |
| Linearidade em burn rate | Sim — fração direta | Não — quantil não é aditivo |
| Janelas longas (30d) | Estável | Pode oscilar com poucos outliers |
| Threshold do alerta | "1% das requests excede 500ms" | "P99 está em 510ms" |

Pra burn rate alerting, queremos um SLI **aditivo**: a soma de erros
em duas janelas equivale ao erro na janela combinada. Quantis não têm
essa propriedade. O `bucket{le="0.5"}` dá exatamente isso — é o número
de requests que ficaram abaixo de 500ms, somável por janela.

A definição vira: *"99% das requests devem ser servidas em ≤ 500ms"* —
que é o que o usuário experimenta, não *"o P99 deve ficar abaixo de 500ms"*
que é uma estimativa estatística sobre a cauda.

### 3.3 Target e budget

| Item | Valor |
|---|---|
| SLO | 99% |
| Error budget | 1% |
| Janela | 30d rolling |
| Tempo "permitido" de tráfego lento | ≈ 7h12min/mês |

---

## 4. Matemática do burn rate alerting

### 4.1 Por que multi-window, multi-burn-rate

Um alerta de SLO ingênuo seria *"dispare quando error rate > error budget"*.
Isso falha em dois extremos:

- **Janela curta:** dispara em qualquer ruído transitório (alta sensibilidade,
  baixa precisão) → fadiga de alerta.
- **Janela longa:** demora horas pra reagir a uma falha grande
  (baixa sensibilidade) → incidente sério passa silencioso por muito tempo.

A solução do Google SRE Workbook (cap 5) é dividir o problema em **classes
de severidade**, cada uma com sua própria combinação `(long_window, short_window, burn_rate)`:

- O **long window** garante que o problema é real (não ruído).
- O **short window** garante que o alerta é *atual* (não obsoleto, já
  resolvido).
- O **burn rate threshold** define quanto do budget pode ser
  consumido antes de acionar essa classe.

### 4.2 Tabela de alertas (tabela 5-1, adaptada)

| Severidade | Long window | Short window | Burn rate | Budget consumido se mantido | `for:` | Ação |
|---|---|---|---|---|---|---|
| **Critical (page)** | 1h | 5m | 14.4× | 2% em 1h | 2m | Acordar plantão imediatamente |
| **Critical (page)** | 6h | 30m | 6× | 5% em 6h | 5m | Acordar plantão imediatamente |
| **Warning (ticket)** | 1d | 2h | 3× | 10% em 1d | 15m | Ticket pra próxima janela útil |
| **Warning (ticket)** | 3d | 6h | 1× | 10% em 3d | 1h | Investigar tendência |

**Como o burn rate threshold é calculado** — para "queimar X% do budget
em Y horas", o burn rate é `X / (Y / 720)`, onde 720 é a quantidade de
horas em 30 dias:

- 2% em 1h → `0.02 / (1/720)` = **14.4×**
- 5% em 6h → `0.05 / (6/720)` = **6×**
- 10% em 1d → `0.10 / (24/720)` = **3×**
- 10% em 3d → `0.10 / (72/720)` = **1×**

E o threshold de error rate aplicado na recording rule é
`burn_rate × error_budget`:

- SLO disponibilidade (budget 0.5%): fast = 0.5% × 14.4 = **7.2%**
- SLO latência (budget 1%): fast = 1% × 14.4 = **14.4%**

### 4.3 Expressão dos alertas

Cada alerta exige que **ambas** as janelas estejam acima do threshold:

```promql
# Exemplo: SLOAvailabilityFastBurn
slo:traffic_simulator_availability:error_ratio_rate1h > (14.4 * 0.005)
and
slo:traffic_simulator_availability:error_ratio_rate5m > (14.4 * 0.005)
```

A janela longa elimina ruído; a curta elimina alertas obsoletos
(se o problema já cessou, a janela curta cai abaixo do threshold
em minutos, e o alerta sai de firing).

---

## 5. Política de error budget

Esta é a parte que diferencia "SLO formal" de "SLO decorativo": a
política definindo o que **fazer** com o budget.

### 5.1 Quando há budget (≥ 50%)

- Mudanças seguem o ritmo normal.
- Experimentos com feature flags podem ser graduais.
- Chaos game days são bem-vindos.

### 5.2 Quando há pouco budget (20%–50%)

- Mudanças em path crítico (incluindo `/health`) precisam de revisão
  adicional.
- Adiar testes de chaos que possam impactar produção.
- Iniciar investigação proativa do que está consumindo budget.

### 5.3 Quando o budget está esgotado (≤ 0%)

Acionado pelo alerta `SLOAvailabilityBudgetExhausted` /
`SLOLatencyBudgetExhausted`:

- **Freeze** de mudanças não-críticas até o budget se recuperar.
- Toda capacidade de release é direcionada para trabalho de confiabilidade
  (bug fixes, redução de tempo de detecção, melhoria de runbooks).
- Postmortem público é obrigatório para o incidente que consumiu o budget.
- O freeze sai quando o SLI rolling 30d volta ao target.

---

## 6. Playbook de validação (chaos primitive)

O app tem um endpoint dedicado pra testar todo esse aparato sem precisar
inventar falhas. Ele entra no caminho de produção (`/health`) — portanto
**consome error budget de verdade**, ao contrário de `/stress/error`
que é excluído do SLI.

### 6.1 Ativar fault

```bash
# Subir port-forward do app
kubectl port-forward svc/traffic-simulator 18080:8080 &

# Ativar fault: 40% de 5xx em /health por 10 minutos, com auto-reset
curl -X POST "http://localhost:18080/admin/fault?rate=40&duration=10m"
```

Resposta:
```json
{
  "status": "enabled",
  "rate_pct": 40,
  "duration": "10m0s",
  "expires_at": "...",
  "target": "/health"
}
```

### 6.2 Gerar carga sustentada

```bash
# Loop simples — ~20 req/s
while true; do
  for i in $(seq 1 20); do curl -s -o /dev/null http://localhost:18080/health & done
  wait
  sleep 1
done
```

### 6.3 Acompanhar burn rate

```bash
# Métricas no Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &

# Error ratios em múltiplas janelas
for w in 5m 30m 1h 6h; do
  echo -n "rate$w: "
  curl -s --data-urlencode "query=slo:traffic_simulator_availability:error_ratio_rate$w" \
    http://localhost:19090/api/v1/query \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{float(d['data']['result'][0]['value'][1]):.4f}\")"
done

# Estado dos alertas (pending = aguardando 'for:', firing = disparou)
curl -s http://localhost:19090/api/v1/alerts \
  | python3 -c "import sys, json; [print(f\"{a['state']:8s} {a['labels']['alertname']}\") for a in json.load(sys.stdin)['data']['alerts'] if a['labels'].get('slo')]"
```

### 6.4 Tempo esperado até cada alerta disparar

Com fault a 80% e ~20 rps de carga, partindo de SLI saudável:

| Alerta | Tempo até cruzar threshold | + `for:` | Total |
|---|---|---|---|
| `SLOAvailabilityFastBurn` | ~3min (rate1h cruza 7.2%) | 2min | ~5min |
| `SLOAvailabilityMediumBurn` | ~2min (rate30m cruza 3%) | 5min | ~7min |
| `SLOAvailabilitySlowestBurn` | ~5min (rate6h cruza 0.5%) | 1h | ~1h05 |
| `SLOAvailabilityBudgetExhausted` | ~15min (rate30d > 0.5%) | 5min | ~20min |

### 6.5 Desativar

```bash
curl -X POST "http://localhost:18080/admin/fault?rate=0"
```

Ou simplesmente espere o auto-reset após `duration`. O cap máximo
hard-coded é 30min (safety: é lab, não game day em produção).

---

## 7. Lições aprendidas na implementação

Notas registradas durante a construção dessa fase, pra contexto futuro:

### 7.1 Bug clássico de PromQL: vetor vazio / escalar

Recording rules de error ratio retornam vazio quando o numerador (5xx)
não tem séries. Isso ocorre no estado saudável (>99% do tempo), o que
quebra dashboards e impede alguns alertas. **Sempre embrulhar o
numerador em `or vector(0)`** — ver seção 2.3.

### 7.2 Fault injection ≥ 50% em `/health` causa probe-induced restart

Durante validação, fault a 80% causou 4 restarts no pod em 2 minutos —
o liveness probe bate em `/health`, falha 3× consecutivas, kubelet mata
o pod. Isso é **realismo correto** (em prod isso seria uma cascata de
restart loop), mas confunde a interpretação do experimento.

Mitigações possíveis (não aplicadas no lab):

1. Adicionar `/readyz` separado que **não** sofre fault — caminho clean
   para probes; `/health` continua sendo o SLI.
2. Aumentar `failureThreshold` do liveness pra absorver fault injection
   moderada sem matar o pod.
3. Limitar `fault?rate=` a < 50% no código (cap defensivo).

Para o lab, decidimos manter o comportamento atual — é boa prova de que
SLO sem `/readyz` separado contém um anti-pattern sutil.

### 7.3 Fault state é local ao pod

`/admin/fault` armazena state em memória do pod, não em
ConfigMap/banco compartilhado. Em deploys multi-réplica, ativar fault
via service só atinge **um** pod (round-robin). Isso é OK pra lab —
em ferramentas reais (Chaos Mesh, Litmus) o controle é declarativo
e propaga pra todos os pods alvo.

Workaround usado: port-forward por pod individualmente, ou scale pra
1 réplica antes do teste.

---

## 8. Roadmap dessa SLO

Itens conscientemente fora de escopo nesta primeira versão:

- [ ] **SLO multi-service** quando o lab tiver mais de um serviço.
  Por hoje, o traffic-simulator é o único — escopo definido por
  `service="traffic-simulator"` em todas as recording rules.
- [ ] **Janela de compliance configurável** via variável (hoje hard-coded `30d`).
- [ ] **Auto-mute de alertas em janela de mudança** (`silence` automático
  no AlertManager durante deploys planejados).
- [ ] **SLO de saturação** (USE: utilization, saturation, errors) —
  hoje cobrimos só RED.
- [ ] Replicar tudo no **OKE** quando o cluster voltar (`terraform apply`
  + Helm stack + manifests).

---

## 9. Referências

- Google SRE Workbook, cap. 5 — *Alerting on SLOs*
  https://sre.google/workbook/alerting-on-slos/
- Google SRE Book, cap. 4 — *Service Level Objectives*
  https://sre.google/sre-book/service-level-objectives/
- Prometheus docs — *Recording rules*
  https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Sloth (gerador declarativo de SLOs, **referência apenas** — não usado
  aqui por escolha pedagógica): https://sloth.dev/
