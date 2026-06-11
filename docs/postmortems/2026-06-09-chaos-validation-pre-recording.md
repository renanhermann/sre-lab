# Postmortem — Chaos test de validação do pipeline de detecção (pre-recording)

> **Status**: rascunho · **em revisão** · publicado
> **Autor**: Postmortem Specialist (draft automatizado)
> **Revisores**: — *(pendente revisão humana sênior)*
> **Data do incidente**: 2026-06-09
> **Data do postmortem**: 2026-06-09
> **Severidade**: SEV2
> **Duração**: ~00:03:30 (impacto agudo no caminho de produção: 22:35:30 → 22:39:00)

---

> ⚠️ **ESTE NÃO É UM INCIDENTE DE PRODUÇÃO REAL.**
> Trata-se de um **exercício de chaos test controlado**, executado deliberadamente
> para validar que o pipeline de detecção (recording rules de SLO, burn rate alerts
> e métricas RED) dispara corretamente. Não houve impacto a usuários finais reais.
> O slug `pre-recording` indica que o exercício antecede uma gravação/demonstração.
> Os "afetados" são as probes do Kubernetes e o error budget sintético do lab.

---

## Resumo Executivo

> Legível por gestor não-técnico.

Em 2026-06-09, entre **22:30 e 22:45** (America/São_Paulo), foi executado um **chaos test
controlado** no laboratório de SRE para validar a cadeia de detecção de falhas. Um fault
sintético (HTTP 5xx) foi injetado no endpoint `/health` do `traffic-simulator` por volta
de **22:35:30**, fazendo o error rate atingir **pico de 48.55%** às 22:38:30 `[fato]` e
disparando o alerta RED `HighErrorRate` (22:37:00) e o burn rate `SLOAvailabilityFastBurn`
(22:39:00) conforme esperado `[fato]`. O sistema **se recuperou sozinho** com o erro
voltando a 0% a partir de **22:39:30** `[fato]`, após o fim do fault. **O objetivo do
exercício — confirmar que o pipeline de detecção dispara — foi atingido.** Nenhum usuário
real foi afetado.

---

## Impacto

> Impacto medido em ambiente de laboratório. "Usuários" = tráfego sintético do gerador.

| Dimensão | Valor |
|---|---|
| Usuários afetados | Nenhum usuário real (tráfego 100% sintético) `[fato]` |
| Requests com erro | Janela aguda de ~3.5 min (22:35:30 → 22:39:00) com error rate entre 41.9% e 48.55% `[fato]`. Estimativa absoluta: throughput médio na janela ~3.92 rps, pico ~14.93 rps `[fato]`; com ~45% de erro sobre o pico de tráfego, ordem de **algumas centenas de requests 5xx** no intervalo agudo `[hipótese — interpolação a partir de rate × duração]` |
| Latência adicional (P99) | Desprezível — P99 entre 0.018s (médio) e 0.023s (pico) em toda a janela `[fato]` (o fault retorna 5xx rápido, não adiciona latência) |
| Error budget consumido | Budget de disponibilidade **já estava esgotado antes da janela** (`error_budget_remaining` = -9.6898 às 22:30) `[fato]`. Durante a janela aguda consumiu de -9.6838 (22:35) a -11.1807 (22:39) → **~1.50 de budget adicional queimado** `[fato]`. O valor já negativo reflete chaos tests anteriores acumulados no laboratório `[hipótese — validar histórico de execuções]` |
| SLOs violados | `traffic_simulator_availability` (target 99.5%) — burn rate excedeu thresholds de fast/medium/slow/slowest burn na janela `[fato]`. `error_ratio_rate5m` chegou a 0.5363, muito acima do threshold de fast burn (14.4 × 0.005 = 0.072) `[fato]` |
| Receita/SLA impactados | Nenhum — ambiente de laboratório, sem SLA com cliente `[fato]` |

---

## Linha do Tempo

> Todos os horários em America/São_Paulo (UTC−3).

