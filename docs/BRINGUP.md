# Saw II bring-up workflow

## Reproducibility contract

The current baseline is ReXGlue `0.10.0-dev.g398e2ba`; the manifest records the
compatible `0.10.0` floor. `scripts/common.sh` discovers one coherent CLI,
CMake package and runtime prefix, while root `build.sh` can use `--sdk-prefix`
or build the pinned commit under `.deps/`. The workflow verifies the exact
`Default.xex` SHA-256 before codegen, build or runtime.

The filename case is deliberate: Linux must resolve `game/Default.xex`, not
`game/default.xex`.

## Commands

```bash
./scripts/bootstrap-sdk.sh
./scripts/codegen.sh
./build.sh
./test-boot.sh --timeout 30 -- --debug
```

The normal build runs stamp-aware codegen before CMake configure and also keeps
the generated `saw2_codegen` dependency, so a separate codegen invocation is
only needed when inspecting analysis output.
Modern ReXGlue uses `codegen --ignore-stamp` for an intentional re-analysis;
the old scaffold's `--force codegen` target has been removed because it no
longer describes the 0.10 CLI contract.

## Runtime defaults

The root runtime scripts pass:

```text
--gpu_plugin=xenos
--input_backend=sdl
--resolution=720p
--game_data_root=/path/to/legal/Saw2/extraction
```

The bounded boot test uses GNU `timeout` and retains paired console/runtime logs.
Surviving the observation window is reported separately from a clean guest
exit. A crash or fatal runtime exit is returned to the caller and retained in
both a runtime log and a console log.

## Evidence ladder

Record each milestone only when its log proves it:

1. XEX analyzed and generated function table registered.
2. Native executable loads the intended SDK runtime and Xenos plugin.
3. Guest entry point executes and imports are resolved.
4. Guest submits a draw/resolve/swap, not merely a host swapchain creation.
5. A guest-produced frame is presented.
6. SDL reports a physical controller and guest input calls observe it.

Do not add function boundary hints by analogy with another title. Every hint
must be derived from this exact XEX, be narrowly sized, and be documented with
the failing guest address and adjacent code evidence.
