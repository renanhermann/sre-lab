# Postmortem — Validação de Chaos Test (fault 50% em /health)

> **Status**: rascunho
> **Autor**: Renan Hermann
> **Revisores**: —
> **Data do incidente**: 2026-05-29
> **Data do postmortem**: 2026-05-29
> **Severidade**: SEV2
> **Duração**: 00:06:00 (janela analisada) · fault ativo por 00:03:22

---

## Resumo Executivo

Durante validação do pipeline de SLO via `make chaos-quick`, um fault injection
de 50% em `/health` causou pico de error rate de 52.60% no `traffic-simulator`,
disparou o alerta crítico `SLOAvailabilityFastBurn` em 191s e provocou 1 restart
de pod por falha de liveness probe. O fault foi desativado pelo cleanup
automático do script e a recovery não foi capturada nesta janela (modo `--skip-recovery`).

---

## Impacto

| Dimensão | Valor |
|---|---|
| Usuários afetados | N/A — ambiente de lab, sem usuários reais |
| Requests com erro | ≈ 1.597 (estimativa: 15 req/s × 360s × 29.56% médio) `[hipótese — derivado de RED]` |
| Error rate pico | **52.60%** às 23:27:30 `[fato]` |
| Error rate médio na janela | 29.56% `[fato]` |
| Latência P99 | 0.005s (estável — fault não injeta latência) `[fato]` |
| Error budget consumido na janela | **0.60 unidades** (de −2.86 para −3.46) `[fato]` |
| SLOs violados | `availability` (alvo 99.5%) `[fato]` |
| Pods reiniciados | 1 (`traffic-simulator-88d8644d7-2cnbs`: 13 → 14 restarts) `[fato]` |

> **Nota sobre o budget**: o `error_budget_remaining` já estava negativo (−2.86) no
> início da janela, herança de chaos tests anteriores no mesmo mês. Não é deste incidente.

---

## Linha do Tempo

Todos os horários em `America/Sao_Paulo` (UTC−3).

| Hora | Evento | Fonte |
|---|---|---|
| 23:26:23 | Baseline saudável confirmado (`error_ratio_rate5m = 0`) | chaos-test.sh |
| 23:26:25 | Fault injetado em pod `2cnbs` (rate=50%, duration=10m) | app log |
| 23:26:28 | Fault injetado em pod `zqf4r` (rate=50%) | app log |
| 23:26:28 | Load gen iniciado (15 req/s em `/health`) | chaos-test.sh |
| 23:26:33 | Taxa de erro observada = 46.67% (30 amostras) | chaos-test.sh |
| 23:27:30 | **Pico de error rate: 52.60%** | Prometheus |
| 23:28:00 | `HighErrorRate` [warning] entra em firing | AlertManager |
| 23:28:03 | Readiness probe falha no pod `2cnbs` (HTTP 500) | kubectl events |
| 23:28:16 | Liveness probe falha no pod `zqf4r` (HTTP 500) | kubectl events |
| 23:28:17 | **Pod `2cnbs` reiniciado** por falha de liveness probe (exitCode=2) | kubectl events |
| 23:28:51 | Readiness probe falha no pod `zqf4r` (sem chegar a restart) | kubectl events |
| 23:29:44 | Métrica `rate5m = 48.6%` confirma burn rate ≫ threshold de 7.2% | chaos-test.sh |
| 23:29:45 | **`SLOAvailabilityFastBurn` [critical] entra em firing** | AlertManager |
| 23:29:47 | Cleanup automático: fault desabilitado em `2cnbs` | app log |
| 23:29:49 | Cleanup automático: fault desabilitado em `zqf4r` | app log |
| 23:29:49 | Chaos test encerra (exit 0) — recovery não esperada (modo quick) | chaos-test.sh |
| 23:31:00 | Fim da janela analisada (`rate5m` ainda em 48.6%, decaindo) | Prometheus |

---

## Detecção

- **Como o incidente foi detectado?** Automaticamente — o próprio chaos test
  monitorou `SLOAvailabilityFastBurn` até virar `firing`. Em cenário real, o
  alerta teria ido para o pager configurado no AlertManager.
