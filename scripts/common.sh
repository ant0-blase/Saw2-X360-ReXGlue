#!/usr/bin/env bash

# Shared Saw II workflow helpers. Sourcing this file performs no network,
# package-manager or build mutation.

SAW2_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SAW2_XEX="$SAW2_ROOT/game/Default.xex"
SAW2_MANIFEST="$SAW2_ROOT/saw2_manifest.toml"
SAW2_EXPECTED_XEX_SHA256="0bb765d0c89de2674efea76056a9c1b6236173587398ddc248b08cc1a6092883"
SAW2_EXPECTED_REXGLUE_VERSION="0.10.0-dev.g398e2ba"
SAW2_REXGLUE_VERSION_PREFIX="0.10."
SAW2_REXGLUE_COMMIT="398e2ba7802d0c4ca1f68d7ad4fa2cd73e8123eb"
SAW2_REXGLUE_REPOSITORY="https://github.com/rexglue/rexglue-sdk.git"

case "$(uname -m)" in
  x86_64|amd64) SAW2_HOST_ARCH="amd64" ;;
  aarch64|arm64) SAW2_HOST_ARCH="arm64" ;;
  *) SAW2_HOST_ARCH="unsupported" ;;
esac
SAW2_DEFAULT_PRESET="linux-$SAW2_HOST_ARCH-relwithdebinfo"
SAW2_SDK_PRESET="linux-$SAW2_HOST_ARCH"
SAW2_SDK_PREFIX=""
SAW2_REXGLUE_CLI=""

saw2_die() {
  printf '[saw2] ERROR: %s\n' "$*" >&2
  exit 1
}

saw2_warn() {
  printf '[saw2] WARNING: %s\n' "$*" >&2
}

saw2_info() {
  printf '[saw2] %s\n' "$*"
}

saw2_print_command() {
  printf '[saw2] +'
  printf ' %q' "$@"
  printf '\n'
}

saw2_run() {
  saw2_print_command "$@"
  "$@"
}

saw2_require_command() {
  command -v "$1" >/dev/null 2>&1 || saw2_die "missing host dependency: $1"
}

saw2_verify_xex() {
  [[ -f "$SAW2_XEX" ]] || saw2_die "missing case-sensitive XEX: $SAW2_XEX"
  saw2_require_command sha256sum
  local actual_sha
  actual_sha="$(sha256sum "$SAW2_XEX")"
  actual_sha="${actual_sha%% *}"
  [[ "$actual_sha" == "$SAW2_EXPECTED_XEX_SHA256" ]] ||
    saw2_die "unexpected Default.xex SHA-256: $actual_sha"
}

saw2_config_from_prefix() {
  local prefix="$1"
  local candidate
  for candidate in \
    "$prefix/lib/cmake/rexglue" \
    "$prefix/lib64/cmake/rexglue" \
    "$prefix/share/rexglue/cmake"; do
    [[ -f "$candidate/rexglueConfig.cmake" ]] && {
      printf '%s\n' "$candidate"
      return 0
    }
  done
  return 1
}

saw2_package_version() {
  sed -nE 's/^[[:space:]]*set\(REXGLUE_VERSION_STRING[[:space:]]+"([^"]+)"\).*/\1/p' \
    "$1/rexglueConfig.cmake" | head -n 1
}

saw2_accept_sdk_prefix() {
  local prefix="$1"
  local config version cli
  [[ -d "$prefix" ]] || return 1
  prefix="$(cd -- "$prefix" && pwd -P)"
  config="$(saw2_config_from_prefix "$prefix" || true)"
  [[ -n "$config" ]] || return 1
  version="$(saw2_package_version "$config")"
  [[ "$version" == "$SAW2_REXGLUE_VERSION_PREFIX"* ]] || return 1
  cli="$prefix/bin/rexglue"
  [[ -x "$cli" ]] || return 1
  [[ "$("$cli" --version 2>/dev/null | sed -n '1p')" == "$version" ]] || return 1
  SAW2_SDK_PREFIX="$prefix"
  SAW2_REXGLUE_CLI="$cli"
  return 0
}

