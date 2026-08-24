#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"

BUILD_KIND="relwithdebinfo"
CLEAN=0
INSTALL_DEPS=0
JOBS="${SAW2_BUILD_JOBS:-}"

readonly SDK_SOURCE="$ROOT_DIR/.deps/rexglue-sdk"
readonly SDK_BINARY_PATCH_HELPER="$ROOT_DIR/scripts/ensure-saw2-binary-patches.py"
readonly SDK_TIMERQUEUE_HELPER="$ROOT_DIR/scripts/ensure-rexglue-timerqueue-blocking-wait.py"
readonly SDK_DISRUPTOR_HELPER="$ROOT_DIR/scripts/ensure-disruptorplus-blocking-wait-fix.py"
readonly SDK_DB16_NOOP_HELPER="$ROOT_DIR/scripts/ensure-rexglue-db16cyc-noop.py"
readonly ROOT_PATCH_CLEANUP="$ROOT_DIR/scripts/cleanup-obsolete-root-patches.sh"

usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

Build configuration:
  --debug           Build Debug
  --relwithdebinfo  Build RelWithDebInfo (default)
  --release         Build Release
  --clean           Fresh Saw II CMake configure + clean-first build
  --install-deps    Install missing host dependencies
  --jobs N          Parallel build jobs
  -h, --help        Show this help

This build always uses:
  .deps/rexglue-sdk

The pinned ReXGlue revision is taken from scripts/common.sh.
ReXGlue compatibility/optimization fixes are applied idempotently by scripts/
and no generated .patch files are required or created in the project root.
EOF
}

require_value() {
  [[ -n "${2:-}" ]] || saw2_die "$1 requires a value"
}

while (($#)); do
  case "$1" in
    --debug) BUILD_KIND="debug" ;;
    --relwithdebinfo) BUILD_KIND="relwithdebinfo" ;;
    --release) BUILD_KIND="release" ;;
    --clean) CLEAN=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --jobs)
      require_value "$1" "${2:-}"
      JOBS="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) saw2_die "unknown option '$1' (try --help)" ;;
  esac
  shift
done

[[ "$SAW2_HOST_ARCH" != "unsupported" ]] ||
  saw2_die "unsupported host architecture: $(uname -m)"

