# Project status

## Current milestone

The current Saw II bring-up has progressed through XEX loading, generated PPC
registration, guest execution, Xenos rendering activity and visible guest frame
output in local testing.

The latest recorded blocker is a title-specific indirect PPC target that
requires an exact function boundary. The manifest already contains the narrow
candidate boundary for `0x82275238`; a fresh post-change build/runtime proof is
still required before treating that blocker as resolved.

## Known generated-code baseline

- ReXGlue baseline: `0.10.0-dev.g398e2ba`
- Supported XEX SHA-256: `0bb765d0c89de2674efea76056a9c1b6236173587398ddc248b08cc1a6092883`
- Last runtime-backed registration count documented locally: 47,091 functions

## Next work

1. Rebuild from a clean generated tree with the current manifest.
2. Verify the `0x82275238` boundary with a bounded runtime test.
3. Capture the next invalid guest target, if any, with GDB.
4. Continue GPU/input/audio validation only after the guest control flow is stable.

Local logs and captures are intentionally not committed to the repository.
