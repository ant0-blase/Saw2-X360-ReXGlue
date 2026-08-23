#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TIMEOUT_SECONDS=30
DRY_RUN=0
declare -a RUN_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./test-boot.sh [options] [-- run.sh options]

  --timeout SECONDS   Observation window (default: 30)
  --dry-run           Resolve the launch without starting Saw II
  -h, --help          Show this help

Put run.sh options such as --debug or --game-root after --.
EOF
}

die() {
  printf '[test-boot] ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --timeout)
      [[ -n "${2:-}" ]] || die "--timeout requires a value"
      TIMEOUT_SECONDS="$2"
      shift
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    --)
      shift
      RUN_ARGS=("$@")
      break
      ;;
    *) die "unknown option '$1' (put run.sh options after --)" ;;
  esac
  shift
done

[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*([.][0-9]+)?$ ]] ||
  die "--timeout must be positive"
command -v timeout >/dev/null 2>&1 || die "GNU timeout is required"

if ((DRY_RUN)); then
  printf '[test-boot] timeout: %ss\n' "$TIMEOUT_SECONDS"
  exec "$ROOT_DIR/run.sh" --dry-run "${RUN_ARGS[@]}"
fi

mkdir -p -- "$ROOT_DIR/logs"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUNTIME_LOG="$ROOT_DIR/logs/test-boot-$RUN_ID.runtime.log"
CONSOLE_LOG="$ROOT_DIR/logs/test-boot-$RUN_ID.console.log"
COMBINED_LOG="$ROOT_DIR/logs/test-boot-$RUN_ID.log"

printf '[test-boot] running Saw II for at most %ss\n' "$TIMEOUT_SECONDS"
set +e
timeout --foreground --signal=TERM --kill-after=5s "${TIMEOUT_SECONDS}s" \
  "$ROOT_DIR/run.sh" --log-file "$RUNTIME_LOG" "${RUN_ARGS[@]}" \
  >"$CONSOLE_LOG" 2>&1
STATUS=$?
set -e

{
  printf 'Saw II bounded boot test\n'
  printf 'exit_status=%s\n' "$STATUS"
  printf 'timeout_seconds=%s\n\n' "$TIMEOUT_SECONDS"
  printf '%s\n' '--- console ---'
  sed -n '1,$p' "$CONSOLE_LOG"
  printf '\n%s\n' '--- ReXGlue runtime log ---'
  if [[ -f "$RUNTIME_LOG" ]]; then
    sed -n '1,$p' "$RUNTIME_LOG"
  else
    printf '(runtime log was not created)\n'
  fi
} >"$COMBINED_LOG"
ln -sfn "$COMBINED_LOG" "$ROOT_DIR/logs/test-boot-latest.log"

milestone() {
  local label="$1" pattern="$2"
  if grep -Eiq "$pattern" "$COMBINED_LOG"; then
    printf '[test-boot] %-24s yes\n' "$label"
    return 0
  fi
  printf '[test-boot] %-24s no\n' "$label"
  return 1
}

MISSING_CORE=0
milestone 'XEX loaded' 'Loading XEX image' || MISSING_CORE=1
milestone 'guest entrypoint' 'KernelState: Preparing module launch|Module prepared on thread' || MISSING_CORE=1
milestone 'GPU initialized' 'GPU system initialized' || true
milestone 'guest draw/render target' 'render target|draw usage|graphics pipeline state' || true
milestone 'guest present' 'XELOG_GPU PRESENT:|FIRST PRESENT' || true
milestone 'visible guest frame' 'SAW2 FIRST VISIBLE FRAME: non_black=[1-9][0-9]*/' || true
milestone 'SDL input initialized' 'SDL input driver initialized successfully' || true
milestone 'SDL controller event' 'OnControllerDeviceAdded|controller connected|gamepad (added|connected)' || true

FATAL_PATTERN='Call to invalid or unregistered function|\[FATAL\]|fatal error|segmentation fault|Assertion.*failed'
if grep -Eiq "$FATAL_PATTERN" "$COMBINED_LOG"; then
  grep -Ei "$FATAL_PATTERN" "$COMBINED_LOG" | tail -n 1 >&2
  printf '[test-boot] logs: %s\n' "$COMBINED_LOG" >&2
  die "fatal runtime diagnostic detected"
fi

printf '[test-boot] combined log: %s\n' "$COMBINED_LOG"
printf '[test-boot] runtime log: %s\n' "$RUNTIME_LOG"

if ((MISSING_CORE)); then
  die "core boot milestones were not observed"
fi

case "$STATUS" in
  0) printf '[test-boot] process exited cleanly\n' ;;
  124) printf '[test-boot] observation timeout reached cleanly\n' ;;
  *) die "Saw II exited before timeout with status $STATUS" ;;
esac
