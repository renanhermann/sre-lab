# Runbook: SLO Burn Rate

**Alertas cobertos**: `SLOAvailabilityFastBurn`, `SLOAvailabilityMediumBurn`,
`SLOAvailabilitySlowBurn`, `SLOAvailabilitySlowestBurn` (e análogos `SLOLatency*`).
**Serviço**: traffic-simulator
**Referência**: `docs/slo.md` (definições e matemática)

---

## Por que esse alerta dispara

Cada alerta exige **duas** janelas (long + short) acima do mesmo
threshold de error rate, derivado do burn rate da classe:

| Alerta | Long × Short | Burn | Significado |
|---|---|---|---|
| FastBurn | 1h × 5m | 14.4× | Vai consumir 2% do budget em 1h |
| MediumBurn | 6h × 30m | 6× | Vai consumir 5% do budget em 6h |
| SlowBurn | 1d × 2h | 3× | Vai consumir 10% do budget em 1d |
| SlowestBurn | 3d × 6h | 1× | Degradação prolongada — erosão lenta |

A condição combinada protege contra:
- **Falso positivo** (ruído transitório que sumiria na long window)
- **Alerta obsoleto** (problema já cessou — short window cai abaixo do threshold)

## Sintomas

- Alerta `SLO*Burn` ativo no AlertManager (`severity=critical` → page; `warning` → ticket)
- Dashboard "SLO — traffic-simulator" no Grafana mostra error ratio
  acima das linhas tracejadas em uma ou mais janelas
- Tráfego de produção (`path !~ "/stress/.*"`) com taxa anômala de 5xx
  ou latência > 500ms

## Diagnóstico

### 1. Confirmar burn rate atual

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &

for w in 5m 30m 1h 6h 1d 3d; do
  echo -n "availability rate$w: "
  curl -s --data-urlencode "query=slo:traffic_simulator_availability:error_ratio_rate$w" \
    http://localhost:19090/api/v1/query \
    | python3 -c "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(f\"{float(r[0]['value'][1]):.4f}\" if r else 'NaN')"
done
```

### 2. Verificar quanto budget já foi consumido

```bash
curl -s --data-urlencode 'query=slo:traffic_simulator_availability:error_budget_remaining' \
  http://localhost:19090/api/v1/query \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('budget restante:', d['data']['result'][0]['value'][1])"
```

Resultado **negativo** significa budget já estourado — alerta
`SLOAvailabilityBudgetExhausted` vai disparar (ou já disparou).

### 3. Identificar a origem da falha

```bash
# Top status codes nos últimos 5min (excluindo /stress/*)
curl -sg --data-urlencode 'query=topk(5, sum by (status, path) (rate(traffic_simulator_requests_total{path!~"/stress/.*"}[5m])))' \
  http://localhost:19090/api/v1/query
```

```bash
# Logs de erro nos últimos 5min via Loki
LOKI_URL=http://localhost:3100  # após cluster/expose.sh
curl -sG "$LOKI_URL/loki/api/v1/query_range" \
  --data-urlencode 'query={app="traffic-simulator"} |= "ERROR"' \
  --data-urlencode "start=$(date -v-5M -u +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000"
```

### 4. Checar se o problema é chaos primitive ativo

Se o alerta dispara em ambiente de teste, **confirmar** se há fault
injection ativa antes de tratar como incidente:

```bash
# Dispara um GET /health e olha o response — se /admin/fault ativo,
# response.reason = "fault injection active"
kubectl port-forward svc/traffic-simulator 18080:8080 &
for i in 1 2 3 4 5; do
  curl -s http://localhost:18080/health | python3 -m json.tool
done
```

Se houver fault ativo e for não-intencional:

```bash
curl -X POST "http://localhost:18080/admin/fault?rate=0"
```

## Resposta por severidade

### Fast/Medium burn (`severity: critical`, `page: true`)

- **SLA de resposta**: imediato (acordar plantão)
- Identificar release recente: `kubectl rollout history deployment/traffic-simulator`
- Se correlação com release: `kubectl rollout undo deployment/traffic-simulator`
- Se não: capturar evidência (curl `/api/v1/alerts`, gravar dashboard)
  e escalar para investigação

### Slow/Slowest burn (`severity: warning`, `page: false`)

- **SLA de resposta**: próxima janela útil (1 dia útil)
- Abrir ticket com:
  - Burn rate observado por janela (output do passo 1)
  - Budget restante (passo 2)
  - Distribuição de erros (passo 3)
  - Hipótese inicial de causa raiz
- Investigar tendência: subiu degrau? crescimento gradual? sazonalidade?

### `SLOAvailabilityBudgetExhausted` / `SLOLatencyBudgetExhausted`

- Acionar **política de error budget** (ver `docs/slo.md` §5):
  - Freeze de mudanças não-críticas
  - Capacidade de release direcionada para confiabilidade
  - Postmortem público obrigatório do incidente que consumiu o budget
- O freeze sai quando SLI rolling 30d volta ao target.

## Critérios de resolução

- Burn rate em **todas** as janelas relevantes abaixo do threshold por
  pelo menos o tempo do `for:` correspondente
- Error budget restante crescendo (não mais consumindo)
- Verificação de que a causa raiz foi corrigida (não só auto-mitigação
  por restart, throttling ou recuo de carga)

## Referências

- `docs/slo.md` — definições formais, matemática completa, política de budget
- `manifests/slo/availability-slo.yaml` — recording rules + alertas
- `manifests/slo/latency-slo.yaml` — recording rules + alertas
- Google SRE Workbook, cap 5 — https://sre.google/workbook/alerting-on-slos/
