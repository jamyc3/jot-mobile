#!/usr/bin/env python3
"""Score noise-bench transcripts.

Reference = each clip's CLEAN transcript from the SAME engine, so a number
measures how far noise/processing pushes the result away from the clean-audio
result (noise-robustness delta), not absolute accuracy. Reports word error
rate (WER) and insertion rate (inserted words / ref words = hallucination
proxy), aggregated micro-average per condition.
"""
import json, os, re, sys, glob
from collections import defaultdict

def norm(s):
    s = s.lower()
    s = re.sub(r"[^a-z0-9' ]", " ", s)
    return s.split()

def edits(ref, hyp):
    """Levenshtein with S/D/I breakdown (word level)."""
    n, m = len(ref), len(hyp)
    d = [[0]*(m+1) for _ in range(n+1)]
    op = [[None]*(m+1) for _ in range(n+1)]
    for i in range(n+1): d[i][0] = i; op[i][0] = "D"
    for j in range(m+1): d[0][j] = j; op[0][j] = "I"
    op[0][0] = None
    for i in range(1, n+1):
        for j in range(1, m+1):
            if ref[i-1] == hyp[j-1]:
                d[i][j] = d[i-1][j-1]; op[i][j] = "="
            else:
                sub, dele, ins = d[i-1][j-1], d[i-1][j], d[i][j-1]
                best = min(sub, dele, ins)
                d[i][j] = best + 1
                op[i][j] = "S" if best == sub else ("D" if best == dele else "I")
    i, j = n, m
    S = D = I = 0
    while i > 0 or j > 0:
        o = op[i][j]
        if o == "=": i -= 1; j -= 1
        elif o == "S": S += 1; i -= 1; j -= 1
        elif o == "D": D += 1; i -= 1
        else: I += 1; j -= 1
    return S, D, I

def parse(path):
    b = os.path.basename(path)[:-4]
    if "__" not in b:
        return b, "clean", "none", "na"
    id_, cond, noise, snr = b.split("__")
    return id_, cond, noise, snr.replace("snr", "")

def load(fn):
    out = {}
    if not os.path.exists(fn): return out
    for line in open(fn):
        line = line.strip()
        if not line: continue
        o = json.loads(line)
        out[o["path"]] = o["text"]
    return out

v3 = load("out_v3.jsonl")
for extra in ["out_rnnoise.jsonl", "out_dfn.jsonl", "out_denoise.jsonl"]:   # learned-denoiser conditions, same v3 engine
    v3.update(load(extra))
vad = load("out_vad.jsonl")
v2 = load("out_v2.jsonl")

# references from clean-v3
ref3 = {}
for p, t in v3.items():
    id_, cond, _, _ = parse(p)
    if cond == "clean": ref3[id_] = norm(t)

def agg(items, refmap, condlabel=None):
    """items: list of (path,text). returns bucket->(S,D,I,refwords)."""
    buckets = defaultdict(lambda: [0,0,0,0])
    for p, t in items:
        id_, cond, noise, snr = parse(p)
        if cond == "clean": continue
        if id_ not in refmap: continue
        S,D,I = edits(refmap[id_], norm(t))
        key = (condlabel or cond, noise, snr)
        b = buckets[key]; b[0]+=S; b[1]+=D; b[2]+=I; b[3]+=len(refmap[id_])
    return buckets

buckets = agg(v3.items(), ref3)
for k,v in agg(vad.items(), ref3, condlabel="vad").items():
    buckets[k] = v

def wer(b): S,D,I,N = b; return (S+D+I)/N if N else 0
def insr(b): S,D,I,N = b; return I/N if N else 0

print(f"clips={len(ref3)}  ref words(clean-v3)={sum(len(w) for w in ref3.values())}\n")
order = {"noisy":0,"hpf":1,"afftdn":2,"anlmdn":3,"vad":4}
print(f"{'condition':10} {'noise':6} {'snr':>3}  {'WER':>7}  {'ins/ref':>7}")
print("-"*44)
for (cond,noise,snr) in sorted(buckets, key=lambda k:(k[1],k[2],order.get(k[0],9))):
    b = buckets[(cond,noise,snr)]
    print(f"{cond:10} {noise:6} {snr:>3}  {wer(b)*100:6.1f}%  {insr(b)*100:6.1f}%")

# ---- v2 vs v3 ----
if v2:
    print("\n=== model: v2 vs v3 ===")
    ref2 = {}
    for p,t in v2.items():
        id_,cond,_,_ = parse(p)
        if cond=="clean": ref2[id_]=norm(t)
    # clean v2 vs clean v3 (absolute divergence between checkpoints)
    S=D=I=N=0
    for id_ in ref3:
        if id_ in ref2:
            s,dd,i = edits(ref3[id_], ref2[id_]); S+=s;D+=dd;I+=i;N+=len(ref3[id_])
    print(f"clean: v2 differs from v3 by {100*(S+D+I)/N:.1f}% WER (checkpoint divergence)")
    # noise degradation water@5 under each engine
    def deg(vmap, refmap, tag):
        b=[0,0,0,0]
        for p,t in vmap.items():
            id_,cond,noise,snr = parse(p)
            if cond=="noisy" and noise=="water" and snr=="05" and id_ in refmap:
                s,dd,i=edits(refmap[id_],norm(t)); b[0]+=s;b[1]+=dd;b[2]+=i;b[3]+=len(refmap[id_])
        print(f"  {tag} water@5 noisy vs its own clean: WER {wer(b)*100:.1f}%  ins {insr(b)*100:.1f}%")
    deg(v3, ref3, "v3")
    deg(v2, ref2, "v2")