if [[ -n "$JOBS" && ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  saw2_die "--jobs must be a positive integer"
fi

if [[ -z "$JOBS" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
  else
    JOBS=2
  fi
fi

readonly PRESET="linux-$SAW2_HOST_ARCH-$BUILD_KIND"
readonly BUILD_DIR="$ROOT_DIR/out/build/$PRESET"
readonly STAGE_DIR="$ROOT_DIR/out/stage/$PRESET"

version_major() {
  "$1" --version 2>/dev/null | sed -nE '1{s/.*version ([0-9]+).*/\1/p;q;}'
}

select_clang() {
  local candidate major c_command
  CLANG_MAJOR=0
  CLANG_C=""
  CLANG_CXX=""
  for candidate in clang++ clang++-22 clang++-21 clang++-20 clang++-19 clang++-18; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    major="$(version_major "$candidate")"
    [[ "$major" =~ ^[0-9]+$ ]] || continue
    c_command="${candidate/clang++/clang}"
    command -v "$c_command" >/dev/null 2>&1 || continue
    if ((major > CLANG_MAJOR)); then
      CLANG_MAJOR="$major"
      CLANG_C="$(command -v "$c_command")"
      CLANG_CXX="$(command -v "$candidate")"
    fi
  done
}

library_available() {
  local soname="$1"
  if command -v ldconfig >/dev/null 2>&1 &&
     ldconfig -p 2>/dev/null | grep -Fq "$soname"; then
    return 0
  fi
  find /usr/lib /usr/lib64 /lib /lib64 -maxdepth 2 -name "$soname" \
    -print -quit 2>/dev/null | grep -q .
}

declare -a MISSING_REQUIREMENTS=()

check_host_requirements() {
  local command_name
  MISSING_REQUIREMENTS=()

  for command_name in cmake ninja git python3 sha256sum pkg-config; do
    command -v "$command_name" >/dev/null 2>&1 ||
      MISSING_REQUIREMENTS+=("command:$command_name")
  done

  select_clang
  if [[ -z "$CLANG_CXX" ]] || ((CLANG_MAJOR < 18)); then
    MISSING_REQUIREMENTS+=("Clang>=18")
  fi

  for command_name in libvulkan.so.1 libX11.so.6 libX11-xcb.so.1 libxcb.so.1 \
    libwayland-client.so.0; do
    library_available "$command_name" ||
      MISSING_REQUIREMENTS+=("runtime-library:$command_name")
  done
}

install_arch_deps() {
  local -a cmd=()
  if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 || saw2_die "sudo is required"
    cmd+=(sudo)
  fi
  cmd+=(pacman -S --needed --
    base-devel cmake ninja clang lld git python pkgconf curl unzip autoconf
    gtk3 libx11 libxss vulkan-headers vulkan-icd-loader wayland
    wayland-protocols libxkbcommon libdecor alsa-lib libpulse pipewire)
  saw2_run "${cmd[@]}"
}

check_host_requirements
if ((${#MISSING_REQUIREMENTS[@]})); then
  saw2_warn "missing host requirements: ${MISSING_REQUIREMENTS[*]}"
  if ((INSTALL_DEPS)); then
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      source /etc/os-release
    fi
    case " ${ID:-} ${ID_LIKE:-} " in
      *" arch "*) install_arch_deps ;;
      *) saw2_die "automatic --install-deps is currently configured for Arch only" ;;
    esac
    check_host_requirements
  fi
fi

((${#MISSING_REQUIREMENTS[@]} == 0)) ||
  saw2_die "missing requirements: ${MISSING_REQUIREMENTS[*]}"

saw2_info "compiler: $CLANG_CXX (Clang $CLANG_MAJOR)"
saw2_info "CMake: $(cmake --version | sed -n '1p')"
saw2_verify_xex

[[ -f "$ROOT_DIR/CMakeLists.txt" ]] || saw2_die "missing CMakeLists.txt"
[[ -f "$ROOT_DIR/CMakePresets.json" ]] || saw2_die "missing CMakePresets.json"
[[ -f "$SAW2_MANIFEST" ]] || saw2_die "missing saw2_manifest.toml"
[[ -f "$ROOT_DIR/generated/rexglue.cmake" ]] ||
  saw2_die "missing generated/rexglue.cmake scaffold"
[[ -f "$SDK_BINARY_PATCH_HELPER" ]] ||
  saw2_die "missing helper: $SDK_BINARY_PATCH_HELPER"
[[ -f "$SDK_TIMERQUEUE_HELPER" ]] ||
  saw2_die "missing helper: $SDK_TIMERQUEUE_HELPER"
[[ -f "$SDK_DISRUPTOR_HELPER" ]] ||
  saw2_die "missing helper: $SDK_DISRUPTOR_HELPER"
[[ -f "$SDK_DB16_NOOP_HELPER" ]] ||
  saw2_die "missing helper: $SDK_DB16_NOOP_HELPER"
[[ -f "$ROOT_PATCH_CLEANUP" ]] ||
  saw2_die "missing helper: $ROOT_PATCH_CLEANUP"

saw2_info "cleaning obsolete generated .patch files from project root"
saw2_run "$ROOT_PATCH_CLEANUP"

mkdir -p "$ROOT_DIR/.deps"

if [[ ! -d "$SDK_SOURCE/.git" ]]; then
  saw2_info "cloning pinned ReXGlue SDK into .deps/rexglue-sdk"
  saw2_run git clone --recursive "$SAW2_REXGLUE_REPOSITORY" "$SDK_SOURCE"
fi

sdk_head="$(git -C "$SDK_SOURCE" rev-parse HEAD 2>/dev/null || true)"
if [[ "$sdk_head" != "$SAW2_REXGLUE_COMMIT" && "$sdk_head" != "$SAW2_REXGLUE_COMMIT"* ]]; then
  saw2_info "checking out pinned ReXGlue revision: $SAW2_REXGLUE_COMMIT"
  saw2_run git -C "$SDK_SOURCE" fetch --all --tags
  saw2_run git -C "$SDK_SOURCE" checkout --detach "$SAW2_REXGLUE_COMMIT"
fi

saw2_run git -C "$SDK_SOURCE" submodule update --init --recursive

saw2_info "ensuring ReXGlue pre-codegen binary patch support"
saw2_run python3 "$SDK_BINARY_PATCH_HELPER" "$SDK_SOURCE"

saw2_info "ensuring ReXGlue TimerQueue blocking wait"
saw2_run python3 "$SDK_TIMERQUEUE_HELPER" "$SDK_SOURCE"

saw2_info "fixing vendored Disruptor++ blocking wait"
saw2_run python3 "$SDK_DISRUPTOR_HELPER" "$SDK_SOURCE"

saw2_info "restoring ReXGlue db16cyc codegen no-op"
saw2_run python3 "$SDK_DB16_NOOP_HELPER" "$SDK_SOURCE"

readonly SDK_PREFIX="$SDK_SOURCE/out/install/$SAW2_SDK_PRESET"

case "$BUILD_KIND" in
  debug) SDK_CMAKE_CONFIG="Debug" ;;
  relwithdebinfo) SDK_CMAKE_CONFIG="RelWithDebInfo" ;;
  release) SDK_CMAKE_CONFIG="Release" ;;
  *) saw2_die "unsupported SDK build kind: $BUILD_KIND" ;;
esac
readonly SDK_CMAKE_CONFIG

saw2_info "building local ReXGlue SDK: $SDK_SOURCE"
saw2_info "ReXGlue SDK configuration: $SDK_CMAKE_CONFIG"
saw2_run cmake --preset "$SAW2_SDK_PRESET" -S "$SDK_SOURCE" \
  -DCMAKE_C_COMPILER:FILEPATH="$CLANG_C" \
  -DCMAKE_CXX_COMPILER:FILEPATH="$CLANG_CXX"
saw2_run cmake --build "$SDK_SOURCE/out/build/$SAW2_SDK_PRESET" \
  --config "$SDK_CMAKE_CONFIG" \
  --target install --parallel "$JOBS"

readonly REXGLUE_CLI="$SDK_PREFIX/bin/rexglue"
[[ -x "$REXGLUE_CLI" ]] ||
  saw2_die "local ReXGlue CLI was not installed: $REXGLUE_CLI"

saw2_info "ReXGlue CLI: $REXGLUE_CLI ($("$REXGLUE_CLI" --version | sed -n '1p'))"
saw2_info "ReXGlue prefix: $SDK_PREFIX"

SAW2_FPS_MODE="${SAW2_FPS:-60}"
case "${SAW2_FPS_MODE,,}" in
  unlimited|uncapped|0)
    SAW2_FPS_BYTE="00"
    SAW2_FPS_LABEL="unlimited"
    ;;
  60)
    SAW2_FPS_BYTE="01"
    SAW2_FPS_LABEL="60 FPS"
    ;;
  30)
    SAW2_FPS_BYTE="02"
    SAW2_FPS_LABEL="30 FPS"
    ;;
  *)
    saw2_die "SAW2_FPS must be 30, 60, or unlimited"
    ;;
