# -*- coding: utf-8 -*-
"""Extract text from multiple parquet shards (+ optionally append plain .txt parts)
into one UTF-8 LF corpus file, streaming in bounded memory.

Usage:
  python extract_all.py <out.txt> <file1.parquet|file1.txt> <file2...> ...
  .parquet -> read the `text` column; .txt -> append bytes as-is (already UTF-8 LF).
Prints per-file rows/chars and the grand total.
"""
import os
import sys

import pyarrow.parquet as pq


def main() -> None:
    out_path, *inputs = sys.argv[1:]
    total_rows = 0
    total_chars = 0
    with open(out_path, "wb") as out:
        for src in inputs:
            if src.lower().endswith(".parquet"):
                pf = pq.ParquetFile(src)
                rows = 0
                chars = 0
                for batch in pf.iter_batches(columns=["text"], batch_size=512):
                    for t in batch.column(0).to_pylist():
                        if not t:
                            continue
                        out.write(t.encode("utf-8"))
                        out.write(b"\n")
                        rows += 1
                        chars += len(t)
                print("parquet %-40s rows=%d chars=%d" % (os.path.basename(src), rows, chars), flush=True)
            else:
                with open(src, "rb") as f:
                    data = f.read()
                out.write(data)
                if data and not data.endswith(b"\n"):
                    out.write(b"\n")
                rows = data.count(b"\n")
                chars = len(data.decode("utf-8", "ignore"))
                print("text    %-40s rows=%d chars=%d" % (os.path.basename(src), rows, chars), flush=True)
            total_rows += rows
            total_chars += chars
    print("TOTAL rows=%d chars=%d -> %s (%.1f MB)" % (
        total_rows, total_chars, out_path, os.path.getsize(out_path) / 1048576))


if __name__ == "__main__":
    main()
