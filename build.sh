#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"

BUILD_KIND="relwithdebinfo"
CLEAN=0
CHECK_ONLY=0
INSTALL_DEPS=0
BOOTSTRAP_SDK=0
SDK_SOURCE="${REXSDK_DIR:-}"
SDK_PREFIX_OVERRIDE="${REXGLUE_SDK_PREFIX:-${REXGLUE_PREFIX:-}}"
JOBS="${SAW2_BUILD_JOBS:-}"

usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

Build configuration:
  --debug                 Build Debug
  --relwithdebinfo        Build RelWithDebInfo (default)
  --release               Build Release
  --clean                 Fresh CMake configure and clean-first build

Environment and SDK:
  --check                 Validate the environment only
  --install-deps          Authorize installing missing distro packages
  --bootstrap-sdk         Clone/build the pinned ReXGlue SDK under .deps/
  --sdk-prefix PATH       Use one coherent installed ReXGlue prefix
  --sdk-source PATH       Build/install ReXGlue from this source tree
  --jobs N                Parallel build jobs
  -h, --help              Show this help

Environment equivalents: REXGLUE_SDK_PREFIX (or REXGLUE_PREFIX), REXSDK_DIR.
No package installation or download occurs without explicit permission (or an
interactive confirmation).
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
    --check) CHECK_ONLY=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --bootstrap-sdk) BOOTSTRAP_SDK=1 ;;
    --sdk-prefix)
      require_value "$1" "${2:-}"
      SDK_PREFIX_OVERRIDE="$2"
      shift
      ;;
    --sdk-source)
      require_value "$1" "${2:-}"
      SDK_SOURCE="$2"
      shift
      ;;
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

DISTRO_ID="unknown"
DISTRO_LIKE=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
fi
saw2_info "host distribution: $DISTRO_ID${DISTRO_LIKE:+ (like $DISTRO_LIKE)}"
saw2_info "host architecture: $SAW2_HOST_ARCH"
saw2_info "configuration: $BUILD_KIND"

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
  local command_name cmake_version cmake_major cmake_minor
  MISSING_REQUIREMENTS=()
  for command_name in cmake ninja git python3 sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 ||
      MISSING_REQUIREMENTS+=("command:$command_name")
  done

  if command -v cmake >/dev/null 2>&1; then
    cmake_version="$(cmake --version | sed -nE '1{s/[^0-9]*([0-9]+)\.([0-9]+).*/\1.\2/p;q;}')"
    cmake_major="${cmake_version%%.*}"
    cmake_minor="${cmake_version#*.}"
    if [[ ! "$cmake_major" =~ ^[0-9]+$ ]] ||
       ((cmake_major < 3 || (cmake_major == 3 && cmake_minor < 25))); then
      MISSING_REQUIREMENTS+=("CMake>=3.25")
    fi
  fi

  select_clang
  if [[ -z "$CLANG_CXX" ]] || ((CLANG_MAJOR < 18)); then
    MISSING_REQUIREMENTS+=("Clang>=18")
  fi
  command -v ld.lld >/dev/null 2>&1 ||
    saw2_warn "ld.lld is unavailable; the system linker will be used"

  for command_name in libvulkan.so.1 libX11.so.6 libX11-xcb.so.1 libxcb.so.1 \
    libwayland-client.so.0; do
    library_available "$command_name" ||
      MISSING_REQUIREMENTS+=("runtime-library:$command_name")
  done

  if ((BOOTSTRAP_SDK)) || [[ -n "$SDK_SOURCE" ]]; then
    command -v pkg-config >/dev/null 2>&1 ||
      MISSING_REQUIREMENTS+=("command:pkg-config")
    for command_name in x11-xcb wayland-client alsa libpulse libpipewire-0.3; do
      if command -v pkg-config >/dev/null 2>&1 &&
         ! pkg-config --exists "$command_name"; then
        MISSING_REQUIREMENTS+=("development-package:$command_name")
      fi
    done
  fi
}

dependency_command() {
  local -n output_ref="$1"
  local -a privilege=()
  if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 || return 1
    privilege=(sudo)
  fi
  case " $DISTRO_ID $DISTRO_LIKE " in
    *" arch "*)
      output_ref=("${privilege[@]}" pacman -S --needed --
        base-devel cmake ninja clang lld git python pkgconf curl unzip autoconf
        gtk3 libx11 libxss vulkan-headers vulkan-icd-loader wayland
        wayland-protocols libxkbcommon libdecor alsa-lib libpulse pipewire)
      ;;
    *" debian "*|*" ubuntu "*)
      output_ref=("${privilege[@]}" apt-get install -y
        cmake ninja-build clang lld git python3 python3-venv pkg-config
        build-essential curl unzip autoconf libgtk-3-dev libx11-xcb-dev
        libxss-dev libvulkan-dev libwayland-dev libwayland-bin
        wayland-protocols libxkbcommon-dev libdecor-0-dev libasound2-dev
        libpulse-dev libpipewire-0.3-dev)
      ;;
    *" fedora "*|*" rhel "*)
      output_ref=("${privilege[@]}" dnf install -y
        cmake ninja-build clang lld git python3 pkgconf-pkg-config gcc-c++
        curl unzip autoconf gtk3-devel libX11-devel libXScrnSaver-devel
        vulkan-headers vulkan-loader-devel wayland-devel wayland-protocols-devel
        libxkbcommon-devel libdecor-devel alsa-lib-devel
        pulseaudio-libs-devel pipewire-devel)
      ;;
    *) return 1 ;;
  esac
}

