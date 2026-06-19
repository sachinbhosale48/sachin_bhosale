#!/usr/bin/env bash
set -uo pipefail

LOG_FILE="/var/log/connectivity-check.log"
LOCK_FILE="/tmp/connectivity-check.lock"
DRY_RUN=0
CRITICAL_ONLY=0

PASSED=0
FAILED=0
SKIPPED=0
CRITICAL_FAILED=0

usage() {
  cat <<'EOF'
Usage: connectivity-check.sh [--dry-run] [--critical-only]

Options:
  --dry-run        Print checks that would run, but do not execute them.
  --critical-only  Run only critical checks.
  -h, --help       Show this help message.
EOF
}

log_msg() {
  local level="$1"
  local message="$2"
  local ts=""

  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s %s\n' "$ts" "$level" "$message" | tee -a "$LOG_FILE"
}

ensure_log_file() {
  local log_dir=""

  log_dir="$(dirname "$LOG_FILE")"

  if ! sudo mkdir -p "$log_dir"; then
    printf '[FAIL] Unable to create log directory with sudo: %s\n' "$log_dir"
    exit 1
  fi

  if ! sudo touch "$LOG_FILE"; then
    printf '[FAIL] Unable to create log file with sudo: %s\n' "$LOG_FILE"
    exit 1
  fi

  if ! sudo chown "$USER":"$USER" "$LOG_FILE"; then
    printf '[FAIL] Unable to set log file ownership for %s\n' "$LOG_FILE"
    exit 1
  fi
}

acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    printf '[FAIL] Another instance is already running (lock: %s)\n' "$LOCK_FILE"
    exit 1
  fi
}

run_check() {
  local name="$1"
  local critical="$2"
  local command_str="$3"

  if [[ "$CRITICAL_ONLY" -eq 1 && "$critical" -eq 0 ]]; then
    SKIPPED=$((SKIPPED + 1))
    log_msg "[SKIP]" "$name (non-critical skipped due to --critical-only)"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    SKIPPED=$((SKIPPED + 1))
    log_msg "[SKIP]" "$name | dry-run | command: $command_str"
    return
  fi

  if bash -c "$command_str" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1))
    log_msg "[PASS]" "$name"
  else
    FAILED=$((FAILED + 1))
    log_msg "[FAIL]" "$name"
    if [[ "$critical" -eq 1 ]]; then
      CRITICAL_FAILED=1
    fi
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --critical-only)
        CRITICAL_ONLY=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

print_summary() {
  log_msg "[INFO]" "Summary: passed=$PASSED failed=$FAILED skipped=$SKIPPED"

  if [[ "$CRITICAL_FAILED" -eq 1 ]]; then
    log_msg "[INFO]" "Exit code: 1 (one or more critical checks failed)"
    exit 1
  fi

  log_msg "[INFO]" "Exit code: 0"
  exit 0
}

main() {
  parse_args "$@"
  acquire_lock
  ensure_log_file

  log_msg "[INFO]" "Starting connectivity checks (dry_run=$DRY_RUN critical_only=$CRITICAL_ONLY)"

  # 1) Critical pings
  run_check "Ping gateway (10.0.0.1)" 1 "timeout 5 ping -c 3 -W 5 10.0.0.1"
  run_check "Ping self (10.0.0.4)" 1 "timeout 5 ping -c 3 -W 5 10.0.0.4"
  run_check "Ping internet (8.8.8.8)" 1 "timeout 5 ping -c 3 -W 5 8.8.8.8"

  # 2) Non-critical pings
  run_check "Ping app server (10.0.1.10)" 0 "timeout 5 ping -c 3 -W 5 10.0.1.10"
  run_check "Ping DB server (10.0.2.10)" 0 "timeout 5 ping -c 3 -W 5 10.0.2.10"

  # 3) Non-critical port checks
  run_check "Port check PostgreSQL (10.0.2.10:5432)" 0 "timeout 5 nc -zv -w 5 10.0.2.10 5432"
  run_check "Port check app health (10.0.1.10:8080)" 0 "timeout 5 nc -zv -w 5 10.0.1.10 8080"

  # 4) Critical DNS resolution with 5-second timeout
  run_check "DNS lookup (google.com)" 1 "timeout 5 nslookup google.com"

  # 5) Critical default route check
  run_check "Default route exists" 1 "ip route show | grep -q '^default'"

  # 6) Non-critical qdisc validation for artificial latency on eth0
  run_check "tc qdisc latency check on eth0" 0 "if tc qdisc show dev eth0 | grep -Eq 'netem.*delay'; then exit 1; else exit 0; fi"

  print_summary
}

main "$@"
