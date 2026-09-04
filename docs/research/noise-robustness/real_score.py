#!/usr/bin/env python3
"""Score the two REAL recordings against hand-built ground-truth references."""
import json, os, re

REF = {
 "fan":   "Hi my name is Vineet Sriram and this is a test when there is a background noise with the exhaust on let's see how this goes hopefully you can hear me",
 "water": "My name is Vineet Sriram let's see how this one works this is the audio with water running let's see how it goes",
}
def norm(s): return re.sub(r"[^a-z0-9' ]", " ", s.lower()).split()

def edits(r, h):
    n, m = len(r), len(h)
    d=[[0]*(m+1) for _ in range(n+1)]; op=[[None]*(m+1) for _ in range(n+1)]
    for i in range(n+1): d[i][0]=i; op[i][0]="D"
    for j in range(m+1): d[0][j]=j; op[0][j]="I"
    op[0][0]=None
    for i in range(1,n+1):
        for j in range(1,m+1):
            if r[i-1]==h[j-1]: d[i][j]=d[i-1][j-1]; op[i][j]="="
            else:
                s,de,ins=d[i-1][j-1],d[i-1][j],d[i][j-1]; b=min(s,de,ins)
                d[i][j]=b+1; op[i][j]="S" if b==s else ("D" if b==de else "I")
    i,j=n,m; S=D=I=0
    while i>0 or j>0:
        o=op[i][j]
        if o=="=": i-=1;j-=1
        elif o=="S": S+=1;i-=1;j-=1
        elif o=="D": D+=1;i-=1
        else: I+=1;j-=1
    return S,D,I

def parse(p):
    b=os.path.basename(p)[:-4]
    if b in ("fan","water"): return b,"raw"
    name,cond=b.split("__"); return name,cond

rows={}   # (name,cond)->text
for l in open("out_real.jsonl"):
    o=json.loads(l); rows[parse(o["path"])]=o["text"]
for l in open("out_real_vad.jsonl"):
    o=json.loads(l); n,_=parse(o["path"]); rows[(n,"vad")]=o["text"]
for n in REF:
    t=f"real/raw/{n}.wav.txt"
    if os.path.exists(t): rows[(n,"whisper")]=open(t).read().strip().replace("\n"," ")

ORDER=["raw","vad","hpf","dfnmild","anlmdn","afftdn","rnnoise","dfn","whisper"]
LABEL={"raw":"Do nothing (baseline)","vad":"Skip-silence (VAD)","hpf":"High-pass filter",
 "dfnmild":"DeepFilterNet (mild)","anlmdn":"Denoiser anlmdn","afftdn":"Denoiser afftdn",
 "rnnoise":"RNNoise","dfn":"DeepFilterNet (full)","whisper":"Whisper (different model)"}

for name in ["fan","water"]:
    ref=norm(REF[name]); N=len(ref)
    print(f"\n=== REAL: {name}  (reference {N} words) ===")
    print(f"{'condition':26} {'WER':>6} {'ins':>4}  transcript")
    print("-"*100)
    base=None
    for cond in ORDER:
        if (name,cond) not in rows: continue
        S,D,I=edits(ref,norm(rows[(name,cond)])); wer=(S+D+I)/N*100
        if cond=="raw": base=wer
        d = "" if cond=="raw" else (f"  ({wer-base:+.0f})")
        print(f"{LABEL[cond]:26} {wer:5.0f}% {I:>4}  {rows[(name,cond)][:70]}{d}")
