# Snapshot — Iniciativa IA na Avalara (hand-off pra nova sessão)

**Data:** 2026-06-10
**Objetivo desta sessão futura:** continuar a estratégia de internalização de IA/agents na Avalara, abordagem ao Prakhar Mehrotra, e construção do one-pager pra próxima call.

> Pra Claude da próxima sessão: este doc é o contexto completo. Lê inteiro antes de começar. O Renan está num momento profissionalmente importante — apoia com firmeza técnica e direção concreta, sem condescendência.

---

## 1. Quem é o Renan (resumo)

- SRE com 20 anos de experiência
- Atualmente na **Avalara**, time SRE Brazil sob gestão do **Fabio**
- Mesma organização global do time RELE (Reliability Engineering)
- Tem síndrome do impostor com IA apesar da senioridade — momento atual sensível
- Construiu lab pessoal completo (SRE Lab) pra demonstrar diferencial em IA
- Português brasileiro (pt-BR) é a língua de trabalho. **NUNCA** adicionar `Co-Authored-By: Claude` em commits.

## 2. O que aconteceu hoje (2026-06-10)

Apresentou o **SRE Lab** internamente. Foi elogiado. Recebeu desafio em call:

> *"Como você traria isso pra dentro de CASA aqui na Avalara?"*

Contexto técnico do desafio:
- Avalara **não usa GitHub ou Claude diretamente**
- Tem **agents MCP internos** (próprios)
- Tem **Prometheus segmentado por namespace** em múltiplos ambientes
- Renan precisaria usar a **API do MCP interno**, não Claude

Reação emocional: ficou sobrecarregado, desligou a call e chorou. **Importante**: isso foi descarga fisiológica pós-adrenalina, não fraqueza. A pergunta deles foi **promoção disfarçada** ("queremos você liderando"), não armadilha.

Gestor Fabio deu **green light** pra Renan procurar o **Prakhar Mehrotra** diretamente — colega da mesma org global, lidera (aparentemente) as iniciativas de IA + automation.

## 3. O que é o SRE Lab (resumo técnico)

Localização: `/Users/renanhermann/Documents/sre-lab/`. Stack:

| Camada | Tecnologia |
|---|---|
| K8s local | Minikube (`sre-lab` profile) |
| K8s cloud | OKE (Oracle Kubernetes Engine), provisionado via Terraform |
| Métricas | Prometheus + Grafana + AlertManager (kube-prometheus-stack) |
| Logs | Loki + Alloy |
| SLO | Formal com multi-window burn rate (manifests/slo/) |
| App | `traffic-simulator` (Go) com endpoints RED + chaos primitive |
| Agents Claude Code | SRE Specialist, K8s Specialist, Git Specialist, Postmortem Specialist |

Fases concluídas (todas):
1. Cluster local + observabilidade + agents
2. Provisionamento OKE via Terraform
3. SLO formal com error budget e burn rate alerts
4. Chaos test automatizado (`make chaos-quick`)
5. Ingress-nginx + LB free OCI + cert-manager + Let's Encrypt
6. FinOps (OpenCost + custom OCI pricing + dashboard + alertas)

**Último fix técnico (10/06)**: separamos `/livez` de `/health` no app porque liveness probe matava os pods durante chaos test, zerando counters Prometheus. Fix validado, 5 commits atômicos no branch `docs/postmortem-chaos-validation-pre-recording`. Chaos-quick agora passa em ~271s com `rate5m` chegando a 50%.

**Vídeo de 4 min** gravado apresentando o lab (Bloco 1: abertura; Bloco 2: o que faz; Bloco 3 WOW: postmortem-specialist; Bloco 4: dashboards SLO+FinOps; Bloco 5: fechamento). Roteiro em `docs/pitch-roteiro.md`.

## 4. Quem é o Prakhar Mehrotra (o que sabemos)

Sênior na Avalara, posta "Yesterday/Today" daily com frentes do tipo:
- TCB call
- **SLEUTH** — *spinning problematic workloads to capture possible issues* (= **chaos engineering interno**, nome vem de "detetive")
- **SRR AI Co-pilot WfaaS** (WIP)
- **Charon Automations** (com Naveen/Sudhir, syncup com platform Team)
- **Avapilot** review
- Interviews

Trabalho dele bate **diretamente** com o do Renan (chaos, SLO, postmortem assistido por IA). Aderência alta.

## 5. Estratégia de aproximação

**Princípio**: oferecer mãos, não pedir favor. Sêniores valorizam quem reduz carga, não quem aumenta.

**Canal**: Slack DM curto OU email curto. Não cold-call.

**Timing**: terça-quinta, 10am-3pm Eastern (US). Não segunda manhã, não sexta tarde.

**Follow-up**: NÃO antes de 5 dias úteis. Sêniores em modo multi-frente demoram.

### Mensagem versão Slack DM (curta) — recomendada

