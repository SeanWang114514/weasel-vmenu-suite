# -*- coding: utf-8 -*-
"""Compare two predict-bigram.txt files: prev coverage + size + sample new prevs.

Usage: python compare_coverage.py <old.txt> <new.txt>
"""
import sys


def load_index(path):
    data = open(path, "rb").read()
    header, rest = data.split(b"\n", 1)
    n = int(header.split()[1])
    pos = 0
    entries = {}
    for _ in range(n):
        nl = rest.find(b"\n", pos)
        line = rest[pos:nl]
        ch, off, ln = line.split(b"\t")
        entries[ch.decode("utf-8")] = (int(off), int(ln))
        pos = nl + 1
    return data, entries


def bucket_total(data, off, ln):
    blob = data[off:off + ln]
    total_s = blob.split(b"\t", 1)[0]
    return int(total_s)


def main():
    old_path, new_path = sys.argv[1], sys.argv[2]
    od, oi = load_index(old_path)
    nd, ni = load_index(new_path)
    import os
    print("old: %.1f MB, prevs=%d" % (os.path.getsize(old_path) / 1048576, len(oi)))
    print("new: %.1f MB, prevs=%d" % (os.path.getsize(new_path) / 1048576, len(ni)))

    new_prevs = [c for c in ni if c not in oi]
    lost = [c for c in oi if c not in ni]
    print("newly covered prevs: %d ; lost prevs: %d" % (len(new_prevs), len(lost)))

    # growth of kept successors for a few important prevs
    for c in ["眼", "太", "北", "的", "我"]:
        if c in oi and c in ni:
            ol = od[oi[c][0]:oi[c][0] + oi[c][1]].count(b"=")
            nl_ = nd[ni[c][0]:ni[c][0] + ni[c][1]].count(b"=")
            print("  %s: kept successors %d -> %d, total %d -> %d" % (
                c, ol, nl_,
                bucket_total(od, *oi[c]), bucket_total(nd, *ni[c])))

    # sample newly covered prevs that have decent totals (typable contexts)
    sample = sorted(
        ((c, bucket_total(nd, *ni[c])) for c in new_prevs),
        key=lambda t: -t[1])[:20]
    print("top-20 newly covered prevs by total:")
    print("  " + " ".join("%s(%d)" % (c, t) for c, t in sample))

    if lost:
        print("LOST prevs:", "".join(sorted(lost)[:40]))


if __name__ == "__main__":
    main()
