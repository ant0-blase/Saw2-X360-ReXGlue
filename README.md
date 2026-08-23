# Saw II: Flesh & Blood — Xbox 360 ReXGlue Recompilation

Experimental native recompilation bring-up for the Xbox 360 version of
**Saw II: Flesh & Blood**, built around ReXGlue 0.10.

The repository contains the project scaffold, title-specific function boundary
hints, build/runtime tooling and host-side integration code. It does **not**
contain the game executable or retail assets.

> **Project status:** early bring-up. This is not a finished or fully playable
> PC port.

## Current target

| Field | Value |
|---|---|
| Title ID | `4B4E0822` |
| Media ID | `32FBD29B` |
| Internal module | `Saw2Game-XeReleaseLTCG.exe` |
| Expected XEX | `game/Default.xex` |
| SHA-256 | `0bb765d0c89de2674efea76056a9c1b6236173587398ddc248b08cc1a6092883` |
| ReXGlue baseline | `0.10.0-dev.g398e2ba` |

## Requirements

The Linux workflow expects a recent 64-bit Linux environment with:

- CMake 3.25 or newer
- Ninja
- Clang 18 or newer
- Git
- Python 3
- Vulkan and the host window/input runtime libraries required by ReXGlue

`build.sh` detects Arch Linux, Debian/Ubuntu and Fedora-family systems. Missing
packages are never installed without explicit authorization.

## Game setup

Copy your own supported game extraction into `game/`. At minimum, codegen needs:

```text
game/Default.xex
```

The exact supported XEX hash is verified before codegen or runtime startup.
See [`game/README.md`](game/README.md) for the expected layout.

## Build

From the repository root:

```bash
./build.sh --bootstrap-sdk
```

This bootstraps the pinned ReXGlue SDK under `.deps/`, performs stamp-aware
codegen and builds a staged executable. If ReXGlue is already installed:

```bash
./build.sh --sdk-prefix /path/to/rexglue/prefix
```

Useful variants:

```bash
./build.sh --debug
./build.sh --release
./build.sh --clean
./build.sh --check
./build.sh --jobs 8
```

The default configuration is `RelWithDebInfo`.

## Run

With the complete extracted game tree under `game/`:

```bash
./run.sh
```

Useful diagnostics:

```bash
./run.sh --debug
./run.sh --gdb
./test-boot.sh --timeout 30 -- --debug
./gdb.sh
```

Generated logs, captures, build output, generated PPC translation units and
retail game files are ignored by Git.

## Repository layout

```text
Saw2-X360-ReXGlue/
├── build.sh                 # dependency, SDK, codegen and build orchestration
├── run.sh                   # staged runtime launcher
├── test-boot.sh             # bounded boot smoke test
├── gdb.sh                   # guest invalid-function diagnostics
├── saw2_manifest.toml       # ReXGlue manifest and title-specific boundaries
├── src/                     # host application integration
├── generated/               # small ReXGlue CMake scaffold only
├── scripts/                 # shared Linux/Windows helper scripts
├── docs/                    # bring-up and analysis notes
├── game/                    # user-supplied retail files; ignored by Git
└── logs/                    # local diagnostics; ignored by Git
```

## Development rules

Title-specific function boundaries must be derived from the exact supported
XEX. Do not hide unknown guest targets behind broad guessed ranges or generic
success stubs. Keep generated recompilation output out of version control and
make host-side fixes reproducible whenever possible.

## License

Original project code is licensed under **GPL-3.0-only**. ReXGlue and upstream
components retain their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

No retail Saw II executable, assets, encryption keys or other proprietary game
content are included or licensed by this repository.
