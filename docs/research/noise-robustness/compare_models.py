#!/usr/bin/env python3
"""Parakeet vs Whisper noise-robustness. Each model scored against ITS OWN
clean transcript, so we compare how much noise degrades each — a proxy for
how noise-robust the checkpoint is. Whisper (trained on huge diverse/noisy
data) degrading less would show the fix is a robust checkpoint, not a filter."""
import json, os, re, glob
from collections import defaultdict

def norm(s):
    return re.sub(r"[^a-z0-9' ]", " ", s.lower()).split()

def edits(r, h):
    n, m = len(r), len(h)
    d = [[0]*(m+1) for _ in range(n+1)]
    for i in range(n+1): d[i][0] = i
    for j in range(m+1): d[0][j] = j
    for i in range(1, n+1):
        for j in range(1, m+1):
            d[i][j] = d[i-1][j-1] if r[i-1]==h[j-1] else 1+min(d[i-1][j-1], d[i-1][j], d[i][j-1])
    return d[n][m]

def parse(p):
    b = os.path.basename(p)[:-4]
    if "__" not in b: return b, "clean", "none", "na"
    id_, cond, noise, snr = b.split("__"); return id_, cond, noise, snr.replace("snr","")

def load(fn):
    return {json.loads(l)["path"]: json.loads(l)["text"] for l in open(fn) if l.strip()}

def degradation(data):
    """WER of each noisy clip vs same clip's clean transcript, same model."""
    ref = {}
    for p, t in data.items():
        id_, cond, _, _ = parse(p)
        if cond == "clean": ref[id_] = norm(t)
    buckets = defaultdict(lambda: [0, 0])   # [edits, refwords]
    for p, t in data.items():
        id_, cond, noise, snr = parse(p)
        if cond != "noisy" or id_ not in ref: continue
        buckets[(noise, snr)][0] += edits(ref[id_], norm(t))
        buckets[(noise, snr)][1] += len(ref[id_])
    return {k: (e/n if n else 0) for k, (e, n) in buckets.items()}

para = degradation(load("out_v3.jsonl"))
whis = degradation(load("out_whisper.jsonl"))

print(f"{'noise':7} {'snr':>3}   {'Parakeet':>9} {'Whisper':>9}   winner")
print("-"*48)
for k in sorted(para, key=lambda k:(k[0], -int(k[1]))):
    p, w = para[k]*100, whis.get(k, 0)*100
    win = "Whisper" if w < p - 1 else ("Parakeet" if p < w - 1 else "tie")
    print(f"{k[0]:7} {k[1]:>3}   {p:8.1f}% {w:8.1f}%   {win} ({p-w:+.1f})")