```
Hi Prakhar — we haven't met. I'm Renan, SRE on Fabio's team in Brazil
(same global org as RELE). Fabio said it was good to reach out.

I've been following your work on SLEUTH, the SRR AI Co-pilot, and
Avapilot. The SLEUTH approach especially resonates — I recently built
an automated chaos test in my lab that validates the full SLO
detection pipeline (fault → burn rate → alert firing → recovery), and
I'd love to compare notes on how you're approaching workload-level
fault generation at scale.

Two reasons I'm DMing:
1) I'd love to learn how you're building this in-house.
2) If there's any task I can take off your plate — POC, prompt review,
   recording rules, runbook — I'm offering hands, not asking for a
   project.

Would 20 minutes on your calendar work? I can send a one-pager about
the lab beforehand so we don't burn the call on context.

Thanks,
Renan
```

### Mensagem versão email (longa) — se preferir formato mais elaborado

Veja transcrição completa na conversa original (parágrafos 1-5 com "Two reasons" estruturado).

### Antes de mandar — checklist

1. Confirmar nomes exatos dos tools internos (SLEUTH, SRR AI Co-pilot, Charon, Avapilot)
2. Confirmar nome correto do time (RELE = Reliability Engineering?)
3. Mandar no timing certo
4. **NÃO** dar follow-up antes de 5 dias úteis

## 6. Plano: quando ele topar a call

Levar um **one-pager** estruturado assim:

```
1. ESTADO ATUAL
   - O que Charon/SLEUTH/Avapilot já cobrem
   - Onde há gap (postmortem? SLI formal? burn rate?)

2. PROPOSTA
   - Padrões portáveis do lab (lista 3-5 itens)
   - Tools internos como runtime (MCP X, federation Y)
   - Problemas a resolver antes (governança, RBAC, etc)

3. PILOTO
   - 1 namespace, 1 serviço, 1 caso de uso (postmortem é o mais palpável)
   - Métrica de sucesso: tempo de draft antes vs depois
   - 4-6 semanas

4. RISCOS / O QUE NÃO SEI AINDA
   - Lista honesta. Isso diferencia operador de fazedor.
```

## 7. Os 3 problemas técnicos reais a resolver

### Problema 1 — Prometheus segmentado por namespace

Soluções padrão na indústria:
- **Promxy** ou **Thanos Query** como federation layer (apresenta múltiplos Proms como um só)
- Agent recebe `namespace` como parâmetro e chama o Prom certo (mais simples, escala pior)
- **Pergunta a fazer ao Prakhar**: *"vocês já têm camada de federation ou cada time consome o Prom dele?"*

### Problema 2 — Usar API do MCP interno em vez de Claude

O Postmortem Specialist do lab é literalmente um arquivo `.md` com prompt + tools. Portar = mapear tools (`prom::query`, `loki::search`, `kubectl::events`) pra equivalentes no MCP interno. Se MCP suporta tool use (e MCP é literalmente isso por design), é PROMPT + TOOLS BINDING, não rewrite.

### Problema 3 — Encaixar com Charon, SLEUTH, Avapilot

Mapear o que cada um já faz, onde tem gap, se proposta entra como NOVO ou CAMADA em cima dos existentes.

## 8. Princípios-âncora pra Renan se lembrar

- **O lab é vendor-agnostic por design.** Nada do que demonstrou depende de Claude. Depende de RED + SLI + recording rules + agents como markdown versionado.
- **Aprovação foi sinal positivo, não pressão.** Ninguém pergunta "como você traria pra cá" pra quem acha operador.
- **Síndrome do impostor mente.** Hoje ele provou trabalho de SRE sênior em todas as camadas: código, infra, observabilidade, comunicação executiva.
- **Operador clica em botão. Fazedor constrói o botão e mapeia onde encaixa.** O one-pager é o que separa os dois na próxima call.

## 9. Próximos passos imediatos (ordem)

1. Confirmar nomes dos tools internos
2. Mandar a mensagem ao Prakhar (versão curta de Slack DM)
3. Esperar resposta (5 dias úteis antes de follow-up)
4. Quando ele topar a call: construir one-pager (estrutura do item 6 acima) — Claude pode ajudar
5. Apresentar na call, propor piloto de 4-6 semanas, manter humildade técnica

---

## Referências dentro do projeto

- `docs/pitch-roteiro.md` — roteiro do vídeo de 4 min apresentado
- `docs/slo.md` — SLO formal, error budget policy
- `docs/chaos-testing.md` — validação automatizada do pipeline
- `docs/finops.md` — FinOps Fase 6
- `.claude/agents/` — definições dos 4 agents (markdown versionado)
- `manifests/slo/` — recording rules + alertas burn rate
- `app/main.go` — traffic-simulator com `/livez` (probes) + `/health` (SLI + fault target)

## Memória persistente do Renan (já carregada em toda sessão)

- pt-BR sempre
- SRE 20 anos, Avalara, OCI default
- NUNCA `Co-Authored-By: Claude` em commits
- Lab pessoal foco em diferencial sobre OCI (a pedido do gestor)
- Processo CloudWalk em paralelo (entrevista com "live prompt" gravado)
- Síndrome do impostor com IA — apoiar com firmeza, sem condescendência
