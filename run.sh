#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"

DEBUG_LOGGING=0
USE_GDB=0
BINARY_OVERRIDE="${SAW2_BINARY:-}"
GAME_ROOT="${SAW2_GAME_ROOT:-$ROOT_DIR/game}"
LOG_FILE="${SAW2_LOG_FILE:-}"
RESOLUTION_REQUEST="${SAW2_RESOLUTION:-auto}"
declare -a RUNTIME_EXTRA=()

usage() {
  cat <<'EOF'
Usage: ./run.sh [options] [-- ReXGlue options]

  --debug           Enable ReXGlue debug logging
  --gdb             Launch under GDB
  --binary PATH     Override Saw II executable
  --game-root PATH  Override game directory
  --log-file PATH   Override runtime log
  --resolution MODE auto or WIDTHxHEIGHT (default: auto)
  -h, --help        Show this help
EOF
}

require_value() {
  [[ -n "${2:-}" ]] || saw2_die "$1 requires a value"
}

while (($#)); do
  case "$1" in
    --debug) DEBUG_LOGGING=1 ;;
    --gdb) USE_GDB=1 ;;
    --binary)
      require_value "$1" "${2:-}"
      BINARY_OVERRIDE="$2"
      shift
      ;;
    --game-root)
      require_value "$1" "${2:-}"
      GAME_ROOT="$2"
      shift
      ;;
    --log-file)
      require_value "$1" "${2:-}"
      LOG_FILE="$2"
      shift
      ;;
    --resolution)
      require_value "$1" "${2:-}"
      RESOLUTION_REQUEST="$2"
      shift
      ;;
    --ue3-msaa-fix)
      require_value "$1" "${2:-}"
      SAW2_UE3_MSAA_FIX="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    --)
      shift
      RUNTIME_EXTRA=("$@")
      break
      ;;
    *) saw2_die "unknown option '$1' (put ReXGlue options after --)" ;;
  esac
  shift
done

resolve_file() {
  [[ -f "$1" ]] || return 1
  (cd -- "$(dirname -- "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$1")")
}

find_binary() {
  local candidate
  if [[ -n "$BINARY_OVERRIDE" ]]; then
    candidate="$(resolve_file "$BINARY_OVERRIDE" || true)"
    [[ -n "$candidate" && -x "$candidate" ]] ||
      saw2_die "Saw II executable is not runnable: $BINARY_OVERRIDE"
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in \
    "$ROOT_DIR/out/stage/current/saw2" \
    "$ROOT_DIR/out/stage/linux-$SAW2_HOST_ARCH-relwithdebinfo/saw2" \
    "$ROOT_DIR/out/stage/linux-$SAW2_HOST_ARCH-debug/saw2" \
    "$ROOT_DIR/out/stage/linux-$SAW2_HOST_ARCH-release/saw2"; do
    if [[ -x "$candidate" ]]; then
      resolve_file "$candidate"
      return 0
    fi
  done

  saw2_die "no staged Saw II executable found; run ./build.sh first"
}

[[ -d "$GAME_ROOT" ]] || saw2_die "game data root does not exist: $GAME_ROOT"
GAME_ROOT="$(cd -- "$GAME_ROOT" && pwd -P)"
readonly GAME_ROOT

XEX_PATH="$GAME_ROOT/Default.xex"
[[ -f "$XEX_PATH" ]] || saw2_die "missing $XEX_PATH"

BINARY_PATH="$(find_binary)"
readonly BINARY_PATH
BINARY_DIR="$(dirname -- "$BINARY_PATH")"
readonly BINARY_DIR

case "$BINARY_DIR" in
  *linux-*-debug)
    GPU_PLUGIN_NAME="librexgpu-xenosd.so"
    RUNTIME_NAME="librexruntimed.so"
    ;;
  *linux-*-relwithdebinfo)
    GPU_PLUGIN_NAME="librexgpu-xenosrd.so"
    RUNTIME_NAME="librexruntimerd.so"
    ;;
  *)
    GPU_PLUGIN_NAME="librexgpu-xenos.so"
    RUNTIME_NAME="librexruntime.so"
    ;;
esac

PLUGIN_PATH="$BINARY_DIR/$GPU_PLUGIN_NAME"
RUNTIME_PATH="$BINARY_DIR/$RUNTIME_NAME"

[[ -f "$PLUGIN_PATH" ]] ||
  saw2_die "Xenos plugin missing beside executable: $PLUGIN_PATH"
[[ -f "$RUNTIME_PATH" ]] ||
  saw2_die "local ReXGlue runtime missing beside executable: $RUNTIME_PATH"

export LD_LIBRARY_PATH="$BINARY_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"


valid_resolution() {
  [[ "$1" =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]]
}

