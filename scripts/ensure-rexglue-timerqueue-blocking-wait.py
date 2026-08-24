#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ensure-rexglue-timerqueue-blocking-wait.py /path/to/rexglue-sdk")

sdk = Path(sys.argv[1]).resolve()
src = sdk / "src/core/timer_queue.cpp"

if not src.is_file():
    raise SystemExit(f"[timerqueue] missing source: {src}")

text = src.read_text(encoding="utf-8")
before = text

# Include.
text = text.replace(
    "#include <disruptorplus/spin_wait_strategy.hpp>",
    "#include <disruptorplus/blocking_wait_strategy.hpp>",
)

# TimerQueue member types.
text = text.replace(
    "dp::spin_wait_strategy wait_strategy_;",
    """// TimerQueue spends most of its time waiting for either a newly queued
  // timer or the next timer deadline. Busy-spinning here wastes a host CPU
  // thread. blocking_wait_strategy sleeps on a condition variable and is
  // signaled automatically by claim_strategy_.publish().
  dp::blocking_wait_strategy wait_strategy_;""",
)
text = text.replace(
    "dp::multi_threaded_claim_strategy<dp::spin_wait_strategy> claim_strategy_;",
    "dp::multi_threaded_claim_strategy<dp::blocking_wait_strategy> claim_strategy_;",
)
text = text.replace(
    "dp::sequence_barrier<dp::spin_wait_strategy> consumed_;",
    "dp::sequence_barrier<dp::blocking_wait_strategy> consumed_;",
)

src.write_text(text, encoding="utf-8")

final = src.read_text(encoding="utf-8")

required = [
    "#include <disruptorplus/blocking_wait_strategy.hpp>",
    "dp::blocking_wait_strategy wait_strategy_;",
    "dp::multi_threaded_claim_strategy<dp::blocking_wait_strategy> claim_strategy_;",
    "dp::sequence_barrier<dp::blocking_wait_strategy> consumed_;",
]
missing = [x for x in required if x not in final]
if missing:
    raise SystemExit(f"[timerqueue] sanity check failed; missing: {missing}")

# This source should no longer instantiate spin_wait_strategy for TimerQueue.
for forbidden in [
    "dp::spin_wait_strategy wait_strategy_;",
    "dp::multi_threaded_claim_strategy<dp::spin_wait_strategy> claim_strategy_;",
    "dp::sequence_barrier<dp::spin_wait_strategy> consumed_;",
]:
    if forbidden in final:
        raise SystemExit(f"[timerqueue] old spin strategy still present: {forbidden}")

if final != before:
    print("[timerqueue] converted TimerQueue spin_wait_strategy -> blocking_wait_strategy")
else:
    print("[timerqueue] TimerQueue blocking_wait_strategy already present")

print("[timerqueue] OK (no root patch generated)")
