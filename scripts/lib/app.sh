# shellcheck shell=bash
#
# Helpers para controlar o traffic-simulator durante o chaos test:
# ativar/desativar fault injection e gerar carga sustentada.
# Assume que o caller já fez port-forward (APP_URL aponta pra ele).

: "${APP_URL:=http://localhost:18080}"

# app::healthy — verifica que o endpoint /health responde 2xx.
app::healthy() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}/health")
  [[ "${code}" == "200" ]]
}

# app::wait_healthy <timeout_s>
app::wait_healthy() {
  local timeout="${1:-30}"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    app::healthy && return 0
    sleep 1
  done
  return 1
}

# app::fault_set_all <rate> <duration> — ativa fault em CADA pod do deployment.
# Necessário porque o fault state é local ao pod (limitação documentada em
# docs/slo.md §7.3). Usa port-forward dinâmico por pod, com porta variável
# pra evitar conflito quando rodado em paralelo.
app::fault_set_all() {
  local rate="$1"
  local duration="$2"
  # `mapfile` é bash 4+; macOS shippa bash 3.2 por padrão.
  # Usar `while read` é portável, MAS exige `|| [[ -n "${line}" ]]` porque
  # `read` retorna falha na última linha quando não termina com newline,
  # mesmo tendo lido o conteúdo — sem isso, perdemos o último pod.
  local pods=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] && pods+=("${line}")
  done < <(kubectl get pod -l app=traffic-simulator -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')

  if (( ${#pods[@]} == 0 )); then
    log::error "  nenhum pod traffic-simulator encontrado"
    return 1
  fi

  local base_port=18091
  local i=0
  local failures=0
  for pod in "${pods[@]}"; do
    [[ -z "${pod}" ]] && continue
    local port=$(( base_port + i ))
    kubectl port-forward "pod/${pod}" "${port}:8080" > /dev/null 2>&1 &
    local pf_pid=$!
    sleep 2.5

    local resp
    resp=$(curl -sf -X POST "http://localhost:${port}/admin/fault?rate=${rate}&duration=${duration}" || echo "")
    if [[ -z "${resp}" ]]; then
      log::warn "  [${pod}] fault não respondeu"
      failures=$(( failures + 1 ))
    else
      log::info "  [${pod}] fault: ${resp}"
    fi
    kill "${pf_pid}" 2>/dev/null || true
    wait "${pf_pid}" 2>/dev/null || true
    i=$(( i + 1 ))
  done

  if (( failures > 0 )); then
    log::warn "  ${failures}/${#pods[@]} pods não confirmaram fault"
    return 1
  fi
  return 0
}

# app::fault_clear_all — desativa fault em todos os pods.
app::fault_clear_all() {
  app::fault_set_all 0 1s
}

# app::start_load <rps> — inicia gerador de carga em background.
# Escreve PID em /tmp/chaos-load.pid pra cleanup posterior.
app::start_load() {
  local rps="${1:-15}"
  app::stop_load  # idempotente — mata qualquer load anterior

  nohup bash -c "
    while true; do
      for i in \$(seq 1 ${rps}); do
        curl -s -o /dev/null --max-time 1 ${APP_URL}/health &
      done
      wait
      sleep 1
    done
  " > /dev/null 2>&1 &
  echo $! > /tmp/chaos-load.pid
  log::info "  load gen iniciado (PID=$(cat /tmp/chaos-load.pid), ${rps} rps)"
}

# app::stop_load — para o gerador.
app::stop_load() {
  if [[ -f /tmp/chaos-load.pid ]]; then
    local pid
    pid=$(cat /tmp/chaos-load.pid 2>/dev/null || echo "")
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f /tmp/chaos-load.pid
  fi
  # Mata curls órfãos do loop
  pkill -f "curl.*--max-time 1 ${APP_URL}/health" 2>/dev/null || true
}

# app::observed_error_rate <n> — amostra N requests e retorna a fração de erro
# observada (0.0 a 1.0). Útil pra confirmar que fault está propagando.
app::observed_error_rate() {
  local n="${1:-30}"
  local err=0
  for ((i=0; i<n; i++)); do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "${APP_URL}/health")
    [[ "${code}" != "200" ]] && err=$(( err + 1 ))
  done
  python3 -c "print(f'{${err}/${n}:.4f}')"
}