esac

# Saw II: Flesh & Blood patches by Sowa_95:
#   0x825243FC = 0x60000000   Unlock framerate limiter (PPC NOP)
#   0x82A2A3C7 = 00/01/02     unlimited / 60 FPS / 30 FPS
#   0x8296CB74 = 0x38A00010   16x anisotropic filtering
SAW2_BINARY_PATCHES="825243FC:60000000,82A2A3C7:$SAW2_FPS_BYTE"
case "${SAW2_AF16X:-1}" in
  1|true|TRUE|yes|YES|on|ON)
    SAW2_BINARY_PATCHES="$SAW2_BINARY_PATCHES,8296CB74:38A00010"
    SAW2_AF_LABEL="16x"
    ;;
  0|false|FALSE|no|NO|off|OFF)
    SAW2_AF_LABEL="default"
    ;;
  *)
    saw2_die "SAW2_AF16X must be 0/1, false/true, off/on"
    ;;
esac

# Must remain exported through the CMake-generated codegen step too.
export REXGLUE_BINARY_PATCHES="$SAW2_BINARY_PATCHES"
saw2_info "Saw II patches: FPS=$SAW2_FPS_LABEL, anisotropic=$SAW2_AF_LABEL"
saw2_info "pre-codegen bytes: $REXGLUE_BINARY_PATCHES"