offer_dependency_install() {
  ((${#MISSING_REQUIREMENTS[@]})) || return 0
  local answer=""
  local install_now="$INSTALL_DEPS"
  local -a install_command=()
  saw2_warn "missing host requirements: ${MISSING_REQUIREMENTS[*]}"
  dependency_command install_command ||
    saw2_die "unsupported distribution; install the requirements above manually"
  saw2_info "suggested dependency command:"
  saw2_print_command "${install_command[@]}"
  if ((!install_now)) && [[ -t 0 && -t 1 ]]; then
    read -r -p '[saw2] Install these packages now? [y/N] ' answer
    [[ "$answer" =~ ^[Yy]$ ]] && install_now=1
  fi
  ((install_now)) ||
    saw2_die "dependencies not installed (use --install-deps to authorize it)"
  saw2_run "${install_command[@]}"
  check_host_requirements
  ((${#MISSING_REQUIREMENTS[@]} == 0)) ||
    saw2_die "requirements remain missing: ${MISSING_REQUIREMENTS[*]}"
}

check_host_requirements
offer_dependency_install
saw2_info "compiler: $CLANG_CXX (Clang $CLANG_MAJOR)"
saw2_info "CMake: $(cmake --version | sed -n '1p')"
saw2_verify_xex

[[ -f "$ROOT_DIR/CMakeLists.txt" ]] || saw2_die "missing CMakeLists.txt"
[[ -f "$ROOT_DIR/CMakePresets.json" ]] || saw2_die "missing CMakePresets.json"
[[ -f "$SAW2_MANIFEST" ]] || saw2_die "missing saw2_manifest.toml"
[[ -f "$ROOT_DIR/generated/rexglue.cmake" ]] ||
  saw2_die "missing generated/rexglue.cmake scaffold"

if [[ -e "$ROOT_DIR/.git" && -f "$ROOT_DIR/.gitmodules" ]]; then
  if ((CHECK_ONLY)); then
    saw2_info "project submodules: declared (initialization skipped by --check)"
  else
    saw2_info "initializing Saw II project submodules"
    saw2_run git -C "$ROOT_DIR" submodule update --init --recursive
  fi
else
  saw2_info "project submodules: none"
fi

build_sdk_source() {
  local source_dir="$1"
  local install_prefix="$source_dir/out/install/$SAW2_SDK_PRESET"
  [[ -f "$source_dir/CMakeLists.txt" && -f "$source_dir/CMakePresets.json" ]] ||
    saw2_die "not a ReXGlue SDK source tree: $source_dir"
  if [[ -e "$source_dir/.git" ]]; then
    saw2_run git -C "$source_dir" submodule update --init --recursive
  fi
  saw2_run cmake --preset "$SAW2_SDK_PRESET" -S "$source_dir" \
    -DCMAKE_C_COMPILER:FILEPATH="$CLANG_C" \
    -DCMAKE_CXX_COMPILER:FILEPATH="$CLANG_CXX"
  saw2_run cmake --build "$source_dir/out/build/$SAW2_SDK_PRESET" \
    --target install --parallel "$JOBS"
  SDK_PREFIX_OVERRIDE="$install_prefix"
}

if [[ -n "$SDK_SOURCE" ]]; then
  SDK_SOURCE="$(cd -- "$SDK_SOURCE" 2>/dev/null && pwd -P)" ||
    saw2_die "SDK source directory does not exist"
  build_sdk_source "$SDK_SOURCE"
fi

if [[ -n "$SDK_PREFIX_OVERRIDE" ]]; then
  export REXGLUE_SDK_PREFIX="$SDK_PREFIX_OVERRIDE"
fi

if ! saw2_discover_sdk; then
  ((BOOTSTRAP_SDK)) ||
    saw2_die "ReXGlue SDK not found; use --sdk-prefix, --sdk-source or --bootstrap-sdk"
  SDK_SOURCE="$ROOT_DIR/.deps/rexglue-sdk"
  if [[ ! -d "$SDK_SOURCE" ]]; then
    saw2_run git clone --recursive "$SAW2_REXGLUE_REPOSITORY" "$SDK_SOURCE"
    saw2_run git -C "$SDK_SOURCE" checkout --detach "$SAW2_REXGLUE_COMMIT"
  elif [[ -e "$SDK_SOURCE/.git" ]]; then
    sdk_head="$(git -C "$SDK_SOURCE" rev-parse HEAD)"
    [[ "$sdk_head" == "$SAW2_REXGLUE_COMMIT" ]] ||
      saw2_die ".deps SDK is at $sdk_head, expected $SAW2_REXGLUE_COMMIT"
  fi
  build_sdk_source "$SDK_SOURCE"
  export REXGLUE_SDK_PREFIX="$SDK_PREFIX_OVERRIDE"
  saw2_discover_sdk || saw2_die "installed SDK could not be rediscovered"
fi
saw2_verify_sdk

saw2_info "ReXGlue CLI: $SAW2_REXGLUE_CLI ($("$SAW2_REXGLUE_CLI" --version | sed -n '1p'))"
saw2_info "ReXGlue prefix: $SAW2_SDK_PREFIX"

if ((CHECK_ONLY)); then
  saw2_info "environment check passed; no codegen/configure/build performed"
  exit 0
fi

saw2_prepare_logs
BUILD_LOG="$ROOT_DIR/logs/build-$(saw2_timestamp)-$$.log"
CODEGEN_LOG="$ROOT_DIR/logs/codegen-$(saw2_timestamp)-$$.log"
saw2_info "build log: $BUILD_LOG"
exec > >(tee "$BUILD_LOG") 2>&1

# Normal codegen is stamp-aware and cheap when current. Running it before
# configure is essential on a clean tree so CMake sees every generated TU.
saw2_run "$SAW2_REXGLUE_CLI" --log-level info --log-file "$CODEGEN_LOG" \
  codegen "$SAW2_MANIFEST"

declare -a configure_extra=(
  -DCMAKE_C_COMPILER:FILEPATH="$CLANG_C"
  -DCMAKE_CXX_COMPILER:FILEPATH="$CLANG_CXX"
)
if ((CLEAN)); then
  configure_extra+=(--fresh)
fi
saw2_print_command cmake --preset "$PRESET" -S "$ROOT_DIR" \
  -DCMAKE_PREFIX_PATH:PATH="$SAW2_SDK_PREFIX" \
  -Drexglue_DIR:PATH="$(saw2_config_from_prefix "$SAW2_SDK_PREFIX")" \
  "${configure_extra[@]}"
saw2_cmake_configure "$PRESET" "${configure_extra[@]}"

declare -a build_command=(cmake --build "$BUILD_DIR" --parallel "$JOBS")
if ((CLEAN)); then
  build_command+=(--clean-first)
fi
saw2_run "${build_command[@]}"

BINARY_PATH="$BUILD_DIR/saw2"

# ReXGlue 0.10 ships the runtime and Xenos backend as SDK libraries.
# The game target itself only links the executable; it does not rebuild
# librexgpu-xenos.so in the project build directory. Resolve both shared
# libraries from the selected SDK and stage them beside the executable.
find_sdk_library() {
  local library_name="$1"
  local candidate=""
  for candidate in \
    "$SAW2_SDK_PREFIX/lib/$library_name" \
    "$SAW2_SDK_PREFIX/lib64/$library_name"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  find "$SAW2_SDK_PREFIX" -type f -name "$library_name" -print -quit 2>/dev/null
}

RUNTIME_PATH="$(find_sdk_library librexruntime.so || true)"
PLUGIN_PATH="$(find_sdk_library librexgpu-xenos.so || true)"
[[ -x "$BINARY_PATH" ]] || saw2_die "build produced no executable: $BINARY_PATH"
[[ -n "$RUNTIME_PATH" && -f "$RUNTIME_PATH" ]] ||
  saw2_die "selected SDK has no librexruntime.so: $SAW2_SDK_PREFIX"
[[ -n "$PLUGIN_PATH" && -f "$PLUGIN_PATH" ]] ||
  saw2_die "selected SDK has no librexgpu-xenos.so: $SAW2_SDK_PREFIX"
saw2_info "ReXGlue runtime: $RUNTIME_PATH"
saw2_info "Xenos plugin: $PLUGIN_PATH"

mkdir -p -- "$STAGE_DIR"
saw2_run install -m 0755 "$BINARY_PATH" "$STAGE_DIR/saw2"
saw2_run install -m 0755 "$PLUGIN_PATH" "$STAGE_DIR/librexgpu-xenos.so"
saw2_run install -m 0755 "$RUNTIME_PATH" "$STAGE_DIR/librexruntime.so"
if [[ -L "$ROOT_DIR/out/stage/current" || ! -e "$ROOT_DIR/out/stage/current" ]]; then
  saw2_run ln -sfn "$PRESET" "$ROOT_DIR/out/stage/current"
else
  saw2_warn "out/stage/current is not a symlink; leaving it unchanged"
fi

if command -v ldd >/dev/null 2>&1 &&
   LD_LIBRARY_PATH="$STAGE_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
     ldd "$STAGE_DIR/saw2" | grep -q 'not found'; then
  saw2_die "staged executable has unresolved shared libraries"
fi

printf '\n'
saw2_info "build successful"
saw2_info "executable: $STAGE_DIR/saw2"
saw2_info "launch from the project root with: ./run.sh"
