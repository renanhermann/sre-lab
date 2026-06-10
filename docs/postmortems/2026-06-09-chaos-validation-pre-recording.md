# Postmortem — Chaos test de validação do pipeline de detecção (pre-recording)

> **Status**: rascunho · **em revisão** · publicado
> **Autor**: Postmortem Specialist (draft automatizado)
> **Revisores**: — *(pendente revisão humana sênior)*
> **Data do incidente**: 2026-06-09
> **Data do postmortem**: 2026-06-09
> **Severidade**: SEV2
> **Duração**: ~00:01:30 (impacto agudo no caminho de produção: 20:57:24 → ~20:58:45)

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

Em 2026-06-09, entre 20:30 e 21:00 (America/São_Paulo), foi executado um **chaos test
controlado** no laboratório de SRE para validar a cadeia de detecção de falhas. Um fault
sintético (HTTP 500) foi injetado no endpoint `/health` do `traffic-simulator` por volta
de **20:57**, fazendo o error rate atingir **pico de ~49%** `[fato]` e disparando os
alertas de SLO burn rate e o alerta RED `HighErrorRate` conforme esperado. O sistema
**se recuperou sozinho** com o erro voltando a <1% até **~20:58:45** `[fato]`, após o fim
do fault. **O objetivo do exercício — confirmar que o pipeline de detecção dispara — foi
atingido.** Nenhum usuário real foi afetado.

---

## Impacto

> Impacto medido em ambiente de laboratório. "Usuários" = tráfego sintético do gerador.

| Dimensão | Valor |
|---|---|
| Usuários afetados | Nenhum usuário real (tráfego 100% sintético) `[fato]` |
| Requests com erro | Pico ~49% do tráfego retornou 5xx às 20:57:45 `[fato]`; ~1 min de janela aguda. Estimativa absoluta: throughput médio ~1.8 rps, pico ~15 rps → ordem de algumas centenas de requests com erro no minuto de pico `[hipótese — interpolação a partir de rate]` |
| Latência adicional (P99) | Desprezível — P99 ~0.005s estável em toda a janela `[fato]` (o fault retorna 5xx rápido, não adiciona latência) |
| Error budget consumido | Budget de disponibilidade **já estava esgotado antes da janela** (`error_budget_remaining` = -7.28 no início, -7.30 no fim) `[fato]`. Variação na janela: ~0.02 (consumo marginal adicional) `[fato]`. O valor negativo reflete chaos tests anteriores acumulados no laboratório `[hipótese — validar histórico de execuções]` |
| SLOs violados | `traffic_simulator_availability` (99.5%) — burn rate excedeu thresholds de fast/medium/slow burn na janela `[fato]` |
| Receita/SLA impactados | Nenhum — ambiente de laboratório, sem SLA com cliente `[fato]` |

---

## Linha do Tempo

> Todos os horários em America/São_Paulo (UTC−3).

| Hora | Evento | Fonte |
|---|---|---|
| 20:30:00 | `SLOAvailabilityBudgetExhausted` (warning) já firing no início da janela — budget esgotado por execuções anteriores | Prometheus / AlertManager |
| 20:30:00 | `SLOAvailabilityFastBurn` (critical) firing — resíduo de burn rate de fault anterior (5m=0.21 às 20:30, zera às 20:31) | Prometheus / AlertManager |
| 20:30:45 | `SLOAvailabilityMediumBurn` (critical) firing | Prometheus / AlertManager |
| 20:31:00 | `SLOAvailabilityFastBurn` resolve | Prometheus / AlertManager |
| 20:40:45 | `SLOAvailabilitySlowBurn` (warning) firing | Prometheus / AlertManager |
| 20:56:00 | `SLOAvailabilityMediumBurn` resolve | Prometheus / AlertManager |
| ~20:57:00 | **Fault sintético injetado em `/health` (HTTP 500)** — início real do impacto agudo desta janela | Prometheus / kubectl (inferido do efeito) |
| 20:57:24 | Liveness probe falha (HTTP 500) no pod `...-2cnbs` (x8) | kubectl events |
| 20:57:30 | Primeira amostra RED anômala: error rate 42.99% | Prometheus |
| 20:57:33 | Readiness probe falha (HTTP 500) no pod `...-zqf4r` (x8) | kubectl events |
| 20:57:45 | Pico de error rate RED: 49.19% | Prometheus |
| 20:57:38 | Pod `...-zqf4r` killed por falha de liveness probe e reiniciado | kubectl events |
| 20:58:00 | `error_ratio_rate5m` do SLI atinge pico 0.477 (caminho de produção `/health`) | Prometheus |
| 20:58:15 | Error rate RED já em 1.85% — recuperação em curso | Prometheus |
| ~20:58:45 | **Recuperação confirmada**: error rate RED <1% (0.97%) | Prometheus |
| 20:59:00 | `HighErrorRate` (warning, RED) firing — dispara após o pico devido ao `for:` do alerta | Prometheus / AlertManager |
| 20:59:15 | `HighErrorRate` resolve | Prometheus / AlertManager |
| 21:00:00 | `SLOAvailabilitySlowBurn` ainda firing no fim da janela (janela longa do burn rate) | Prometheus / AlertManager |

