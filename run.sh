#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"

DEBUG_LOGGING=0
USE_GDB=0
DRY_RUN=0
BINARY_OVERRIDE="${SAW2_BINARY:-}"
GAME_ROOT="${SAW2_GAME_ROOT:-$ROOT_DIR/game}"
LOG_FILE="${SAW2_LOG_FILE:-}"
declare -a RUNTIME_EXTRA=()

usage() {
  cat <<'EOF'
Usage: ./run.sh [options] [-- ReXGlue options]

  --debug             Enable ReXGlue debug logging
  --gdb               Launch Saw II under GDB
  --binary PATH       Use this Saw II executable
  --game-root PATH    Use this legally extracted Saw II game directory
  --log-file PATH     Runtime log (default: timestamped under logs/)
  --dry-run           Resolve and print the command without launching
  -h, --help          Show this help

Environment equivalents: SAW2_BINARY, SAW2_GAME_ROOT, SAW2_LOG_FILE.
SAW2_CAPTURE_FIRST_FRAME controls the optional guest-frame PPM path.
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
    --dry-run) DRY_RUN=1 ;;
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

[[ "$SAW2_HOST_ARCH" != "unsupported" ]] ||
  saw2_die "unsupported host architecture: $(uname -m)"

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
    "$ROOT_DIR/out/stage/linux-$SAW2_HOST_ARCH-release/saw2" \
    "$ROOT_DIR/out/build/linux-$SAW2_HOST_ARCH-relwithdebinfo/saw2" \
    "$ROOT_DIR/out/build/linux-$SAW2_HOST_ARCH-debug/saw2" \
    "$ROOT_DIR/out/build/linux-$SAW2_HOST_ARCH-release/saw2"; do
    if [[ -x "$candidate" ]]; then
      resolve_file "$candidate"
      return 0
    fi
  done
  saw2_die "no Saw II executable found; run ./build.sh first"
}

[[ -d "$GAME_ROOT" ]] || saw2_die "game data root does not exist: $GAME_ROOT"
GAME_ROOT="$(cd -- "$GAME_ROOT" && pwd -P)"
readonly GAME_ROOT
XEX_PATH="$GAME_ROOT/Default.xex"
[[ -f "$XEX_PATH" ]] ||
  saw2_die "missing exact case-sensitive game file: $XEX_PATH"
saw2_require_command sha256sum
xex_sha="$(sha256sum "$XEX_PATH" | awk '{print $1}')"
[[ "$xex_sha" == "$SAW2_EXPECTED_XEX_SHA256" ]] ||
  saw2_die "XEX differs from the statically generated Saw II image ($xex_sha)"

[[ -d "$GAME_ROOT/SAW2GAME/CookedXenon" ]] ||
  saw2_die "incomplete game root: missing SAW2GAME/CookedXenon/"
for asset in \
  "$GAME_ROOT/SAW2GAME/CookedXenon/Core.xxx" \
  "$GAME_ROOT/SAW2GAME/CookedXenon/Engine.xxx"; do
  [[ -f "$asset" ]] || saw2_warn "expected boot asset is missing: ${asset#$GAME_ROOT/}"
done

BINARY_PATH="$(find_binary)"
readonly BINARY_PATH
BINARY_DIR="$(dirname -- "$BINARY_PATH")"
readonly BINARY_DIR
case "$BINARY_DIR" in
  *linux-*-debug)
    GPU_PLUGIN_NAME="librexgpu-xenosd.so"
    ;;
  *linux-*-relwithdebinfo)
    GPU_PLUGIN_NAME="librexgpu-xenosrd.so"
    ;;
  *)
    GPU_PLUGIN_NAME="librexgpu-xenos.so"
    ;;
esac
PLUGIN_PATH="$BINARY_DIR/$GPU_PLUGIN_NAME"
[[ -f "$PLUGIN_PATH" ]] ||
  saw2_die "Xenos plugin is not colocated with the executable: $PLUGIN_PATH"

