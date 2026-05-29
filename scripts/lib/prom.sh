# shellcheck shell=bash
#
# Helpers para consultar Prometheus durante o chaos test.
# Assume que o caller já fez port-forward (variável PROM_URL aponta pra ele).

: "${PROM_URL:=http://localhost:19090}"

# prom::query <expr> — executa uma instant query e retorna o valor escalar.
# Retorna "NaN" se a expressão não casou com séries.
prom::query() {
  local expr="$1"
  curl -sf -G --data-urlencode "query=${expr}" "${PROM_URL}/api/v1/query" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d['data']['result']
    print(r[0]['value'][1] if r else 'NaN')
except Exception:
    print('NaN')
"
}

# prom::healthy — verifica que o endpoint está vivo.
prom::healthy() {
  curl -sf -o /dev/null "${PROM_URL}/-/healthy"
}

# prom::wait_healthy <timeout_s> — espera até o Prometheus responder healthy.
prom::wait_healthy() {
  local timeout="${1:-30}"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    prom::healthy && return 0
    sleep 1
  done
  return 1
}

# prom::alert_state <alertname> [slo_label] — retorna o estado atual do alerta:
# "firing", "pending" ou "inactive". Se múltiplas séries existirem, prioriza
# firing > pending > inactive.
prom::alert_state() {
  local alertname="$1"
  local slo_label="${2:-}"

  curl -sf "${PROM_URL}/api/v1/alerts" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
target = '${alertname}'
slo = '${slo_label}'
states = []
for a in d['data']['alerts']:
    if a['labels'].get('alertname') != target:
        continue
    if slo and a['labels'].get('slo') != slo:
        continue
    states.append(a['state'])
# Prioridade: firing > pending > inactive
for s in ('firing', 'pending', 'inactive'):
    if s in states:
        print(s); sys.exit()
print('inactive')
"
}

# prom::wait_for_alert <alertname> <expected_state> <timeout_s>
#                     [poll_interval_s] [slo_label]
# Faz polling até o alerta entrar no estado esperado ou estourar timeout.
# Retorna 0 em sucesso, 1 em timeout. Imprime ticks de progresso.
prom::wait_for_alert() {
  local alertname="$1"
  local expected="$2"
  local timeout="${3:-300}"
  local poll="${4:-10}"
  local slo_label="${5:-availability}"

  local start
  start=$(date +%s)
  local deadline=$(( start + timeout ))

  while (( $(date +%s) < deadline )); do
    local state
    state=$(prom::alert_state "${alertname}" "${slo_label}")
    local elapsed=$(( $(date +%s) - start ))
    log::info "  [t+${elapsed}s] ${alertname} = ${state} (alvo: ${expected})"
    if [[ "${state}" == "${expected}" ]]; then
      return 0
    fi
    sleep "${poll}"
  done
  return 1
}
