#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/common.sh"

IGNORE_STAMP=false
LOG_LEVEL=info
for arg in "$@"; do
  case "$arg" in
    --ignore-stamp|force)
      IGNORE_STAMP=true
      ;;
    --trace)
      LOG_LEVEL=trace
      ;;
    normal|linux-*)
      # Accepted for compatibility with the old script interface. Codegen is
      # now independent of a CMake preset.
      ;;
    *)
      saw2_die "usage: ./scripts/codegen.sh [--ignore-stamp] [--trace]"
      ;;
  esac
done

saw2_verify_xex
saw2_verify_sdk
saw2_prepare_logs
CODEGEN_LOG="$SAW2_ROOT/logs/codegen-$(saw2_timestamp).log"
printf 'Codegen log: %s\n' "$CODEGEN_LOG"

ARGS=(--log-level "$LOG_LEVEL" --log-file "$CODEGEN_LOG" codegen)
if [[ "$IGNORE_STAMP" == true ]]; then
  ARGS+=(--ignore-stamp)
fi
ARGS+=("$SAW2_MANIFEST")

cd "$SAW2_ROOT"
"$SAW2_REXGLUE_CLI" "${ARGS[@]}"
