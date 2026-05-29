# Chaos testing automatizado

`scripts/chaos-test.sh` valida que o pipeline de SLO (recording rules
→ burn rate alerts → recuperação) **realmente funciona** rodando o
ciclo completo de incidente em ambiente controlado. É a contraparte
automatizada do tour manual descrito em [`slo.md`](slo.md) §6.

> O objetivo não é "estressar o serviço". É **provar que o aparato de
> detecção dispara e recupera dentro de SLAs internos** — pronto pra
> rodar como gate em PR (futuro) ou agendado em CI.

## TL;DR

```bash
make chaos-baseline    # ~5s   — só valida que sistema está saudável
make chaos-quick       # ~5min — sem fase de recovery
make chaos-test        # ~10-15min — ciclo completo, retorna pass/fail
make chaos-clean       # rede de segurança: desativa qualquer fault ativo
```

Exit code zero = sucesso. Qualquer outro = falha codificada
(ver [Códigos de saída](#códigos-de-saída)).

## O que o teste faz

1. **Pré-flight** — checa dependências (kubectl, curl, python3) e que
   `deployment/traffic-simulator` existe no contexto kube atual.
2. **Port-forwards** — sobe ponte local pro app (`:18080`) e Prometheus
   (`:19090`). Limpos via `trap EXIT`, mesmo em falha.
3. **Baseline check** — rejeita executar se `error_ratio_rate5m ≥ 1%` ou
   se o alerta alvo já está firing. Chaos test em sistema doente é
   inútil: você não consegue distinguir o seu efeito do ruído de fundo.
4. **Fault injection** — chama `/admin/fault` em **cada pod** do
   deployment (fault state é local ao pod — limitação documentada em
   `slo.md` §7.3) e inicia gerador de carga sustentada via curl.
5. **Espera pelo alerta** — faz polling em `/api/v1/alerts` a cada 10s
   até o alerta entrar no estado esperado (default: `firing`), ou
   estourar timeout.
6. **Validação semântica** — confirma que `rate5m > 7.2%` E `rate1h > 7.2%`
   no momento do firing. Isso protege contra o cenário "alerta disparou
   por motivo errado" (configuração inconsistente, métrica corrompida).
7. **Desativa fault e gerador de carga.**
8. **Espera recuperação** — polling até o alerta voltar pra `inactive`
   (rate5m precisa cair abaixo do threshold, o que demora alguns minutos).
9. **Cleanup garantido** — `trap` desliga port-forwards e tenta desativar
   fault como rede de segurança, **mesmo se o teste falhar no meio**.

## Opções de execução

```text
--fault-rate=N          % de 5xx a injetar em /health (default 80)
--fault-duration=Xs     duração do fault no app (default 10m, auto-reset)
--load-rps=N            req/s sustentado em /health (default 15)
--alert=NAME            alerta esperado (default SLOAvailabilityFastBurn)
--timeout-firing=N      timeout aguardando firing (default 360s)
--timeout-recovery=N    timeout aguardando recovery (default 600s)
--skip-recovery         pula a fase de recuperação (modo "quick")
--baseline-only         só roda checagem de baseline e sai
-h, --help              ajuda
```

Combinações úteis:

```bash
# Validar configuração de outro alerta (Medium burn em vez de Fast)
./scripts/chaos-test.sh \
  --alert=SLOAvailabilityMediumBurn \
  --timeout-firing=720

# Smoke test mínimo pra um pre-commit hook (~30s, só baseline)
./scripts/chaos-test.sh --baseline-only

# Teste agressivo: rate=100, carga alta, timeouts curtos
./scripts/chaos-test.sh \
  --fault-rate=100 --load-rps=30 \
  --timeout-firing=180 --timeout-recovery=300
```

## Códigos de saída

| Code | Significado | Causa típica |
|---|---|---|
| 0 | Sucesso | Tudo passou |
| 1 | Baseline inválido | Sistema já degradado ou alerta já firing antes do teste |
| 2 | Alerta não disparou | `timeout-firing` estourou; pode indicar regressão no SLO ou carga insuficiente |
| 3 | Métricas inconsistentes | Alerta firing mas rate abaixo do threshold (desenho do alerta quebrado) |
| 4 | Recuperação não aconteceu | Sistema ficou degradado mesmo após cessar fault |
| 10 | Erro de infraestrutura | kubectl ausente, port-forward falhou, deployment não existe |

## Por que validação semântica importa

O passo 6 acima parece redundante (se alerta firing, por definição as
métricas cruzaram o threshold). Mas há cenários onde **alerta firing
por motivo errado** vira incidente:

- Bug em recording rule fazendo retornar valor incorreto
- Alerta apontando pra métrica diferente do que parece
- Threshold hardcoded fora do que o config sugere
- Inconsistência entre as duas janelas do multi-burn-rate

A validação semântica detecta isso assertando que **as duas condições
do alerta estão de fato satisfeitas no momento do firing observado**.

## Saída esperada

Run bem sucedido (`make chaos-quick`, ~3-5min):

```
── Pré-flight ──
  kubectl, curl, python3 OK
  traffic-simulator presente

── Port-forwards ──
  app port-forward OK (:18080)
  Prometheus port-forward OK (:19090)

── Baseline check ──
  error_ratio_rate5m atual = 0
  baseline saudável (rate5m < 1%)
  SLOAvailabilityFastBurn atual = inactive
  baseline OK

── Injetando fault (rate=80%, duração=10m) ──
  [traffic-simulator-...-2cnbs] fault: enabled
  [traffic-simulator-...-zqf4r] fault: enabled
  load gen iniciado (PID=..., 15 rps)
  taxa de erro observada (30 amostras) = 0.7333

── Aguardando SLOAvailabilityFastBurn ir pra firing (timeout 360s) ──
  [t+0s]   SLOAvailabilityFastBurn = inactive
  [t+50s]  SLOAvailabilityFastBurn = pending
  [t+171s] SLOAvailabilityFastBurn = firing
  SLOAvailabilityFastBurn firing após 171s

── Validando métricas no momento do firing ──
  rate5m = 0.1611  (threshold fast = 0.072)
  rate1h = 0.0876  (threshold fast = 0.072)
  métricas confirmam burn rate acima do threshold
```

## Integração com CI (Fase 4 futura)

Próximo passo planejado: um workflow GitHub Actions que:

1. Sobe Minikube via `medyagh/setup-minikube`
2. Aplica manifests da app + SLO
3. Roda `make chaos-quick` (com timeouts maiores pra absorver setup)
4. Falha o build se exit code ≠ 0
5. Anexa o log do teste como artifact

Isso transforma o repo em "**self-validating SRE lab**": qualquer
mudança que quebre o pipeline de detecção falha CI. Mexer numa
recording rule sem perceber que quebrou um alerta vira erro de PR,
não incidente em prod.

## Trade-off do fault rate default

O default é `--fault-rate=50` em vez de algo mais agressivo (80-100%)
por uma razão concreta descoberta durante validação:

Em rates ≥ 80%, o **livenessProbe do app falha consistentemente** —
ele bate em `/health`, que é justamente onde o fault injeta erro.
Com `failureThreshold: 3` padrão, P(restart) ≈ `0.8³ = 51%` por ciclo
de 30s. Resultado: pods reiniciam várias vezes durante o teste, o
port-forward perde o backend, a carga não chega no app, e o teste
**falha falsamente** (alerta não dispara porque nem tráfego está sendo
processado).

Em rate=50%, P(restart) cai pra `0.5³ = 12.5%` por ciclo — baixo o
suficiente pra teste passar consistentemente, alto o suficiente pra
cruzar threshold fast burn (7.2%) com folga.

Solução "correta" pra produção (não aplicada no lab): separar `/readyz`
(probe) de `/health` (SLI), pra fault injection não cascatear pro
controle do kubelet. Ver `slo.md` §7.2 — anti-pattern documentado.

## Limitações conhecidas

- **Fault state local ao pod** — o script ativa fault em cada pod
  individualmente via port-forward; em deploys com muitas réplicas,
  isso fica lento. Em produção real, usaria Chaos Mesh ou Litmus pra
  controle declarativo.
- **macOS bash 3.2** — todos os scripts foram escritos pra ser portáveis
  (sem `mapfile`, sem `${var,,}`), porque a `bash` default do macOS é
  3.2 e não dá pra exigir bash 4+ de usuários do lab. CI com bash 5+
  funciona igual.
- **Carga via port-forward local** — passar tudo pelo `kubectl
  port-forward` adiciona latência e gargalo de banda. Pra testes mais
  realistas, daria pra rodar a carga dentro do cluster (Job ou
  CronJob), mas isso aumenta complexidade do script.
- **Recovery threshold é o mesmo do alerta** — o teste considera
  "recuperado" quando o alerta sai de firing. Em produção, recuperação
  é uma decisão mais sutil (causa raiz corrigida, não só métrica
  voltando). Aqui aceitamos a definição simples porque o objetivo é
  validar o pipeline de detecção, não o pipeline de resposta.

## Referências

- `scripts/chaos-test.sh` — entrypoint, parseia args, orquestra
- `scripts/lib/log.sh` — logging estruturado
- `scripts/lib/prom.sh` — queries Prometheus + estado de alertas
- `scripts/lib/app.sh` — controle de fault e carga no app
- [`docs/slo.md`](slo.md) — definições formais que esse teste valida
- [`docs/runbooks/slo-burn-rate.md`](runbooks/slo-burn-rate.md) — runbook acionado quando o alerta firing chega ao plantão
