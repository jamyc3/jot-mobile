#!/usr/bin/env python3
"""Granite on the SAME noise matrix as the 2026-07 Jot noise-robustness study.

Replicates choose_set.py selection, preprocess.py wind/water synthesis and
add_fan.py fan synthesis (same seeds, same active-RMS SNR mixing), then scores
degradation vs the model's OWN clean output -- the exact metric RESULTS.txt
reports for Parakeet, so the two are directly comparable.
"""
import csv, os, sys, json, subprocess, wave, warnings, time
warnings.filterwarnings("ignore")
import numpy as np, torch, jiwer
from transformers import AutoModelForCTC, AutoProcessor
from whisper_normalizer.english import EnglishTextNormalizer
norm=EnglishTextNormalizer()
SR=16000; N=36

def colored_noise(rng,n,beta):
    X=np.fft.rfft(rng.standard_normal(n)); f=np.arange(len(X)); f[0]=1
    y=np.fft.irfft(X/(f**(beta/2.0)),n=n); return y/(np.std(y)+1e-12)
def moving_avg(x,k):
    k=min(k,len(x)); c=np.cumsum(np.insert(x,0,0.0)); ma=(c[k:]-c[:-k])/k
    pad=len(x)-len(ma); l=pad//2
    return np.concatenate([np.full(l,ma[0]),ma,np.full(pad-l,ma[-1])])
def make_wind(rng,n):
    base=colored_noise(rng,n,2.0); lfo=np.abs(colored_noise(rng,n,2.0)); lfo/=(lfo.max()+1e-9)
    return (lambda y:y/(np.std(y)+1e-12))(base*(0.4+0.6*moving_avg(lfo,SR)))
def make_water(rng,n):
    y=colored_noise(rng,n,1.0); k=64
    y=y-0.9*np.convolve(y,np.ones(k)/k,mode="same"); return y/(np.std(y)+1e-12)
def make_fan(rng,n):
    bb=colored_noise(rng,n,0.9); t=np.arange(n)/SR
    hum=(0.5*np.sin(2*np.pi*60*t)+0.3*np.sin(2*np.pi*120*t)+0.15*np.sin(2*np.pi*180*t))
    hum/=(np.std(hum)+1e-12); y=bb+0.35*hum; return y/(np.std(y)+1e-12)
def active_rms(x):
    p=np.abs(x).max(); v=x[np.abs(x)>0.12*p] if p>0 else x
    if v.size<SR//5: v=x
    return np.sqrt(np.mean(v**2))+1e-12
def mix(c,nz,snr):
    tn=active_rms(c)/(10**(snr/20.0)); return c+nz*(tn/(np.sqrt(np.mean(nz**2))+1e-12))

def load16k(path):
    p=subprocess.run(["ffmpeg","-nostdin","-v","quiet","-i",path,"-f","f32le","-ac","1","-ar",str(SR),"-"],capture_output=True)
    if p.returncode!=0 or not p.stdout: return None
    return np.frombuffer(p.stdout,dtype=np.float32).astype(np.float64).copy()

# --- same selection as choose_set.py ---
def ascii_ratio(s): return sum(c.isascii() for c in s)/len(s) if s else 0
rows=[]
for r in csv.DictReader(open(os.path.expanduser('~/Desktop/jot-recordings.csv'))):
    tx=(r['transcript'] or '').strip()
    if not tx: continue
    wc=len(tx.split())
    if wc<8 or wc>60 or ascii_ratio(tx)<0.98: continue
    if not os.path.isfile(r['audio_file']): continue
    rows.append((os.path.splitext(os.path.basename(r['audio_file']))[0], r['audio_file'], tx))
rows.sort(key=lambda x:x[0]); step=max(1,len(rows)//N); picked=rows[::step][:N]
print(f"candidates={len(rows)} picked={len(picked)}",file=sys.stderr)

MID="ibm-granite/granite-speech-5.0-470m-turboctc"
proc=AutoProcessor.from_pretrained(MID)
model=AutoModelForCTC.from_pretrained(MID,dtype=torch.float32).to("mps").eval()
def tx(a):
    inp=proc([a.astype(np.float32)],sampling_rate=SR).to("mps")
    with torch.no_grad(): out=model.generate(**inp)
    return proc.batch_decode(out,skip_special_tokens=True)[0]

res={}   # (noise,snr) -> list of (clean_text, noisy_text)
clean_store={}
rng_w=np.random.default_rng(1234); rng_f=np.random.default_rng(4242)
t0=time.time()
for i,(id_,path,jot) in enumerate(picked):
    x=load16k(path)
    if x is None or len(x)<SR//2: continue
    c=tx(x); clean_store[id_]=(c,jot)
    for noise,maker,rng in (("wind",make_wind,rng_w),("water",make_water,rng_w),("fan",make_fan,rng_f)):
        bed=maker(rng,len(x))
        for snr in (10,5):
            res.setdefault((noise,snr),[]).append((c,tx(mix(x,bed,snr))))
    if i%6==0: print(f"  {i}/{len(picked)} {time.time()-t0:.0f}s",file=sys.stderr)

def wer(refs,hyps):
    R=[norm(r) for r in refs]; H=[norm(h) for h in hyps]
    keep=[(r,h) for r,h in zip(R,H) if r.strip()]
    if not keep: return float('nan')
    return jiwer.process_words([k[0] for k in keep],[k[1] if k[1].strip() else "@" for k in keep]).wer*100

# sanity: Granite clean vs Jot clean
print(f"\nGranite clean vs Jot/Parakeet clean (normalized): {wer([v[1] for v in clean_store.values()],[v[0] for v in clean_store.values()]):.1f}%")
PARAKEET={("fan",10):15.5,("fan",5):34.3,("water",10):25.8,("water",5):58.0,("wind",10):1.7,("wind",5):2.8}
print(f"\n=== DEGRADATION vs OWN CLEAN OUTPUT (n={len(picked)} clips) ===")
print(f"{'noise':8}{'snr':>5}{'Granite':>10}{'Parakeet*':>11}   winner")
print("-"*52)
out={}
for noise in ("wind","fan","water"):
    for snr in (10,5):
        v=res[(noise,snr)]; g=wer([a for a,b in v],[b for a,b in v]); out[f"{noise}{snr}"]=g
        p=PARAKEET[(noise,snr)]; d=g-p
        w="Granite" if d<-1 else ("Parakeet" if d>1 else "tie")
        print(f"{noise:8}{snr:>5}{g:>9.1f}%{p:>10.1f}%   {w} ({d:+.1f})")
print("\n* Parakeet numbers from docs/research/noise-robustness/RESULTS.txt (2026-07, same synthesis+metric).")
json.dump({"granite":out,"parakeet":{f"{k[0]}{k[1]}":v for k,v in PARAKEET.items()}},open("noise_granite.json","w"),indent=1)
