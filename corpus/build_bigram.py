"""Build the predict_filter bigram data file (predict-bigram.txt).

Usage:
  python build_bigram.py <corpus.txt> <out.txt> [--min-total 50] [--min-cnt 3] [--topk 128]

Format (UTF-8 text, LF newlines, no BOM; offsets are BYTE offsets into this file):
  line 1            : "RIMEBI1 <n_index>"
  next n_index lines: "<prev_char>\\t<bucket_offset:010d>\\t<bucket_len:06d>"
  bucket region     : at each offset, one line-less blob:
                      "<total>\\t<succ>=<cnt> <succ>=<cnt> ..."
  - total = sum of ALL successor counts for prev_char (incl. dropped ones),
    so P(succ|prev) = cnt / total stays an unbiased estimate.
  - successors sorted by count desc (build time).

Pairs counted: consecutive CJK-CJK characters in raw text; punctuation, latin
letters and digits break pairs naturally (no sentence segmentation needed).
ASCII-only source on purpose (PS 5.1-safe habits).
"""
import argparse
import sys
from collections import defaultdict

URO = (0x4E00, 0x9FFF)
EXT_A = (0x3400, 0x4DBF)


def is_cjk(cp: int) -> bool:
    return URO[0] <= cp <= URO[1] or EXT_A[0] <= cp <= EXT_A[1]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("out")
    ap.add_argument("--min-total", type=int, default=50)
    ap.add_argument("--min-cnt", type=int, default=3)
    ap.add_argument("--topk", type=int, default=128)
    args = ap.parse_args()

    cnt = defaultdict(int)   # (prev, succ) -> count
    tot = defaultdict(int)   # prev -> count of prev occurrences (pair opportunities)
    chars = 0
    cjk_chars = 0

    with open(args.corpus, "r", encoding="utf-8") as f:
        for line in f:
            prev = None
            for ch in line:
                chars += 1
                cp = ord(ch)
                if not is_cjk(cp):
                    prev = None
                    continue
                cjk_chars += 1
                if prev is not None:
                    key = (prev, ch)
                    cnt[key] += 1
                    tot[prev] += 1
                prev = ch

    print(f"corpus chars={chars} cjk={cjk_chars} distinct_pairs={len(cnt)} distinct_prev={len(tot)}")

    # filter + top-k per prev
    by_prev = defaultdict(list)
    for (p, s), c in cnt.items():
        if c >= args.min_cnt:
            by_prev[p].append((s, c))
    prevs = [p for p in by_prev if tot[p] >= args.min_total]
    prevs.sort(key=lambda p: ord(p))          # index sorted by codepoint (tidy only)
    for p in prevs:
        by_prev[p].sort(key=lambda t: (-t[1], ord(t[0])))
        by_prev[p] = by_prev[p][: args.topk]

    print(f"kept prevs={len(prevs)} (min_total={args.min_total}) topk={args.topk}")

    # sanity stats for interesting pairs
    for p, s in [("太", "阳"), ("很", "好"), ("眼", "睛"), ("沙", "漠"), ("汽", "油"), ("蜜", "蜂"), ("河", "北"), ("北", "京")]:
        c = cnt.get((p, s), 0)
        t = tot.get(p, 0)
        print(f"  P({s}|{p}) = {c}/{t}" + (f" = {c / t:.4f}" if t else ""))

    # bucket blobs (index first so offsets are known before writing buckets)
    header = f"RIMEBI1 {len(prevs)}\n"
    # The index region sits BETWEEN header and buckets, so bucket offsets start
    # after header + index. Index line size is deterministic:
    #   len(prev utf8) + 1(tab) + 10(offset) + 1(tab) + 6(len) + 1(newline)
    index_size = sum(len(p.encode("utf-8")) + 19 for p in prevs)
    blob_off = len(header.encode("utf-8")) + index_size
    index_lines = []
    blobs = []
    for p in prevs:
        succs = by_prev[p]
        body = " ".join(f"{s}={c}" for s, c in succs)
        blob = f"{tot[p]}\t{body}"
        b = blob.encode("utf-8")
        index_lines.append(f"{p}\t{blob_off:010d}\t{len(b):06d}\n")
        blobs.append(b)
        blob_off += len(b)
    index = "".join(index_lines).encode("utf-8")
    assert len(index) == index_size, f"index size mismatch {len(index)} != {index_size}"

    with open(args.out, "wb") as out:
        out.write(header.encode("utf-8"))
        out.write(index)
        for b in blobs:
            out.write(b)

    import os
    size = os.path.getsize(args.out)
    print(f"wrote {args.out}: {size / 1048576:.1f} MB, prevs={len(prevs)}")


if __name__ == "__main__":
    main()
