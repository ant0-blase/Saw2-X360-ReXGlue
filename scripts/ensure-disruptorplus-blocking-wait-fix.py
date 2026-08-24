#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit(
        "usage: ensure-disruptorplus-blocking-wait-fix.py /path/to/rexglue-sdk"
    )

sdk = Path(sys.argv[1]).resolve()
header = (
    sdk
    / "thirdparty"
    / "disruptorplus"
    / "include"
    / "disruptorplus"
    / "blocking_wait_strategy.hpp"
)

if not header.is_file():
    raise SystemExit(f"[disruptorplus] missing header: {header}")

text = header.read_text(encoding="utf-8")
before = text

old_wait_for = '''                m_cv.wait_for(
                    lock,
                    [&]() -> bool {
                        result = minimum_sequence_after(sequence, count, sequences);
                        return difference(result, sequence) >= 0;
                    },
                    timeout);'''

new_wait_for = '''                m_cv.wait_for(
                    lock,
                    timeout,
                    [&]() -> bool {
                        result = minimum_sequence_after(sequence, count, sequences);
                        return difference(result, sequence) >= 0;
                    });'''

old_wait_until = '''                m_cv.wait_until(
                    lock,
                    [&]() -> bool {
                        result = minimum_sequence_after(sequence, count, sequences);
                        return difference(result, sequence) >= 0;
                    },
                    timeoutTime);'''

new_wait_until = '''                m_cv.wait_until(
                    lock,
                    timeoutTime,
                    [&]() -> bool {
                        result = minimum_sequence_after(sequence, count, sequences);
                        return difference(result, sequence) >= 0;
                    });'''

if old_wait_for in text:
    text = text.replace(old_wait_for, new_wait_for, 1)
elif new_wait_for not in text:
    raise SystemExit("[disruptorplus] wait_for anchor not found")

if old_wait_until in text:
    text = text.replace(old_wait_until, new_wait_until, 1)
elif new_wait_until not in text:
    raise SystemExit("[disruptorplus] wait_until anchor not found")

header.write_text(text, encoding="utf-8")
final = header.read_text(encoding="utf-8")

if old_wait_for in final or old_wait_until in final:
    raise SystemExit("[disruptorplus] broken condition_variable call order remains")

if new_wait_for not in final:
    raise SystemExit("[disruptorplus] corrected wait_for call missing")

if new_wait_until not in final:
    raise SystemExit("[disruptorplus] corrected wait_until call missing")

if final != before:
    print("[disruptorplus] fixed wait_for/wait_until condition_variable argument order")
else:
    print("[disruptorplus] condition_variable argument order already fixed")

print("[disruptorplus] OK (no root patch generated)")
