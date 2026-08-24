#!/usr/bin/env python3
from pathlib import Path
import re
import shutil
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ensure-rexglue-db16cyc-noop.py /path/to/rexglue-sdk")

sdk = Path(sys.argv[1]).resolve()
src = sdk / "src" / "codegen" / "builders" / "system.cpp"

if not src.is_file():
    raise SystemExit(f"[db16cyc] missing source: {src}")

backup = src.with_suffix(src.suffix + ".db16cyc-noop.bak")
if not backup.exists():
    shutil.copy2(src, backup)

text = src.read_text(encoding="utf-8")

pattern = re.compile(
    r"bool build_db16cyc\(BuilderContext& ctx\) \{.*?\n\}",
    re.DOTALL,
)

canonical = '''bool build_db16cyc(BuilderContext& ctx) {
  // Xenon-specific 16-cycle delay hint, no effect in recompiled code.
  // Keep this as a codegen no-op: mapping each hint to x86 PAUSE is much
  // more expensive than the guest hint on modern CPUs and dominated Saw II.
  (void)ctx;
  return true;
}'''

match = pattern.search(text)
if not match:
    raise SystemExit("[db16cyc] build_db16cyc function not found")

old = match.group(0)
if old != canonical:
    text = text[:match.start()] + canonical + text[match.end():]
    src.write_text(text, encoding="utf-8")
    print("[db16cyc] restored db16cyc codegen to no-op")
else:
    print("[db16cyc] db16cyc codegen already no-op")

final = src.read_text(encoding="utf-8")
m = pattern.search(final)
if not m:
    raise SystemExit("[db16cyc] sanity failure: function disappeared")

body = m.group(0)
for forbidden in (
    "__builtin_ia32_pause",
    "_mm_pause",
    'asm("pause")',
    '__asm__("pause")',
    '__asm__("yield")',
):
    if forbidden in body:
        raise SystemExit(f"[db16cyc] sanity failure: still contains {forbidden}")

if "(void)ctx;" not in body:
    raise SystemExit("[db16cyc] sanity failure: canonical no-op missing")

print("[db16cyc] OK (no root patch generated)")
