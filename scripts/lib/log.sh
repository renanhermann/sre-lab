# shellcheck shell=bash
#
# Logging estruturado para os scripts de chaos test.
# Saída em formato `HH:MM:SS [LEVEL] mensagem`, com cor pra terminal e
# desligável via NO_COLOR=1 pra CI/logs persistidos.

if [[ "${NO_COLOR:-0}" == "1" || ! -t 1 ]]; then
  _C_RESET=""
  _C_DIM=""
  _C_BLUE=""
  _C_YELLOW=""
  _C_RED=""
  _C_GREEN=""
  _C_BOLD=""
else
  _C_RESET=$'\033[0m'
  _C_DIM=$'\033[2m'
  _C_BLUE=$'\033[34m'
  _C_YELLOW=$'\033[33m'
  _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'
  _C_BOLD=$'\033[1m'
fi

_log() {
  local level="$1"; shift
  local color="$1"; shift
  printf '%s%s%s [%s%s%s] %s\n' \
    "${_C_DIM}" "$(date +%H:%M:%S)" "${_C_RESET}" \
    "${color}" "${level}" "${_C_RESET}" \
    "$*"
}

log::info()  { _log "INFO " "${_C_BLUE}"   "$*"; }
log::warn()  { _log "WARN " "${_C_YELLOW}" "$*" >&2; }
log::error() { _log "ERROR" "${_C_RED}"    "$*" >&2; }
log::ok()    { _log "PASS " "${_C_GREEN}"  "$*"; }
log::fail()  { _log "FAIL " "${_C_RED}"    "$*" >&2; }

# Separador visual entre fases do teste
log::section() {
  printf '\n%s── %s ──%s\n' "${_C_BOLD}" "$*" "${_C_RESET}"
}