| Hora | Evento | Fonte |
|---|---|---|
| 22:30:00 | `SLOAvailabilityBudgetExhausted` (warning) já firing no início da janela — budget esgotado por execuções anteriores | Prometheus |
| 22:30:00 | `SLOAvailabilityMediumBurn` / `SLOAvailabilitySlowBurn` / `SLOAvailabilitySlowestBurn` já firing — resíduo de burn de faults anteriores | Prometheus |
| 22:30:00 | Ruído de cluster pré-existente (lab single-node): `TargetDown` (×3), `etcdInsufficientMembers`, `KubeSchedulerInstanceUnreachable`, `KubeControllerManagerInstanceUnreachable`, `NodeClockNotSynchronising` já firing — **não relacionados ao chaos test** | Prometheus |
| 22:30:00 → 22:35:00 | Error rate em 0.00% — baseline estável, fault ainda não injetado | Prometheus |
| ~22:35:30 | **Início real do impacto**: error rate salta para 41.90% (primeira amostra anômala) — fault `/admin/fault` injetando 5xx em `/health` | Prometheus |
| 22:37:00 | Alerta RED `HighErrorRate` (warning) dispara | Prometheus |
| 22:38:30 | **Pico de error rate: 48.55%** | Prometheus |
| 22:39:00 | Alerta `SLOAvailabilityFastBurn` (critical) dispara (após `for:` cumprido) | Prometheus |
| ~22:39:00 | Última amostra anômala (43.20%) — fault encerra | Prometheus |
| 22:39:30 | **Recovery confirmado**: error rate volta a 0.00% e permanece estável | Prometheus |
| 22:40:30 | Alerta `HighErrorRate` resolve | Prometheus |
| 22:45:00 | Fim da janela de análise. `SLOAvailabilityFastBurn` ainda firing (janelas de 5m/1h ainda drenando o fault) | Prometheus |

> **Nota — ações humanas**: nenhuma ação de mitigação humana foi capturada nas fontes de
> observabilidade. Como exercício controlado, a recuperação foi por término do fault
> (kill switch implícito do `/admin/fault` ao expirar a duration). Preencher TTA/TTM em
> revisão humana se houve resposta manual.

---

## Detecção

- **Como o incidente foi detectado?** Automaticamente — alertas RED (`HighErrorRate`) e
  burn rate de SLO (`SLOAvailabilityFastBurn`) dispararam conforme projetado. `[fato]`
- **Tempo até detecção (TTD)**: do início real (22:35:30) ao primeiro alerta acionável do
  exercício (`HighErrorRate` às 22:37:00) = **~00:01:30** `[fato]`. O `SLOAvailabilityFastBurn`
  disparou às 22:39:00 (~00:03:30 após o início), consistente com a janela `for:` do alerta
  de burn rate. `[fato]`
- **O alerta foi acionável?** `HighErrorRate` e os burn rate alerts de SLO são acionáveis e
  têm runbooks associados em `docs/runbooks/`. **Verificar em revisão se há runbook específico
  para `SLOAvailabilityFastBurn`** — se não, abrir action item. `[hipótese — validar inventário de runbooks]`
- **Algum sinal anterior foi perdido?** Não no contexto do exercício. Há ruído de cluster
  pré-existente (`TargetDown`, `etcd*`, `KubeScheduler/ControllerManager Unreachable`,
  `NodeClockNotSynchronising`) firing durante toda a janela, **não relacionado ao chaos test**
  — é característico do lab single-node Minikube. Esse ruído pode mascarar sinais reais e é
  candidato a action item de higiene de alertas. `[hipótese — validar com revisão]`

---

## Resposta

- **Tempo até reconhecimento (TTA)**: — *(sem evidência de reconhecimento humano nas fontes; preencher em revisão)*
- **Tempo até mitigação (TTM)**: recuperação automática por término do fault às ~22:39:30; sem mitigação humana registrada. `[fato]`
- **Quem respondeu**: — *(exercício controlado; preencher se houve operador)*
- **Runbooks executados**: — *(nenhum registrado; validar em revisão)*
- **Comunicação**: — *(preencher em revisão — exercício de lab, comunicação provavelmente não aplicável)*

