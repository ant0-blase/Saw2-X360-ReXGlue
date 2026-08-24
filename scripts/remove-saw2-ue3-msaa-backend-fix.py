#!/usr/bin/env python3
from pathlib import Path
import re
import sys

root = Path.cwd()
src = root / ".deps" / "rexglue-sdk" / "src" / "graphics" / "command_processor.cpp"

if not src.is_file():
    raise SystemExit(f"[rollback] missing {src}")

text = src.read_text(encoding="utf-8")
before = text

# Remove any definition of our cvar.
cvar_pattern = re.compile(
    r'\n?REXCVAR_DEFINE_BOOL\(\s*'
    r'ue3_force_1x_msaa\s*,.*?'
    r'\)\s*'
    r'(?:\.lifecycle\(\s*rex::cvar::Lifecycle::kHotReload\s*\)\s*;\s*)?',
    re.DOTALL,
)
text, cvars = cvar_pattern.subn("\n", text)

# Remove only the Saw II workaround block inserted in WriteRegister.
workaround_pattern = re.compile(
    r'\n\s*// Saw II / UE3 MSAA artifact workaround\..*?'
    r'if\s*\(\s*index\s*==\s*XE_GPU_REG_RB_SURFACE_INFO\s*&&\s*'
    r'REXCVAR_GET\(ue3_force_1x_msaa\)\s*\)\s*\{\s*'
    r'value\s*&=\s*~\(UINT32_C\(0x3\)\s*<<\s*16\);\s*'
    r'\}\s*\n',
    re.DOTALL,
)
text, blocks = workaround_pattern.subn("\n", text)

if text != before:
    src.write_text(text, encoding="utf-8")

print(f"[rollback] removed cvar definitions: {cvars}")
print(f"[rollback] removed backend MSAA blocks: {blocks}")

final = src.read_text(encoding="utf-8")
if "ue3_force_1x_msaa" in final:
    raise SystemExit("[rollback] ERROR: ue3_force_1x_msaa still present")
if "Saw II / UE3 MSAA artifact workaround." in final:
    raise SystemExit("[rollback] ERROR: workaround marker still present")

print("[rollback] backend MSAA workaround removed")
