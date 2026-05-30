# Postmortems

Documentação de incidentes do SRE Lab.
Cada postmortem é um exercício **blameless**: foco em sistemas e processos, nunca em pessoas.

## Filosofia

1. **Fato vs hipótese**. Tudo que vem de log/métrica/diff é fato. Tudo que é inferência
   precisa estar marcado como hipótese, com nota de como validar.
2. **Action items sem owner não saem do papel**. Owner e prazo são obrigatórios.
3. **Postmortems são vivos**. O draft inicial é gerado em minutos pelo agent.
   A análise definitiva sai da revisão humana.

## Como gerar um postmortem

### 1. Pré-requisitos

```bash
./cluster/start.sh           # cluster rodando
./cluster/expose.sh          # port-forwards de Prom/Loki ativos
```

### 2. Defina a janela e o nome do incidente

A janela precisa cobrir:
- ~2 minutos antes do primeiro sinal anômalo
- até ~5 minutos após recovery confirmado

Exemplo:

```text
Nome:       latency-spike-chaos-validation
Severidade: SEV2
Janela:     2026-05-29T21:15:00-03:00 → 2026-05-29T21:35:00-03:00
Contexto:   chaos test com fault rate 50% por 10 minutos
```

### 3. Invoque o agent

No Claude Code, dentro deste repo:

```text
> use o postmortem-specialist pra gerar o postmortem do incidente
  "latency-spike-chaos-validation" entre 2026-05-29T21:15-03:00
  e 2026-05-29T21:35-03:00, severidade SEV2.
  Contexto: chaos test com fault rate 50%.
```

O agent vai:
1. Verificar Prometheus, Loki e kubectl
2. Coletar alertas firing históricos, RED metrics, burn rate, logs e eventos
3. Preencher o `TEMPLATE.md` com os dados, marcando fato vs hipótese
4. Salvar em `docs/postmortems/YYYY-MM-DD-<slug>.md`
5. Devolver um sumário com contagem de alertas, eventos, e itens de revisão

### 4. Revisão humana (obrigatória)

O draft do agent **não é publicável** sem revisão. Antes de mergear:

- [ ] Validar cada `[hipótese]` em "Causa Raiz" — confirmar ou rejeitar
- [ ] Preencher "O Que Correu Bem", "O Que Correu Mal", "Onde Tivemos Sorte"
- [ ] Atribuir owner e prazo a cada action item
- [ ] Verificar que nenhum dado sensível vazou (IPs internos reais, nomes de clientes)
- [ ] Mudar status no topo de `rascunho` para `em revisão` → `publicado`

### 5. Commit e abertura de PR

```bash
git checkout -b docs/postmortem-YYYY-MM-DD-<slug>
git add docs/postmortems/YYYY-MM-DD-<slug>.md
git commit -m "docs(postmortem): adiciona postmortem de <slug>"
git push -u origin docs/postmortem-YYYY-MM-DD-<slug>
gh pr create --fill
```

## Naming convention

`YYYY-MM-DD-<slug-kebab-case>.md`

- `YYYY-MM-DD` = data do **incidente** (não a do postmortem)
- `<slug>` = curto, descritivo. Exemplos:
  - `2026-05-28-chaos-test-fault-50pct.md`
  - `2026-06-15-oom-traffic-simulator.md`
  - `2026-07-02-prometheus-rule-eval-failure.md`

## Severidade

| Nível | Critério |
|---|---|
| SEV1 | Indisponibilidade total ou burn rate de `BudgetExhausted` firing |
| SEV2 | Degradação significativa, SLO violado, burn rate `1h` firing |
| SEV3 | Sintoma detectado mas sem violação de SLO; investigação preventiva |

## O que NÃO incluir

- Dados sensíveis de clientes (este é um repo público)
- IPs internos reais (use `10.x.x.x` ou `<redacted>`)
- Credenciais, tokens, secrets — mesmo em logs colados
- Nomes de pessoas em contexto negativo (blameless: cite por função, não por nome)

## Referências

- [Google SRE Workbook — Postmortem Culture](https://sre.google/workbook/postmortem-culture/)
- [Google SRE Book — Postmortem Philosophy](https://sre.google/sre-book/postmortem/)
- `TEMPLATE.md` neste diretório
- `.claude/agents/postmortem-specialist.md` — definição do agent