---

## Recuperação

- **O que estabilizou o sistema?** Término do fault injetado via `/admin/fault` (o efeito
  expira pela `duration` configurada ou por `rate=0`). Error rate retornou a 0% a partir de
  22:39:30. `[fato]` / `[hipótese — mecanismo exato de término: validar comando executado]`
- **A mitigação foi temporária ou definitiva?** Definitiva para esta execução — o fault é
  pontual e não deixa estado residual no app. `[fato]`
- **Houve impacto residual após "resolvido"?** Sim, esperado: os burn rate alerts de SLO
  (`SLOAvailabilityFastBurn`, médio/lento) permaneceram firing após 22:39:30 porque operam
  sobre janelas deslizantes de 5m/1h que ainda continham o fault. Isso é comportamento
  correto, não um bug. O `error_budget_remaining` ficou em -11.1768 ao fim da janela. `[fato]`

---

## Causa Raiz

> ⚠️ **Marque cada item como FATO ou HIPÓTESE.**

### Causa imediata
Injeção deliberada de fault HTTP 5xx no endpoint `/health` (caminho de produção que consome
error budget), via `POST /admin/fault`, fazendo o error rate subir a um pico de 48.55%
entre 22:35:30 e 22:39:00.

- O **fault sintético** e a janela temporal são **`[fato]`** (error rate de 0% → ~45-48% →
  0% em ~3.5 min, P99 estável e sem restarts de pod são a assinatura clássica de fault 5xx
  injetado, não de falha real de processo).
- A **atribuição ao endpoint `/admin/fault`** e os parâmetros exatos (`rate`, `duration`)
  são **`[hipótese — validar com histórico de comandos / Loki quando disponível]`**. Loki
  estava indisponível durante esta coleta, então não há confirmação por log da chamada ao
  endpoint.

### Causa contribuinte
- O **error budget já estava esgotado** (-9.69) antes do início da janela, por acúmulo de
  chaos tests anteriores no laboratório. Isso significa que qualquer novo fault aprofunda um
  budget já negativo. `[fato — valor medido]` / a atribuição a "chaos tests anteriores" é
  `[hipótese — validar histórico de execuções]`.
- **Ruído de alertas de cluster** (`TargetDown`, `etcd*`, `KubeScheduler/ControllerManager
  Unreachable`, `NodeClockNotSynchronising`) firing continuamente reduz a relação sinal/ruído
  e pode mascarar incidentes reais. `[hipótese — validar se é esperado no lab single-node]`

### Análise dos 5 porquês (opcional)
> Não preenchida — dados insuficientes para sustentar a cadeia além da causa imediata
> (exercício controlado, sem falha sistêmica genuína a investigar). Preencher em revisão se relevante.

---

## O Que Correu Bem

> Preencher/validar em revisão humana após sync de postmortem. Candidatos observados nos dados:
- Pipeline de detecção disparou como projetado: `HighErrorRate` em ~1m30s e `SLOAvailabilityFastBurn` em ~3m30s. `[fato]`
- Recuperação automática limpa (error rate 48.55% → 0% em uma amostra), sem impacto residual no app. `[fato]`
- Sem restarts de pod nem degradação de latência — o fault foi cirúrgico e contido. `[fato]`

## O Que Correu Mal

> Preencher em revisão humana após sync de postmortem. Candidatos observados nos dados:
- Error budget já esgotado antes do exercício (-9.69), tornando o sinal de budget menos útil para distinguir o fault desta execução. `[fato]`
- Ruído de alertas de infraestrutura do cluster compete com os sinais do exercício. `[fato]`
- Loki indisponível durante a coleta — impossível confirmar por log a chamada ao `/admin/fault`. `[fato]`

## Onde Tivemos Sorte

> Preencher em revisão humana após sync de postmortem.
- N/A — exercício controlado; o "blast radius" foi sintético por design.

---

## Action Items

