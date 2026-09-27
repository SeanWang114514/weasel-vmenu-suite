# -*- coding: utf-8 -*-
"""Verify predict-bigram.txt offsets parse correctly (0-based file vs 1-based Lua).

Usage: python check_format.py [file]   (default: corpus\\predict-bigram.txt)
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else r"D:\VibeCoding\输入法\corpus\predict-bigram.txt"
data = open(path, "rb").read()
h, rest = data.split(b"\n", 1)
print("header:", h)
n = int(h.split()[1])

# index region = next n lines
pos = 0
entries = []
for _ in range(n):
    nl = rest.find(b"\n", pos)
    line = rest[pos:nl]
    ch, off, ln = line.split(b"\t")
    entries.append((ch, int(off), int(ln)))
    pos = nl + 1

def lookup(target):
    for ch, off, ln in entries:
        if ch == target.encode("utf-8"):
            return off, ln
    return None

for prev_ch, succ_ch in [("眼", "睛"), ("太", "阳"), ("北", "京")]:
    off, ln = lookup(prev_ch)
    for delta in (0, 1):
        blob = data[off + delta:off + delta + ln]
        try:
            total_s, body = blob.split(b"\t", 1)
            total = int(total_s)
        except Exception as e:
            print(f"  {prev_ch} delta={delta}: PARSE FAIL {e}")
            continue
        ok = succ_ch in body.decode("utf-8", "replace")
        first = body.split(b" ")[0]
        print(f"  {prev_ch} delta={delta}: total={total} first={first!r} has[{succ_ch}]={ok}")
    print()
