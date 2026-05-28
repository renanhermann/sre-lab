#!/usr/bin/env bash
#
# chaos-test.sh — teste automatizado de SLO do traffic-simulator.
#
# Roda o ciclo completo: baseline → injeção de fault → confirma alerta
# firing → desliga fault → confirma recuperação. Retorna exit code não-zero
# em qualquer falha, pronto pra integrar em CI.
#
# Uso:
#   ./scripts/chaos-test.sh [opções]
#
# Opções:
#   --fault-rate=N          % de 5xx a injetar em /health (default 80)
#   --fault-duration=Xs     duração do fault no app (default 10m, auto-reset)
#   --load-rps=N            req/s sustentado em /health (default 15)
#   --alert=NAME            alerta esperado (default SLOAvailabilityFastBurn)
#   --timeout-firing=N      segundos até considerar "alerta não disparou" (default 360)
#   --timeout-recovery=N    segundos até considerar "não recuperou" (default 600)
#   --skip-recovery         pula a fase de recuperação (modo "quick")
#   --baseline-only         só roda checagem de baseline e sai
#   -h, --help              imprime esta ajuda
#
# Códigos de saída:
#   0   sucesso
#   1   baseline inválido (sistema não estava saudável antes do teste)
#   2   alerta não disparou no timeout
#   3   métricas não confirmaram o burn rate esperado
#   4   recuperação não aconteceu no timeout
#   10  erro de infraestrutura (port-forward, kubectl, etc)

set -euo pipefail

# ── Bootstrap ───────────────────────────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/prom.sh
source "${SCRIPT_DIR}/lib/prom.sh"
# shellcheck source=lib/app.sh
source "${SCRIPT_DIR}/lib/app.sh"

# ── Defaults ────────────────────────────────────────────────────────────
#
# FAULT_RATE em 50% é um compromisso deliberado:
# - alto suficiente pra rate5m cruzar threshold 7.2% confortavelmente
# - baixo suficiente pra não disparar liveness probe restart na maioria
#   das vezes (failureThreshold=3 → P(restart) ≈ 0.5³ = 12.5% por ciclo)
# Rates ≥ 80% tornam o teste flaky por restart-induced port-forward drop.
# Em prod real, esse anti-pattern é mitigado com /readyz separado pra
# probes — não aplicado no lab. Ver docs/slo.md §7.2.
FAULT_RATE=50
FAULT_DURATION=10m
LOAD_RPS=15
ALERT_NAME=SLOAvailabilityFastBurn
TIMEOUT_FIRING=360
TIMEOUT_RECOVERY=600
SKIP_RECOVERY=0
BASELINE_ONLY=0

# Threshold do alerta (fast burn = 14.4 × budget 0.5% = 7.2%)
FAST_THRESHOLD=0.072

# Portas locais usadas pelos port-forwards
APP_URL=http://localhost:18080
PROM_URL=http://localhost:19090
export APP_URL PROM_URL

# PIDs de port-forwards iniciados aqui — pra cleanup no trap
PF_APP_PID=""
PF_PROM_PID=""

# ── Args ────────────────────────────────────────────────────────────────
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

for arg in "$@"; do
  case "${arg}" in
    --fault-rate=*)       FAULT_RATE="${arg#*=}" ;;
    --fault-duration=*)   FAULT_DURATION="${arg#*=}" ;;
    --load-rps=*)         LOAD_RPS="${arg#*=}" ;;
    --alert=*)            ALERT_NAME="${arg#*=}" ;;
    --timeout-firing=*)   TIMEOUT_FIRING="${arg#*=}" ;;
    --timeout-recovery=*) TIMEOUT_RECOVERY="${arg#*=}" ;;
    --skip-recovery)      SKIP_RECOVERY=1 ;;
    --baseline-only)      BASELINE_ONLY=1 ;;
    -h|--help)            usage ;;
    *) log::error "argumento desconhecido: ${arg}"; exit 10 ;;
  esac
done

# ── Cleanup garantido ───────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  log::section "Cleanup"
  app::stop_load 2>/dev/null || true
  # Desliga fault como rede de segurança — não falha o teste se isso falhar
  if [[ -n "${PF_APP_PID}" ]]; then
    app::fault_clear_all 2>/dev/null || log::warn "  não consegui desativar fault no cleanup"
  fi
  [[ -n "${PF_APP_PID}"  ]] && kill "${PF_APP_PID}"  2>/dev/null || true
  [[ -n "${PF_PROM_PID}" ]] && kill "${PF_PROM_PID}" 2>/dev/null || true
  wait 2>/dev/null || true
  log::info "  cleanup completo"
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ── Sanity de dependências ──────────────────────────────────────────────
log::section "Pré-flight"
for bin in kubectl curl python3; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    log::error "dependência ausente: ${bin}"
    exit 10
  fi
done
log::info "  kubectl, curl, python3 OK"

if ! kubectl get deployment traffic-simulator >/dev/null 2>&1; then
  log::error "deployment traffic-simulator não encontrado no contexto atual"
  log::error "  contexto: $(kubectl config current-context 2>/dev/null || echo '?')"
  exit 10
fi
log::info "  traffic-simulator presente"

# ── Port-forwards ───────────────────────────────────────────────────────
log::section "Port-forwards"
kubectl port-forward svc/traffic-simulator 18080:8080 > /tmp/chaos-pf-app.log 2>&1 &
PF_APP_PID=$!
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 > /tmp/chaos-pf-prom.log 2>&1 &
PF_PROM_PID=$!