- **TTD (tempo até detecção)**: **191s** (3min11s) do início do fault até
  `SLOAvailabilityFastBurn` em `firing`. Compatível com o desenho do alerta
  (fast burn requer `rate5m` e `rate1h` simultaneamente acima do threshold,
  com `for: 2m`).
- **Detecção anterior**: `HighErrorRate` (warning) firou aos 95s — alerta de
  segunda linha. SLOAvailabilityBudgetExhausted e SlowBurn já estavam firing
  no início da janela (estado herdado de chaos tests anteriores).
- **Alerta acionável?** Sim — `SLOAvailabilityFastBurn` tem runbook em
  [`docs/runbooks/slo-burn-rate.md`](../runbooks/slo-burn-rate.md).
- **Sinais perdidos?** Não. A cadeia HighErrorRate → SlowBurn → FastBurn
  funcionou como projetada.

---

## Resposta

- **TTA (tempo até reconhecimento)**: 0s — o chaos test executa como agente
  automatizado; em cenário humano, TTA dependeria do oncall.
- **TTM (tempo até mitigação)**: 2s — cleanup automático disparou
  imediatamente após `firing` confirmado.
- **Quem respondeu**: cleanup automático do `chaos-test.sh` (linhas 53-55 do log).
- **Runbooks executados**: nenhum. Ação foi rollback do fault, não diagnóstico.
- **Comunicação**: N/A — exercício controlado.

---

## Recuperação

- **O que estabilizou o sistema?** Desativação do fault via `POST /admin/fault?rate=0`
  em ambos os pods. O endpoint `/health` voltou a responder 200 imediatamente.
- **Mitigação temporária ou definitiva?** Definitiva para este fault — o pod
  reiniciado já estava saudável aos 23:28:17.
- **Impacto residual?** Sim:
  - `rate5m` decai por ~5 minutos após cleanup (média móvel). No fim da janela
    ainda estava em 48.6%; recovery completa esperada ~23:34:49.
  - `rate1h` decai por ~1 hora — `SLOAvailabilityFastBurn` pode permanecer
    firing por mais alguns minutos enquanto `rate5m` cai abaixo de 7.2%.
  - **A recovery não foi capturada nesta janela** porque o `chaos-quick` usa
    `--skip-recovery`. Para validação completa do ciclo, usar `make chaos-test`.

---

## Causa Raiz

### Causa imediata `[fato]`

O chaos primitive `POST /admin/fault?rate=50&duration=10m` foi disparado
deliberadamente em `/health` para validar o pipeline de SLO. O comportamento
é exatamente o desenhado.

### Causa contribuinte — restart probe-induced `[fato]`

A `livenessProbe` e a `readinessProbe` do pod `traffic-simulator` apontam para
o mesmo endpoint `/health` que o fault ataca. Com `rate=50%` e
`failureThreshold=3`, a probabilidade de restart por ciclo de probe é
P ≈ 0.5³ = 12.5%. Para o pod `2cnbs` o evento ocorreu em ~112s após o início
do fault. Confirmado por:

- evento `Liveness probe failed: HTTP probe failed with statuscode: 500` às 23:28:17
- evento `Container traffic-simulator failed liveness probe, will be restarted`
- `restartCount` aumentou de 13 para 14 (`lastReason=Error, exitCode=2`)

### Causa sistêmica `[hipótese — validar com docs/slo.md §7.2]`

Ausência de endpoint `/readyz` separado para probes do Kubernetes. Em produção
real, probes deveriam consultar um endpoint que mede saúde *do processo*
(handler vivo, deps internas ok), não um endpoint funcional sujeito a injeção
de erro ou degradação de dependência externa. Esse anti-pattern está
documentado no comentário do `scripts/chaos-test.sh` linhas 45-50.

### 5 Porquês

1. **Por que o pod reiniciou?** Liveness probe falhou 3 vezes seguidas (HTTP 500).
2. **Por que a probe recebeu 500?** O endpoint `/health` está injetando 5xx por design (fault test).
3. **Por que a probe usa `/health`?** É o único endpoint disponível para health check no app.
4. **Por que não há `/readyz` separado?** O app é deliberadamente simples no lab; em prod real isso seria separado. `[hipótese]`
5. **Por que essa decisão é defensível no lab?** O comportamento "anti-pattern" é o que torna o chaos test pedagógico — demonstra na prática por que separar probes importa. `[hipótese]`