saw2_prepare_logs
BUILD_LOG="$ROOT_DIR/logs/build-$(saw2_timestamp)-$$.log"
CODEGEN_LOG="$ROOT_DIR/logs/codegen-$(saw2_timestamp)-$$.log"
saw2_info "build log: $BUILD_LOG"
exec > >(tee "$BUILD_LOG") 2>&1

saw2_info "forcing codegen regeneration (db16cyc no-op / local SDK changes)"
saw2_run "$REXGLUE_CLI" --log-level info --log-file "$CODEGEN_LOG" \
  codegen --ignore-stamp "$SAW2_MANIFEST"

declare -a configure_extra=(
  -DCMAKE_C_COMPILER:FILEPATH="$CLANG_C"
  -DCMAKE_CXX_COMPILER:FILEPATH="$CLANG_CXX"
  -DCMAKE_PREFIX_PATH:PATH="$SDK_PREFIX"
  -Drexglue_DIR:PATH="$(saw2_config_from_prefix "$SDK_PREFIX")"
)

if ((CLEAN)); then
  configure_extra+=(--fresh)
fi

saw2_cmake_configure "$PRESET" "${configure_extra[@]}"

declare -a build_command=(cmake --build "$BUILD_DIR" --parallel "$JOBS")
if ((CLEAN)); then
  build_command+=(--clean-first)
fi
saw2_run "${build_command[@]}"

BINARY_PATH="$BUILD_DIR/saw2"

find_sdk_library() {
  local library_name="$1"
  local candidate=""
  for candidate in \
    "$SDK_PREFIX/lib/$library_name" \
    "$SDK_PREFIX/lib64/$library_name"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  find "$SDK_PREFIX" -type f -name "$library_name" -print -quit 2>/dev/null
}

case "$BUILD_KIND" in
  debug)
    GPU_PLUGIN_NAME="librexgpu-xenosd.so"
    RUNTIME_NAME="librexruntimed.so"
    ;;
  relwithdebinfo)
    GPU_PLUGIN_NAME="librexgpu-xenosrd.so"
    RUNTIME_NAME="librexruntimerd.so"
    ;;
  release)
    GPU_PLUGIN_NAME="librexgpu-xenos.so"
    RUNTIME_NAME="librexruntime.so"
    ;;
  *) saw2_die "unsupported build kind: $BUILD_KIND" ;;
esac

RUNTIME_PATH="$(find_sdk_library "$RUNTIME_NAME" || true)"
PLUGIN_PATH="$(find_sdk_library "$GPU_PLUGIN_NAME" || true)"

[[ -x "$BINARY_PATH" ]] || saw2_die "build produced no executable: $BINARY_PATH"
[[ -n "$RUNTIME_PATH" && -f "$RUNTIME_PATH" ]] ||
  saw2_die "local SDK has no $RUNTIME_NAME"
[[ -n "$PLUGIN_PATH" && -f "$PLUGIN_PATH" ]] ||
  saw2_die "local SDK has no $GPU_PLUGIN_NAME"

mkdir -p -- "$STAGE_DIR"
saw2_run install -m 0755 "$BINARY_PATH" "$STAGE_DIR/saw2"
saw2_run install -m 0755 "$PLUGIN_PATH" "$STAGE_DIR/$GPU_PLUGIN_NAME"
saw2_run install -m 0755 "$RUNTIME_PATH" "$STAGE_DIR/$RUNTIME_NAME"

for stale_runtime in librexruntime.so librexruntimed.so librexruntimerd.so; do
  [[ "$stale_runtime" == "$RUNTIME_NAME" ]] && continue
  rm -f "$STAGE_DIR/$stale_runtime"
done

if [[ -L "$ROOT_DIR/out/stage/current" || ! -e "$ROOT_DIR/out/stage/current" ]]; then
  saw2_run ln -sfn "$PRESET" "$ROOT_DIR/out/stage/current"
fi

printf '\n'
saw2_info "build successful"
saw2_info "local SDK: $SDK_SOURCE"
saw2_info "executable: $STAGE_DIR/saw2"
saw2_info "launch from project root with: ./run.sh"
