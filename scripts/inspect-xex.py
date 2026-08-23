#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import re
from pathlib import Path


def hashes(data: bytes):
    return hashlib.md5(data).hexdigest(), hashlib.sha256(data).hexdigest()


def ascii_strings(data: bytes, minimum: int = 6):
    pat = rb"[\x20-\x7e]{%d,}" % minimum
    for m in re.finditer(pat, data):
        yield m.start(), m.group().decode("ascii", "replace")


def main():
    p = argparse.ArgumentParser(description="Small non-decrypting XEX sanity probe")
    p.add_argument("xex", nargs="?", default="game/Default.xex")
    args = p.parse_args()
    path = Path(args.xex)
    data = path.read_bytes()
    md5, sha256 = hashes(data)
    print(f"file:    {path}")
    print(f"size:    {len(data)} bytes")
    print(f"magic:   {data[:4]!r}")
    print(f"md5:     {md5}")
    print(f"sha256:  {sha256}")

    needles = ("Saw2", "4B4E0822", "32FBD29B", "XBOXKRNL", "xboxkrnl")
    print("\ninteresting strings:")
    seen = set()
    for off, s in ascii_strings(data, 6):
        if any(n in s for n in needles) and s not in seen:
            print(f"  0x{off:08X}: {s}")
            seen.add(s)


if __name__ == "__main__":
    main()