declare -a LIBRARY_DIRS=("$BINARY_DIR")
if [[ ! -f "$BINARY_DIR/librexruntime.so" ]]; then
  runtime_prefix=""
  cache_file="$BINARY_DIR/CMakeCache.txt"
  if [[ -f "$cache_file" ]]; then
    rexglue_config_dir="$(sed -n 's/^rexglue_DIR:[^=]*=//p' "$cache_file" | head -n 1)"
    [[ -f "$rexglue_config_dir/rexglueConfig.cmake" ]] ||
      saw2_die "build cache has no usable rexglue_DIR: $cache_file"
    cache_sdk_version="$(saw2_package_version "$rexglue_config_dir")"
    [[ "$cache_sdk_version" == "$SAW2_EXPECTED_REXGLUE_VERSION" ]] ||
      saw2_die "build/runtime SDK mismatch: cache uses '$cache_sdk_version'"
    runtime_prefix="$(cd -- "$rexglue_config_dir/../../.." && pwd -P)"
  else
    saw2_verify_sdk
    runtime_prefix="$SAW2_SDK_PREFIX"
  fi
  [[ -d "$runtime_prefix/lib" ]] && LIBRARY_DIRS+=("$runtime_prefix/lib")
  [[ -d "$runtime_prefix/lib64" ]] && LIBRARY_DIRS+=("$runtime_prefix/lib64")
fi
RUNTIME_LIBRARY_PATH="$(IFS=:; printf '%s' "${LIBRARY_DIRS[*]}")"
[[ -z "${LD_LIBRARY_PATH:-}" ]] ||
  RUNTIME_LIBRARY_PATH="$RUNTIME_LIBRARY_PATH:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$RUNTIME_LIBRARY_PATH"

if [[ ! -v SAW2_CAPTURE_FIRST_FRAME ]]; then
  export SAW2_CAPTURE_FIRST_FRAME="$ROOT_DIR/logs/first-visible-guest-frame.ppm"
else
  export SAW2_CAPTURE_FIRST_FRAME
fi

if command -v ldd >/dev/null 2>&1 && ldd "$BINARY_PATH" | grep -q 'not found'; then
  ldd "$BINARY_PATH" >&2 || true
  saw2_die "the Saw II executable has unresolved shared libraries"
fi

if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="$ROOT_DIR/logs/saw2-$(date +%Y%m%d-%H%M%S)-$$.log"
elif [[ "$LOG_FILE" != /* ]]; then
  LOG_FILE="$ROOT_DIR/$LOG_FILE"
fi
LOG_DIR="$(dirname -- "$LOG_FILE")"
LATEST_LOG="$ROOT_DIR/logs/latest.log"

declare -a RUNTIME_ARGS=(
  "--game_data_root=$GAME_ROOT"
  "--gpu_plugin=xenos"
  "--input_backend=sdl"
  "--resolution=720p"
  "--log_file=$LOG_FILE"
)
if ((DEBUG_LOGGING)); then
  RUNTIME_ARGS+=("--log_level=debug")
fi
RUNTIME_ARGS+=("${RUNTIME_EXTRA[@]}")

declare -a LAUNCH_COMMAND=("$BINARY_PATH" "${RUNTIME_ARGS[@]}")
if ((USE_GDB)); then
  saw2_require_command gdb
  LAUNCH_COMMAND=(gdb --args "${LAUNCH_COMMAND[@]}")
fi

saw2_info "executable: $BINARY_PATH"
saw2_info "game root: $GAME_ROOT"
saw2_info "XEX: Default.xex"
saw2_info "GPU plugin: $PLUGIN_PATH"
saw2_info "runtime log: $LOG_FILE"
saw2_info "first visible frame capture: ${SAW2_CAPTURE_FIRST_FRAME:-disabled}"
saw2_info "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
saw2_print_command "${LAUNCH_COMMAND[@]}"

if ((DRY_RUN)); then
  saw2_info "dry run complete; nothing launched"
  exit 0
fi

mkdir -p -- "$LOG_DIR" "$ROOT_DIR/logs"
: >"$LOG_FILE"
[[ "$LOG_FILE" == "$LATEST_LOG" ]] || ln -sfn "$LOG_FILE" "$LATEST_LOG"
cd -- "$BINARY_DIR"
exec "${LAUNCH_COMMAND[@]}"