> ⚠️ Itens abaixo são **sugestões automáticas sem owner/prazo** — confirmar e atribuir em revisão.
> Action items sem owner não saem do papel.

| # | Ação | Tipo | Owner | Prazo | Prioridade | Tracking |
|---|---|---|---|---|---|---|
| 1 | Confirmar existência de runbook para `SLOAvailabilityFastBurn`; criar se faltar | detectar | — | — | P2 | — |
| 2 | Reduzir ruído de alertas de cluster single-node (`TargetDown`, `etcd*`, `*Unreachable`, `NodeClockNotSynchronising`) — inhibit rules ou silences no lab | detectar | — | — | P2 | — |
| 3 | Restaurar/expor Loki antes de chaos tests para permitir confirmação por log do `/admin/fault` | detectar | — | — | P2 | — |
| 4 | Definir política de reset de error budget sintético entre exercícios de lab (budget já estava em -9.69) | prevenir | — | — | P2 | — |

---

## Anexos

### Queries PromQL usadas na investigação

```promql
# Error rate %
sum(rate(traffic_simulator_requests_total{status=~"5.."}[1m]))
/ sum(rate(traffic_simulator_requests_total[1m])) * 100

# Throughput (rps)
sum(rate(traffic_simulator_requests_total[1m]))

# P99 latência
histogram_quantile(0.99, sum(rate(traffic_simulator_request_duration_seconds_bucket[5m])) by (le))

# SLO burn rate e budget
slo:traffic_simulator_availability:error_ratio_rate5m
slo:traffic_simulator_availability:error_ratio_rate1h
slo:traffic_simulator_availability:error_budget_remaining

# Alertas firing
ALERTS{alertstate="firing"}
```

### Dados-chave coletados (janela 22:30:00 → 22:45:00, UTC−3)

- Error rate por amostra (step 30s): 0% até 22:35:00 → 41.90% (22:35:30), pico **48.55%** (22:38:30), 43.20% (22:39:00) → 0% a partir de 22:39:30. `[fato]`
- Throughput: pico 14.93 rps / médio 3.92 rps. `[fato]`
- P99 latência: pico 0.023s / médio 0.018s. `[fato]`
- `error_ratio_rate5m`: início 0.5363, fim 0.4670 (threshold fast burn = 0.072). `[fato]`
- `error_budget_remaining`: -9.6898 (22:30) → -11.1768 (22:45); queima aguda -9.6838→-11.1807 entre 22:35 e 22:39. `[fato]`

### Alertas firing na janela (Prometheus)

| Alerta | Severity | Firing |
|---|---|---|
| `HighErrorRate` | warning | 22:37:00 → 22:40:30 |
| `SLOAvailabilityFastBurn` | critical | 22:39:00 → 22:45:00 (ainda firing no fim) |
| `SLOAvailabilityMediumBurn` | critical | 22:30:00 → 22:45:00 |
| `SLOAvailabilitySlowBurn` / `SLOAvailabilitySlowestBurn` | warning | 22:30:00 → 22:45:00 |
| `SLOAvailabilityBudgetExhausted` | warning | 22:30:00 → 22:45:00 |
| `TargetDown` (×3), `etcdInsufficientMembers`, `etcdMembersDown`, `KubeScheduler/ControllerManagerInstanceUnreachable`, `NodeClockNotSynchronising`, `HighClusterOverhead`, `WorkloadHighIdleResources` | warning/critical | 22:30:00 → 22:45:00 (ruído de cluster, não relacionado) |

### Eventos de cluster (`kubectl get events`)
- **0 eventos** de Warning/Error no namespace `default` na janela. `[fato]`
- **0 restarts de pod** registrados. `[fato]`

### Logs (Loki)
- **Indisponível durante a coleta** (`/ready` não respondeu). Sem trechos de log. `[fato — limitação de coleta]`

---

> Este postmortem é **blameless**. O foco é em sistemas e processos, nunca em pessoas.
> Pessoas tomam a melhor decisão possível com a informação que têm no momento.
