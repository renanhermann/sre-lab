# Postmortem — [Título curto do incidente]

> **Status**: rascunho · em revisão · publicado
> **Autor**: Renan Hermann
> **Revisores**: —
> **Data do incidente**: YYYY-MM-DD
> **Data do postmortem**: YYYY-MM-DD
> **Severidade**: SEV1 · SEV2 · SEV3
> **Duração**: HH:MM

---

## Resumo Executivo

> 2 a 3 frases. O que aconteceu, qual foi o impacto, como foi mitigado.
> Deve ser legível por gestor não-técnico.

---

## Impacto

| Dimensão | Valor |
|---|---|
| Usuários afetados | — |
| Requests com erro | — |
| Latência adicional (P99) | — |
| Error budget consumido | — % do orçamento mensal |
| SLOs violados | — |
| Receita/SLA impactados | — |

---

## Linha do Tempo

> Todos os horários em America/Sao_Paulo (UTC−3). Formato: `HH:MM:SS — evento`.
> Inclua: início real do problema, primeiro alerta, primeira ação humana,
> mudança de hipótese, mitigação aplicada, recuperação confirmada, encerramento.

| Hora | Evento | Fonte |
|---|---|---|
| HH:MM:SS | Início do incidente (primeira métrica anômala) | Prometheus |
| HH:MM:SS | Alerta `X` dispara | AlertManager |
| HH:MM:SS | Engenheiro reconhece | — |
| HH:MM:SS | Hipótese inicial: `…` | — |
| HH:MM:SS | Ação aplicada: `…` | — |
| HH:MM:SS | Mitigação confirmada (métricas voltam ao normal) | Prometheus |
| HH:MM:SS | Alerta resolve | AlertManager |
| HH:MM:SS | Incidente encerrado | — |

---

## Detecção

- **Como o incidente foi detectado?** (alerta automático / cliente reportou / observação manual)
- **Tempo até detecção (TTD)**: do início real até o primeiro alerta — `HH:MM`
- **O alerta foi acionável?** (sim/não — se não, registrar como action item)
- **Algum sinal anterior foi perdido?** (warnings, latência crescente, etc.)

---

## Resposta

- **Tempo até reconhecimento (TTA)**: do alerta até alguém olhar — `HH:MM`
- **Tempo até mitigação (TTM)**: do alerta até o sistema estabilizar — `HH:MM`
- **Quem respondeu**: —
- **Runbooks executados**: links para `docs/runbooks/*.md`
- **Comunicação**: onde foi anunciado, para quem, com que cadência

---

## Recuperação

- **O que estabilizou o sistema?** (rollback, scale, kill switch, config change, esperar)
- **A mitigação foi temporária ou definitiva?**
- **Houve impacto residual após "resolvido"?** (filas drenando, cache frio, etc.)

---

## Causa Raiz

> ⚠️ **Marque cada item como FATO ou HIPÓTESE.**
> Fato = comprovado por log/métrica/diff. Hipótese = inferência plausível ainda não validada.

### Causa imediata
> O que disparou o incidente agora. Ex: "deploy X às 14:02 alterou o timeout do client HTTP de 30s para 3s".
> Marque: `[fato]` ou `[hipótese — validar com …]`

### Causa contribuinte
> O que tornou o sistema vulnerável a essa causa imediata. Ex: "ausência de teste de carga no pipeline; timeout não tem default seguro".

### Análise dos 5 porquês (opcional)
1. Por que aconteceu X? — …
2. Por que Y permitiu X? — …
3. Por que Z não detectou Y? — …
4. Por que W não preveniu Z? — …
5. Por que V existe? — …

---

## O Que Correu Bem

- …

## O Que Correu Mal

- …

## Onde Tivemos Sorte

> Coisas que poderiam ter sido muito piores e não foram por circunstância, não por design.
- …

---

## Action Items

> Cada item DEVE ter: owner, prazo, tipo (prevenir/detectar/mitigar), prioridade, link de tracking.
> Action items sem owner não saem do papel.

| # | Ação | Tipo | Owner | Prazo | Prioridade | Tracking |
|---|---|---|---|---|---|---|
| 1 | … | prevenir | — | YYYY-MM-DD | P0/P1/P2 | issue/PR |
| 2 | … | detectar | — | YYYY-MM-DD | P0/P1/P2 | issue/PR |
| 3 | … | mitigar  | — | YYYY-MM-DD | P0/P1/P2 | issue/PR |

---

## Anexos

- Queries PromQL usadas na investigação
- Trechos de log relevantes (Loki)
- Screenshots de dashboards no momento do incidente
- Eventos de cluster (`kubectl get events`)
- Links para alertas históricos no AlertManager

---

> Este postmortem é **blameless**. O foco é em sistemas e processos, nunca em pessoas.
> Pessoas tomam a melhor decisão possível com a informação que têm no momento.