saw2_discover_sdk() {
  local requested="${REXGLUE_SDK_PREFIX:-${REXGLUE_PREFIX:-}}"
  local cache_config cli candidate prefix

  if [[ -n "$requested" ]]; then
    saw2_accept_sdk_prefix "$requested" ||
      saw2_die "no coherent ReXGlue $SAW2_REXGLUE_VERSION_PREFIX* SDK at $requested"
    return 0
  fi

  for candidate in \
    "$SAW2_ROOT/out/build/$SAW2_DEFAULT_PRESET/CMakeCache.txt" \
    "$SAW2_ROOT/out/build/linux-$SAW2_HOST_ARCH-debug/CMakeCache.txt" \
    "$SAW2_ROOT/out/build/linux-$SAW2_HOST_ARCH-release/CMakeCache.txt"; do
    [[ -f "$candidate" ]] || continue
    cache_config="$(sed -n 's/^rexglue_DIR:[^=]*=//p' "$candidate" | head -n 1)"
    [[ -n "$cache_config" ]] || continue
    prefix="$(cd -- "$cache_config/../../.." 2>/dev/null && pwd -P || true)"
    [[ -n "$prefix" ]] && saw2_accept_sdk_prefix "$prefix" && return 0
  done

  saw2_accept_sdk_prefix "$SAW2_ROOT/.deps/rexglue-sdk/out/install/$SAW2_SDK_PRESET" && return 0

  cli="$(command -v rexglue 2>/dev/null || true)"
  if [[ -n "$cli" ]]; then
    cli="$(readlink -f "$cli" 2>/dev/null || printf '%s' "$cli")"
    prefix="$(cd -- "$(dirname -- "$cli")/.." 2>/dev/null && pwd -P || true)"
    [[ -n "$prefix" ]] && saw2_accept_sdk_prefix "$prefix" && return 0
  fi

  for prefix in /usr/local /usr; do
    saw2_accept_sdk_prefix "$prefix" && return 0
  done
  return 1
}

saw2_verify_sdk() {
  if [[ -n "${REXGLUE_CLI:-}" ]]; then
    SAW2_REXGLUE_CLI="$REXGLUE_CLI"
    [[ -x "$SAW2_REXGLUE_CLI" ]] || saw2_die "REXGLUE_CLI is not executable"
    local cli_prefix
    cli_prefix="$(cd -- "$(dirname -- "$SAW2_REXGLUE_CLI")/.." && pwd -P)"
    saw2_accept_sdk_prefix "${REXGLUE_SDK_PREFIX:-${REXGLUE_PREFIX:-$cli_prefix}}" ||
      saw2_die "REXGLUE_CLI does not belong to a coherent installed SDK"
  elif ! saw2_discover_sdk; then
    saw2_die "ReXGlue SDK not found; set REXGLUE_SDK_PREFIX or use ./build.sh --bootstrap-sdk"
  fi

  local actual_version
  actual_version="$("$SAW2_REXGLUE_CLI" --version 2>/dev/null | sed -n '1p')"
  [[ "$actual_version" == "$SAW2_REXGLUE_VERSION_PREFIX"* ]] ||
    saw2_die "expected ReXGlue $SAW2_REXGLUE_VERSION_PREFIX*, found $actual_version"
}

saw2_prepare_logs() {
  mkdir -p -- "$SAW2_ROOT/logs"
}

saw2_timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

saw2_cmake_configure() {
  local preset="$1"
  shift
  cmake --preset "$preset" -S "$SAW2_ROOT" \
    -DCMAKE_PREFIX_PATH:PATH="$SAW2_SDK_PREFIX" \
    -Drexglue_DIR:PATH="$(saw2_config_from_prefix "$SAW2_SDK_PREFIX")" \
    "$@"
}

saw2_export_runtime_library_path() {
  local runtime_dir="$SAW2_SDK_PREFIX/lib"
  [[ -d "$runtime_dir" ]] || runtime_dir="$SAW2_SDK_PREFIX/lib64"
  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    export LD_LIBRARY_PATH="$runtime_dir:$LD_LIBRARY_PATH"
  else
    export LD_LIBRARY_PATH="$runtime_dir"
  fi
}