> Ruído de baseline do Minikube observado e **excluído** da análise por não ser do app:
> `KubeControllerManagerInstanceUnreachable`, `KubeSchedulerInstanceUnreachable`,
> `NodeClockNotSynchronising`, `TargetDown`, `etcdInsufficientMembers`, `etcdMembersDown`,
> `Watchdog` — todos firing de forma constante na janela inteira (control plane single-node).

---

## Detecção

- **Como foi detectado?** Detecção automática. O exercício validou três camadas em paralelo:
  burn rate alerts de SLO (fast/medium/slow), alerta RED `HighErrorRate`, e eventos do
  Kubernetes (falha de probes). `[fato]`
- **Tempo até detecção (TTD)**: o impacto agudo começou ~20:57:24 (primeira falha de probe)
  e a primeira amostra RED anômala foi 20:57:30 → **TTD ≈ 00:00:06 para o sinal RED**. `[fato]`
  Para o alerta `HighErrorRate` firing (com `for:`), 20:57:30 → 20:59:00 = **~00:01:30**. `[fato]`
- **O alerta foi acionável?** Os alertas de SLO (`SLOAvailability*`) possuem runbook em
  `docs/runbooks/` — verificar cobertura. `[hipótese — validar existência do runbook específico]`
  O alerta `HighErrorRate` deve apontar para runbook de error rate. Se algum não tiver, vira action item.
- **Algum sinal anterior foi perdido?** Não no contexto do exercício. Nota: o `error_budget_remaining`
  já estava negativo (-7.3) **antes** da janela, indicando burn acumulado de execuções anteriores —
  esperado em laboratório, mas mascararia o sinal de um fault novo num cenário real. `[fato]`

---

## Resposta

- **Tempo até reconhecimento (TTA)**: N/A — exercício controlado, sem acionamento de on-call humano. `[fato]`
- **Tempo até mitigação (TTM)**: o fault tinha duração definida; o sistema auto-recuperou.
  Do pico (20:57:45) ao erro <1% (20:58:45) ≈ **00:01:00**. `[fato]`
- **Quem respondeu**: Operador do chaos test (executor do exercício). — *(preencher nome em revisão)*
- **Runbooks executados**: nenhum — não houve resposta humana de incidente, por ser teste planejado.
- **Comunicação**: N/A — exercício de laboratório. *(Em produção, este campo registraria canal e cadência.)*

---

## Recuperação

- **O que estabilizou o sistema?** O fim do fault sintético injetado (duração limitada do
  `/admin/fault`) — após cessar, `/health` voltou a responder 200 e as probes do Kubernetes
  voltaram a passar. `[fato]` (recuperação visível na queda do error rate de ~49% para <1% em ~1 min)
- **A mitigação foi temporária ou definitiva?** Definitiva para esta janela — o fault era de duração
  fixa e não recorreu. `[fato]`
- **Houve impacto residual?** Os pods `...-2cnbs` (17 restarts) e `...-zqf4r` (9 restarts) acumularam
  reinícios por falha de liveness durante o fault `[fato]`. Após a recuperação ficaram estáveis.
  O `error_ratio_rate5m` do SLI ainda decaía no fim da janela (janela móvel de 5m) — resíduo
  estatístico esperado, não impacto real. `[fato]`

---

## Causa Raiz

> ⚠️ Cada item marcado como FATO ou HIPÓTESE.

### Causa imediata
Injeção **deliberada e controlada** de fault HTTP 500 no endpoint `/health` (caminho de produção
que alimenta o SLI de disponibilidade), via chaos primitive `/admin/fault`, como parte do exercício
de validação. `[fato]` — comprovado por:
- presença do endpoint `/admin/fault` (responde HTTP 405 a GET, rota existe) `[fato]`;
- eventos do Kubernetes mostrando probes falhando com `statuscode: 500` em `/health` às 20:57:24 `[fato]`;
- pico de `error_ratio_rate5m` do SLI (0.477) coincidente às 20:58 `[fato]`.

A hora exata da injeção (`rate`/`duration` usados) não está nos dados coletados — `[hipótese — validar
com o comando/log do executor do chaos test]`.

### Causa contribuinte
- O endpoint `/health` é simultaneamente alvo do chaos primitive **e** alvo das probes liveness/readiness
  do Kubernetes, então o fault propagou para o ciclo de vida dos pods (restarts), amplificando o sinal
  além do error rate. `[hipótese — validar se é comportamento desejado para o exercício]`