---

## O Que Correu Bem

> Preencher em revisão humana após sync de postmortem.

Candidatos sugeridos pela coleta:
- Cadeia de alertas funcionou conforme desenho (HighErrorRate → FastBurn).
- TTD compatível com o modelo (191s ≈ janela `rate5m` + `for: 2m`).
- Cleanup automático preveniu consumo excessivo de error budget.

## O Que Correu Mal

> Preencher em revisão humana após sync de postmortem.

Candidatos sugeridos pela coleta:
- Restart de pod ocorreu (ainda que esperado estatisticamente em rate=50%).
- Recovery não foi capturada na janela do `chaos-quick`.

## Onde Tivemos Sorte

> Preencher em revisão humana após sync de postmortem.

---

## Action Items

> Owner e prazo a definir em sync de revisão. Sem owner, item não sai do papel.

| # | Ação | Tipo | Owner | Prazo | Prioridade | Tracking |
|---|---|---|---|---|---|---|
| 1 | Avaliar adicionar endpoint `/readyz` separado dos probes (alinha com prod-pattern) | prevenir | — | — | P2 | — |
| 2 | Considerar rodar `make chaos-test` (full) em sessões de validação para capturar recovery completa | detectar | — | — | P3 | — |
| 3 | Documentar threshold de risco de restart por `fault-rate` em `docs/chaos-testing.md` | mitigar | — | — | P3 | — |

---

## Anexos

### Alertas firing durante a janela (relevantes)

| Alerta | Severidade | Início | Duração na janela |
|---|---|---|---|
| `SLOAvailabilityFastBurn` | critical | 23:29:45 | 75s |
| `HighErrorRate` | warning | 23:28:00 | 180s |
| `SLOAvailabilityBudgetExhausted` | warning | (antes da janela) | toda a janela (estado herdado) |
| `SLOAvailabilitySlowBurn` | warning | (antes da janela) | toda a janela (estado herdado) |
| `SLOAvailabilitySlowestBurn` | warning | (antes da janela) | toda a janela (estado herdado) |

### Alertas filtrados como ruído ambiental (Minikube)

`KubeControllerManagerInstanceUnreachable`, `KubeSchedulerInstanceUnreachable`,
`NodeClockNotSynchronising`, `TargetDown` (control-plane), `etcdMembersDown`,
`etcdInsufficientMembers`, `Watchdog` — endêmicos do Minikube single-node, não
relacionados ao incidente.

### Queries PromQL usadas

```promql
# Error rate (%)
sum(rate(traffic_simulator_requests_total{status=~"5.."}[1m]))
/ sum(rate(traffic_simulator_requests_total[1m])) * 100

# Alertas firing (timeline)
ALERTS{alertstate="firing"}

# SLO burn rate
slo:traffic_simulator_availability:error_ratio_rate5m
slo:traffic_simulator_availability:error_ratio_rate1h
slo:traffic_simulator_availability:error_budget_remaining
```

### Logs Loki relevantes

```
23:29:47  level=WARN msg="fault injection desativada manualmente"
23:29:49  level=WARN msg="fault injection desativada manualmente"
```

(Nenhuma linha de log de erro do `traffic-simulator` durante o pico — o handler
de `/health` retorna 500 silenciosamente quando o fault está ativo, comportamento
esperado.)

### Eventos K8s

```
23:28:03 [Warning] Unhealthy on 2cnbs: Readiness probe failed: HTTP 500
23:28:16 [Warning] Unhealthy on zqf4r: Liveness probe failed: HTTP 500
23:28:17 [Warning] Unhealthy on 2cnbs: Liveness probe failed: HTTP 500
23:28:17 [Normal]  Killing on 2cnbs: failed liveness probe, will be restarted
23:28:51 [Warning] Unhealthy on zqf4r: Readiness probe failed: HTTP 500
```

---

> Este postmortem é **blameless**. O fault foi injetado deliberadamente pelo
> próprio operador para validar o pipeline; o "incidente" é um exercício
> pedagógico. Em incidente real, o foco seria em sistemas e processos, nunca
> em pessoas.