detect_screen_resolution() {
  local mode=""

  # KDE Plasma / KWin Wayland.
  if command -v kscreen-doctor >/dev/null 2>&1; then
    mode="$(kscreen-doctor -o 2>/dev/null |
      grep -m1 -oE 'Geometry: [^ ]+ [0-9]+x[0-9]+' |
      grep -oE '[0-9]+x[0-9]+' || true)"
    valid_resolution "$mode" && { printf '%s\n' "$mode"; return 0; }
  fi

  # wlroots compositors.
  if command -v wlr-randr >/dev/null 2>&1; then
    mode="$(wlr-randr 2>/dev/null |
      grep -m1 -E 'current' |
      grep -oE '[0-9]+x[0-9]+' |
      head -n1 || true)"
    valid_resolution "$mode" && { printf '%s\n' "$mode"; return 0; }
  fi

  # Hyprland.
  if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    mode="$(hyprctl -j monitors 2>/dev/null |
      jq -r 'map(select(.focused == true))[0] // .[0] | "\(.width)x\(.height)"' 2>/dev/null || true)"
    valid_resolution "$mode" && { printf '%s\n' "$mode"; return 0; }
  fi

  # X11 / XWayland fallback.
  if command -v xrandr >/dev/null 2>&1; then
    mode="$(xrandr --current 2>/dev/null |
      sed -nE 's/.* connected primary ([0-9]+x[0-9]+)\+.*/\1/p' |
      head -n1 || true)"
    if ! valid_resolution "$mode"; then
      mode="$(xrandr --current 2>/dev/null |
        sed -nE 's/.* connected( primary)? ([0-9]+x[0-9]+)\+.*/\2/p' |
        head -n1 || true)"
    fi
    valid_resolution "$mode" && { printf '%s\n' "$mode"; return 0; }
  fi

  return 1
}

if [[ "${RESOLUTION_REQUEST,,}" == "auto" ]]; then
  ACTIVE_RESOLUTION="$(detect_screen_resolution || true)"
  if ! valid_resolution "$ACTIVE_RESOLUTION"; then
    ACTIVE_RESOLUTION="1280x800"
    saw2_warn "screen mode detection failed; using 16:10 fallback $ACTIVE_RESOLUTION"
  fi
else
  ACTIVE_RESOLUTION="$RESOLUTION_REQUEST"
fi

if [[ "$ACTIVE_RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]]; then
  SCREEN_W="${BASH_REMATCH[1]}"
  SCREEN_H="${BASH_REMATCH[2]}"
  if (( SCREEN_W * 10 == SCREEN_H * 16 )); then
    ACTIVE_ASPECT="16:10"
  elif (( SCREEN_W * 9 == SCREEN_H * 16 )); then
    ACTIVE_ASPECT="16:9"
  elif (( SCREEN_W * 3 == SCREEN_H * 4 )); then
    ACTIVE_ASPECT="4:3"
  else
    ACTIVE_ASPECT="$(awk -v w="$SCREEN_W" -v h="$SCREEN_H" 'BEGIN { printf "%.3f:1", w/h }')"
  fi
else
  ACTIVE_ASPECT="preset"
fi

if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="$ROOT_DIR/logs/saw2-$(date +%Y%m%d-%H%M%S)-$$.log"
elif [[ "$LOG_FILE" != /* ]]; then
  LOG_FILE="$ROOT_DIR/$LOG_FILE"
fi

mkdir -p "$(dirname -- "$LOG_FILE")" "$ROOT_DIR/logs"

declare -a RUNTIME_ARGS=(
  "--game_data_root=$GAME_ROOT"
  "--gpu_plugin=xenos"
  "--input_backend=sdl"
  "--resolution=$ACTIVE_RESOLUTION"
  "--log_file=$LOG_FILE"
)

if ((DEBUG_LOGGING)); then
  RUNTIME_ARGS+=("--log_level=debug")
fi

RUNTIME_ARGS+=("${RUNTIME_EXTRA[@]}")

declare -a LAUNCH_COMMAND=("$BINARY_PATH" "${RUNTIME_ARGS[@]}")
if ((USE_GDB)); then
  command -v gdb >/dev/null 2>&1 || saw2_die "gdb is not installed"
  LAUNCH_COMMAND=(gdb --args "${LAUNCH_COMMAND[@]}")
fi

saw2_info "executable: $BINARY_PATH"
saw2_info "runtime: $RUNTIME_PATH"
saw2_info "GPU plugin: $PLUGIN_PATH"
saw2_info "game root: $GAME_ROOT"
saw2_info "runtime log: $LOG_FILE"
saw2_info "display: $ACTIVE_RESOLUTION ($ACTIVE_ASPECT)"
saw2_print_command "${LAUNCH_COMMAND[@]}"

cd -- "$BINARY_DIR"
exec "${LAUNCH_COMMAND[@]}"
