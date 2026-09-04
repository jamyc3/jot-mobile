#!/usr/bin/env python3
"""Pick a test set of clean clips + reference transcripts from the Jot CSV."""
import csv, os, re, sys, wave, contextlib

CSV = os.path.expanduser("~/Desktop/jot-recordings.csv")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 36
OUT = "testset.tsv"

def dur(path):
    try:
        with contextlib.closing(wave.open(path)) as w:
            return w.getnframes() / w.getframerate()
    except Exception:
        return None

def ascii_ratio(s):
    if not s: return 0
    return sum(c.isascii() for c in s) / len(s)

rows = []
with open(CSV, newline="") as f:
    for r in csv.DictReader(f):
        path, tx = r["audio_file"], (r["transcript"] or "").strip()
        if not tx: continue
        wc = len(tx.split())
        if wc < 8 or wc > 60: continue          # long enough for a meaningful WER, short enough to stay fast
        if ascii_ratio(tx) < 0.98: continue      # keep it English/latin so scoring is clean
        if not os.path.isfile(path): continue
        rows.append((os.path.splitext(os.path.basename(path))[0], path, tx, wc, 0.0))

# spread across the corpus (stride) so we don't grab one contiguous session
rows.sort(key=lambda x: x[0])
step = max(1, len(rows) // N)
picked = rows[::step][:N]

with open(OUT, "w") as f:
    for id_, path, tx, wc, d in picked:
        f.write(f"{id_}\t{path}\t{wc}\t{d}\t{tx}\n")

print(f"candidates={len(rows)}  picked={len(picked)}")
print(f"total ref words={sum(p[3] for p in picked)}  median dur={sorted(p[4] for p in picked)[len(picked)//2]}s")
