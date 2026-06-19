#!/usr/bin/env bash
set -uo pipefail

LOG_FILE="/var/log/connectivity-check.log"
DRY_RUN="false"
CRITICAL_ONLY="false"
PASSED="0"
FAILED="0"
SKIPPED="0"
CRITICAL_FAILED="0"

usage() {
  cat <<'EOF'
Usage: payment-monitor.sh [--dry-run] [--critical-only] [--help]

Options:
  --dry-run        Print checks that would run without executing them
  --critical-only  Run only critical checks and skip non-critical checks
  --help           Show this help message
EOF
}

ensure_log_file() {
  local log_dir
  log_dir="$(dirname "$LOG_FILE")"

  if ! sudo mkdir -p "$log_dir"; then
    echo "Failed to create log directory: $log_dir" >&2
    exit 1
  fi

  if ! sudo touch "$LOG_FILE"; then
    echo "Failed to create log file: $LOG_FILE" >&2
    exit 1
  fi
}

log_line() {
  local message="$1"
  local timestamp
  local line

  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  line="${timestamp} ${message}"

  echo "$line"
  printf '%s\n' "$line" | sudo tee -a "$LOG_FILE" >/dev/null
}

record_pass() {
  local check_name="$1"
  PASSED="$((PASSED + 1))"
  log_line "[PASS] ${check_name}"
}

record_fail() {
  local check_name="$1"
  local details="$2"
  local is_critical="$3"

  FAILED="$((FAILED + 1))"
  log_line "[FAIL] ${check_name} - ${details}"

  if [[ "$is_critical" == "true" ]]; then
    CRITICAL_FAILED="1"
  fi
}

record_skip() {
  local check_name="$1"
  local details="$2"

  SKIPPED="$((SKIPPED + 1))"
  log_line "[SKIP] ${check_name} - ${details}"
}

run_cmd_check() {
  local check_name="$1"
  local is_critical="$2"
  local command_preview="$3"
  local output
  local status

  shift 3

  if [[ "$CRITICAL_ONLY" == "true" && "$is_critical" == "false" ]]; then
    record_skip "$check_name" "Skipped by --critical-only"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    record_skip "$check_name" "Dry-run: would run '${command_preview}'"
    return
  fi

  output="$("$@" 2>&1)"
  status="$?"

  if [[ "$status" -eq 0 ]]; then
    record_pass "$check_name"
  else
    record_fail "$check_name" "Command failed (exit ${status}): ${output}" "$is_critical"
  fi
}

check_ping() {
  local check_name="$1"
  local is_critical="$2"
  local target="$3"

  run_cmd_check \
    "$check_name" \
    "$is_critical" \
    "timeout 5s ping -c3 -W 5 ${target}" \
    timeout 5s ping -c3 -W 5 "$target"
}

check_port() {
  local check_name="$1"
  local target="$2"
  local port="$3"

  run_cmd_check \
    "$check_name" \
    "false" \
    "timeout 5s nc -zv -w 5 ${target} ${port}" \
    timeout 5s nc -zv -w 5 "$target" "$port"
}

check_dns() {
  run_cmd_check \
    "DNS resolution (nslookup google.com)" \
    "true" \
    "timeout 5s nslookup google.com" \
    timeout 5s nslookup google.com
}

check_default_route() {
  run_cmd_check \
    "Default route exists" \
    "true" \
    "ip route show | grep -q '^default'" \
    bash -c "ip route show | grep -q '^default'"
}

check_tc_qdisc() {
  local check_name="tc qdisc on eth0 has no injected latency"
  local output
  local status

  if [[ "$CRITICAL_ONLY" == "true" ]]; then
    record_skip "$check_name" "Skipped by --critical-only"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    record_skip "$check_name" "Dry-run: would run 'tc qdisc show dev eth0'"
    return
  fi

  output="$(tc qdisc show dev "eth0" 2>&1)"
  status="$?"

  if [[ "$status" -ne 0 ]]; then
    record_fail "$check_name" "Command failed (exit ${status}): ${output}" "false"
    return
  fi

  if echo "$output" | grep -Eiq 'netem.*delay'; then
    record_fail "$check_name" "Artificial latency detected: ${output}" "false"
  else
    record_pass "$check_name"
  fi
}

print_summary() {
  log_line "Summary: passed=${PASSED} failed=${FAILED} skipped=${SKIPPED}"
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN="true"
        ;;
      --critical-only)
        CRITICAL_ONLY="true"
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  ensure_log_file

  log_line "Connectivity validation started (dry_run=${DRY_RUN}, critical_only=${CRITICAL_ONLY})"

  # 1) Critical pings
  check_ping "Ping gateway 10.0.0.1" "true" "10.0.0.1"
  check_ping "Ping self 10.0.0.4" "true" "10.0.0.4"
  check_ping "Ping internet 8.8.8.8" "true" "8.8.8.8"

  # 2) Non-critical server pings (may fail if not provisioned)
  check_ping "Ping app server 10.0.1.10" "false" "10.0.1.10"
  check_ping "Ping DB server 10.0.2.10" "false" "10.0.2.10"

  # 3) Non-critical TCP port checks
  check_port "Port check PostgreSQL 10.0.2.10:5432" "10.0.2.10" "5432"
  check_port "Port check app health 10.0.1.10:8080" "10.0.1.10" "8080"

  # 4) Critical DNS
  check_dns

  # 5) Critical default route check
  check_default_route

  # 6) Non-critical tc qdisc latency injection check
  check_tc_qdisc

  print_summary

  if [[ "$CRITICAL_FAILED" -eq 1 ]]; then
    log_line "Exiting with code 1 due to one or more CRITICAL check failures"
    exit 1
  fi

  log_line "Exiting with code 0"
  exit 0
}

main "$@"