if ! app::wait_healthy 15; then
  log::error "app não respondeu em :18080 (port-forward falhou?)"
  exit 10
fi
log::info "  app port-forward OK (:18080)"

if ! prom::wait_healthy 15; then
  log::error "Prometheus não respondeu em :19090 (port-forward falhou?)"
  exit 10
fi
log::info "  Prometheus port-forward OK (:19090)"

# ── Baseline ────────────────────────────────────────────────────────────
log::section "Baseline check"
baseline_rate=$(prom::query "slo:traffic_simulator_availability:error_ratio_rate5m")
log::info "  error_ratio_rate5m atual = ${baseline_rate}"

# Aceita NaN (sem tráfego) ou rate < 1%
if [[ "${baseline_rate}" != "NaN" ]]; then
  if python3 -c "import sys; sys.exit(0 if float('${baseline_rate}') < 0.01 else 1)"; then
    log::ok "  baseline saudável (rate5m < 1%)"
  else
    log::fail "  baseline degradado — rate5m=${baseline_rate} (esperado < 1%)"
    log::fail "  abortando: chaos test exige sistema saudável antes"
    exit 1
  fi
fi

state=$(prom::alert_state "${ALERT_NAME}" availability)
log::info "  ${ALERT_NAME} atual = ${state}"
if [[ "${state}" == "firing" ]]; then
  log::fail "  ${ALERT_NAME} já está firing — abortando"
  exit 1
fi
log::ok "  baseline OK"

if (( BASELINE_ONLY == 1 )); then
  log::ok "Baseline-only: sucesso."
  exit 0
fi

# ── Ativa fault + carga ─────────────────────────────────────────────────
log::section "Injetando fault (rate=${FAULT_RATE}%, duração=${FAULT_DURATION})"
if ! app::fault_set_all "${FAULT_RATE}" "${FAULT_DURATION}"; then
  log::error "não consegui ativar fault em todos os pods"
  exit 10
fi
app::start_load "${LOAD_RPS}"

sleep 5
observed=$(app::observed_error_rate 30)
log::info "  taxa de erro observada (30 amostras) = ${observed}"

# ── Aguarda alerta firing ───────────────────────────────────────────────
log::section "Aguardando ${ALERT_NAME} ir pra firing (timeout ${TIMEOUT_FIRING}s)"
t0=$(date +%s)
if ! prom::wait_for_alert "${ALERT_NAME}" firing "${TIMEOUT_FIRING}" 10 availability; then
  log::fail "  alerta NÃO entrou em firing no tempo limite"
  log::info "  estado final: $(prom::alert_state "${ALERT_NAME}" availability)"
  log::info "  rate5m: $(prom::query "slo:traffic_simulator_availability:error_ratio_rate5m")"
  log::info "  rate1h: $(prom::query "slo:traffic_simulator_availability:error_ratio_rate1h")"
  exit 2
fi
t_firing=$(( $(date +%s) - t0 ))
log::ok "  ${ALERT_NAME} firing após ${t_firing}s"

# ── Validação semântica ─────────────────────────────────────────────────
log::section "Validando métricas no momento do firing"
r5m=$(prom::query "slo:traffic_simulator_availability:error_ratio_rate5m")
r1h=$(prom::query "slo:traffic_simulator_availability:error_ratio_rate1h")
log::info "  rate5m = ${r5m}  (threshold fast = ${FAST_THRESHOLD})"
log::info "  rate1h = ${r1h}  (threshold fast = ${FAST_THRESHOLD})"

if python3 -c "import sys; sys.exit(0 if float('${r5m}') > ${FAST_THRESHOLD} and float('${r1h}') > ${FAST_THRESHOLD} else 1)"; then
  log::ok "  métricas confirmam burn rate acima do threshold"
else
  log::fail "  alerta firing mas métricas abaixo do threshold — desenho do alerta inconsistente"
  exit 3
fi

# ── Desliga fault e aguarda recuperação ─────────────────────────────────
if (( SKIP_RECOVERY == 1 )); then
  log::warn "  --skip-recovery: pulando fase de recuperação"
  log::ok "Chaos test (sem recovery) concluído com sucesso em ${t_firing}s."
  exit 0
fi

log::section "Desativando fault e aguardando recuperação"
app::stop_load
app::fault_clear_all
sleep 5

t0=$(date +%s)
if ! prom::wait_for_alert "${ALERT_NAME}" inactive "${TIMEOUT_RECOVERY}" 15 availability; then
  log::fail "  alerta não voltou pra inactive em ${TIMEOUT_RECOVERY}s"
  log::info "  estado: $(prom::alert_state "${ALERT_NAME}" availability)"
  exit 4
fi
t_recovery=$(( $(date +%s) - t0 ))
log::ok "  ${ALERT_NAME} voltou a inactive após ${t_recovery}s"

# ── Resumo ──────────────────────────────────────────────────────────────
log::section "Resultado"
log::ok "Chaos test PASS"
log::info "  fault rate                 = ${FAULT_RATE}%"
log::info "  tempo até firing           = ${t_firing}s"
log::info "  tempo até recovery         = ${t_recovery}s"
log::info "  erro observado pré-firing  = ${observed}"
log::info "  rate5m no firing           = ${r5m}"
log::info "  rate1h no firing           = ${r1h}"
exit 0
