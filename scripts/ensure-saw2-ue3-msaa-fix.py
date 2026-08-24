#!/usr/bin/env python3
from pathlib import Path
import re
import shutil
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ensure-saw2-ue3-msaa-fix.py /path/to/rexglue-sdk")

sdk = Path(sys.argv[1]).resolve()
source = sdk / "src/graphics/command_processor.cpp"

if not source.is_file():
    raise SystemExit(f"[saw2-msaa] missing ReXGlue source: {source}")

backup = source.with_suffix(source.suffix + ".saw2-ue3-msaa-v4.bak")
if not backup.exists():
    shutil.copy2(source, backup)

text = source.read_text(encoding="utf-8")

cvar_pattern = re.compile(
    r'REXCVAR_DEFINE_BOOL\(\s*'
    r'ue3_force_1x_msaa\s*,.*?'
    r'\)\s*'
    r'(?:\.lifecycle\(\s*rex::cvar::Lifecycle::kHotReload\s*\)\s*;\s*)?',
    re.DOTALL,
)

existing_cvars = list(cvar_pattern.finditer(text))
if existing_cvars:
    print(f"[saw2-msaa] removing {len(existing_cvars)} existing ue3_force_1x_msaa definition(s)")
    text = cvar_pattern.sub("", text)

vsync_anchor = 'REXCVAR_DEFINE_BOOL(vsync, true, "GPU", "Enable vertical sync");\n'
if vsync_anchor not in text:
    raise SystemExit("[saw2-msaa] vsync cvar anchor not found")

canonical_cvar = '''REXCVAR_DEFINE_BOOL(
    ue3_force_1x_msaa, false, "GPU",
    "Force RB_SURFACE_INFO MSAA sample count to 1x. "
    "UE3 lighting / tiling workaround.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

'''
text = text.replace(vsync_anchor, vsync_anchor + "\n" + canonical_cvar, 1)

old_workaround_pattern = re.compile(
    r'\n\s*// Saw II / UE3 MSAA artifact workaround\..*?'
    r'if\s*\(\s*index\s*==\s*XE_GPU_REG_RB_SURFACE_INFO.*?'
    r'\n\s*\}\s*\n',
    re.DOTALL,
)
text, removed_workarounds = old_workaround_pattern.subn("\n", text)
if removed_workarounds:
    print(f"[saw2-msaa] removing {removed_workarounds} existing MSAA workaround block(s)")

write_anchor = '''void CommandProcessor::WriteRegister(uint32_t index, uint32_t value) {
  RegisterFile& regs = *register_file_;
'''
if write_anchor not in text:
    pos = text.find("void CommandProcessor::WriteRegister")
    context = text[pos:pos + 700] if pos >= 0 else "(function not found)"
    raise SystemExit(
        "[saw2-msaa] WriteRegister prologue not found.\n"
        "[saw2-msaa] local context:\n" + context
    )

workaround = '''void CommandProcessor::WriteRegister(uint32_t index, uint32_t value) {
  RegisterFile& regs = *register_file_;

  // Saw II / UE3 MSAA artifact workaround.
  //
  // RB_SURFACE_INFO has msaa_samples in bits 16..17. Xenos k1X is encoded
  // as zero, so clearing only these two bits preserves surface_pitch / HiZ.
  if (index == XE_GPU_REG_RB_SURFACE_INFO &&
      REXCVAR_GET(ue3_force_1x_msaa)) {
    value &= ~(UINT32_C(0x3) << 16);
  }
'''
text = text.replace(write_anchor, workaround, 1)

source.write_text(text, encoding="utf-8")

final = source.read_text(encoding="utf-8")

definition_count = len(cvar_pattern.findall(final))
if definition_count != 1:
    raise SystemExit(
        f"[saw2-msaa] sanity failure: expected exactly 1 cvar definition, got {definition_count}"
    )

if final.count("Saw II / UE3 MSAA artifact workaround.") != 1:
    raise SystemExit("[saw2-msaa] sanity failure: workaround block count is not 1")

required = [
    "ue3_force_1x_msaa",
    "index == XE_GPU_REG_RB_SURFACE_INFO",
    "value &= ~(UINT32_C(0x3) << 16);",
]
missing = [item for item in required if item not in final]
if missing:
    raise SystemExit(f"[saw2-msaa] sanity failure: missing {missing}")

try:
    diff = subprocess.run(
        ["git", "-C", str(sdk), "diff", "--", "src/graphics/command_processor.cpp"],
        check=True, text=True, stdout=subprocess.PIPE
    ).stdout
    out = Path.cwd() / "ReXGlue-saw2-ue3-msaa-fix.patch"
    out.write_text(diff, encoding="utf-8")
    print(f"[saw2-msaa] generated {out}")
except Exception as exc:
    print(f"[saw2-msaa] warning: could not generate diff: {exc}", file=sys.stderr)

print("[saw2-msaa] cvar definitions: 1")
print("[saw2-msaa] workaround blocks: 1")
print("[saw2-msaa] UE3 1x-MSAA workaround: OK")
