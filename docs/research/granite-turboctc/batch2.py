import csv, os, sys, time, json, subprocess
import numpy as np, soundfile as sf, torch
from transformers import AutoModelForCTC, AutoProcessor

MID="ibm-granite/granite-speech-5.0-470m-turboctc"
START=int(sys.argv[1]); END=int(sys.argv[2]); OUT=sys.argv[3]

def load16k(path):
    try:
        a,sr=sf.read(path,dtype='float32')
        if a.ndim>1: a=a.mean(1)
        if sr!=16000: raise ValueError("resample")
        return a
    except Exception:
        p=subprocess.run(["ffmpeg","-v","quiet","-i",path,"-f","f32le","-ac","1","-ar","16000","-"],
                         capture_output=True)
        if p.returncode!=0 or not p.stdout: return None
        return np.frombuffer(p.stdout,dtype=np.float32).copy()

proc=AutoProcessor.from_pretrained(MID)
model=AutoModelForCTC.from_pretrained(MID, dtype=torch.float32).to("mps").eval()

def ascii_ratio(s): return sum(c.isascii() for c in s)/len(s) if s else 0
rows=[]
for r in csv.DictReader(open('/Users/vsriram/Desktop/jot-recordings.csv')):
    tx=(r['transcript'] or '').strip()
    if not tx: continue
    wc=len(tx.split())
    if wc<8 or wc>60: continue
    if ascii_ratio(tx)<0.98: continue
    if not os.path.isfile(r['audio_file']): continue
    rows.append(r)
sel=rows[START:END]
print(f"eligible={len(rows)} slice={START}:{END} -> {len(sel)}",file=sys.stderr)

f=open(OUT,"w"); tot_a=tot_t=0.0; skipped=0
for k,r in enumerate(sel):
    a=load16k(r['audio_file'])
    if a is None or len(a)<1600: skipped+=1; continue
    dur=len(a)/16000
    t0=time.time()
    inp=proc([a],sampling_rate=16000).to("mps")
    with torch.no_grad(): out=model.generate(**inp)
    txt=proc.batch_decode(out,skip_special_tokens=True)[0]
    el=time.time()-t0
    tot_a+=dur; tot_t+=el
    f.write(json.dumps({"id":os.path.basename(r['audio_file']),"dur":dur,"sec":el,
                        "granite":txt,"jot":r['transcript']})+"\n"); f.flush()
    if k%25==0: print(f"  {k}/{len(sel)} RTFx={tot_a/max(tot_t,1e-9):.0f}x skipped={skipped}",file=sys.stderr)
f.close()
print(f"DONE n={len(sel)-skipped} skipped={skipped} audio={tot_a:.1f}s compute={tot_t:.1f}s RTFx={tot_a/tot_t:.1f}x",file=sys.stderr)