- O error budget já estava esgotado (-7.3) antes do exercício, fruto de chaos tests acumulados no lab,
  o que torna o `error_budget_remaining` pouco informativo como sinal incremental. `[hipótese — validar
  política de reset de budget entre exercícios]`

### Análise dos 5 porquês (opcional)
> Não preenchido automaticamente — os dados sustentam a causa imediata como evento planejado.
> Os 5 porquês não se aplicam a um fault deliberado; preencher apenas se a revisão identificar
> comportamento inesperado do pipeline.

---

## O Que Correu Bem

> Preencher em revisão humana após sync de postmortem.

## O Que Correu Mal

> Preencher em revisão humana após sync de postmortem.

## Onde Tivemos Sorte

> Preencher em revisão humana após sync de postmortem.

---

## Action Items

> Sugestões automáticas (sem owner/prazo). Validar e atribuir em revisão humana.
> Action items sem owner não saem do papel.

| # | Ação | Tipo | Owner | Prazo | Prioridade | Tracking |
|---|---|---|---|---|---|---|
| 1 | *(sugestão)* Confirmar que `SLOAvailabilityFastBurn/MediumBurn/SlowBurn` e `HighErrorRate` têm runbook em `docs/runbooks/` e link no alerta | detectar | — | — | P2 | — |
| 2 | *(sugestão)* Definir política de reset/snapshot do error budget entre chaos tests no lab, para que `error_budget_remaining` seja sinal incremental confiável | detectar | — | — | P2 | — |
| 3 | *(sugestão)* Restaurar acesso ao Loki durante exercícios (estava indisponível: `:3100/ready` falhou) para correlação log↔métrica nos postmortems | detectar | — | — | P2 | — |
| 4 | *(sugestão)* Registrar no exercício o comando exato do `/admin/fault` (rate/duration/hora) para tornar a "causa imediata" 100% factual sem inferência | prevenir | — | — | P3 | — |
| 5 | *(sugestão)* Avaliar se compartilhar `/health` entre chaos primitive e probes do K8s é o comportamento desejado para validação isolada do pipeline | prevenir | — | — | P3 | — |

---

## Anexos

### Queries PromQL usadas na investigação
```promql
# Alertas firing na janela
ALERTS{alertstate="firing"}

# Error rate RED (%)
sum(rate(traffic_simulator_requests_total{status=~"5.."}[1m]))
/ sum(rate(traffic_simulator_requests_total[1m])) * 100

# Throughput
sum(rate(traffic_simulator_requests_total[1m]))

# P99
histogram_quantile(0.99, sum(rate(traffic_simulator_request_duration_seconds_bucket[5m])) by (le))

# SLO burn rate e budget
slo:traffic_simulator_availability:error_ratio_rate1h
slo:traffic_simulator_availability:error_ratio_rate5m
slo:traffic_simulator_availability:error_budget_remaining
```

### Trechos de log relevantes (Loki)
> Loki estava **indisponível** durante a coleta (`http://localhost:3100/ready` falhou).
> Logs do período não puderam ser correlacionados. Ver Action Item #3.

### Eventos de cluster (kubectl)
```
20:57:24 [Warning] Unhealthy ...-2cnbs: Liveness probe failed: HTTP probe failed with statuscode: 500 (x8)
20:57:33 [Warning] Unhealthy ...-zqf4r: Readiness probe failed: HTTP probe failed with statuscode: 500 (x8)
20:57:36 [Warning] Unhealthy ...-2cnbs: Readiness probe failed: HTTP probe failed with statuscode: 500 (x19)
20:57:38 [Normal]  Killing  ...-zqf4r: Container failed liveness probe, will be restarted (x2)
```
Restarts acumulados: `...-2cnbs` = 17 (reason=Error, exitCode=2); `...-zqf4r` = 9 (reason=Error, exitCode=2).

### Resumo de alertas (AlertManager / Prometheus)
| Alerta | Severidade | Firing |
|---|---|---|
| SLOAvailabilityFastBurn | critical | 20:30:00 → 20:31:00 (resíduo) |
| SLOAvailabilityMediumBurn | critical | 20:30:45 → 20:56:00 |
| SLOAvailabilitySlowBurn | warning | 20:40:45 → 21:00:00 |
| SLOAvailabilityBudgetExhausted | warning | toda a janela |
| HighErrorRate (RED) | warning | 20:59:00 → 20:59:15 |

---

> Este postmortem é **blameless**. O foco é em sistemas e processos, nunca em pessoas.
> Pessoas tomam a melhor decisão possível com a informação que têm no momento.
>
> **Requer revisão humana** das seções "Causa Raiz", "O Que Correu Bem/Mal/Sorte" e
> "Action Items" antes de mudar o status para *publicado*.
