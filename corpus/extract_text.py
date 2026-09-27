"""Extract the `text` column of a wikimedia/wikipedia parquet shard into a UTF-8 text file.

Usage: python extract_text.py <shard.parquet> <out.txt>
Streams in batches so memory stays bounded. ASCII-only source on purpose.
"""
import sys

import pyarrow.parquet as pq


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    pf = pq.ParquetFile(src)
    rows = 0
    chars = 0
    with open(dst, "w", encoding="utf-8", newline="\n") as out:
        for batch in pf.iter_batches(columns=["text"], batch_size=128):
            col = batch.column(0)
            for t in col.to_pylist():
                if not t:
                    continue
                out.write(t)
                out.write("\n")
                rows += 1
                chars += len(t)
    print(f"rows={rows} chars={chars} -> {dst}")


if __name__ == "__main__":
    main()
