import warnings,subprocess,numpy as np,torch,time; warnings.filterwarnings("ignore")
from transformers import AutoModelForCTC, AutoProcessor
MID="ibm-granite/granite-speech-5.0-470m-turboctc"
proc=AutoProcessor.from_pretrained(MID)
model=AutoModelForCTC.from_pretrained(MID,dtype=torch.float32).to("mps").eval()
p="/Users/vsriram/Library/Application Support/Jot/Recordings/D9F15908-3C9C-4834-B80E-94D76E1818D9.wav"
r=subprocess.run(["ffmpeg","-v","quiet","-i",p,"-f","f32le","-ac","1","-ar","16000","-"],capture_output=True)
a=np.frombuffer(r.stdout,dtype=np.float32).copy(); dur=len(a)/16000
inp=proc([a],sampling_rate=16000).to("mps")
with torch.no_grad(): o=model(**inp)
logits=o.logits if hasattr(o,'logits') else o[0]
print("logits shape:",tuple(logits.shape),"| audio",f"{dur:.1f}s")
T=logits.shape[1]; print(f"frames={T} -> {dur/T*1000:.1f} ms per frame ({T/dur:.1f} Hz)")
ids=logits.argmax(-1)[0].tolist()
tok=proc.tokenizer
# CTC collapse with frame index -> word start times
words=[];cur="";start=None;prev=-1
for i,t in enumerate(ids):
    if t!=prev and t!=0:
        s=tok.decode([t])
        if s.startswith(" ") and cur:
            words.append((cur,start)); cur=s.strip(); start=i
        else:
            if not cur: start=i
            cur+=s.strip() if not cur else s.replace(" ","")
    prev=t
if cur: words.append((cur,start))
print(f"\nrecovered {len(words)} words with frame-level starts; first 12:")
for w,f in words[:12]: print(f"   {f*dur/T:7.2f}s  {w}")
# latency for a typical dictation clip
for sec in (5,10,20):
    x=a[:16000*sec]
    i2=proc([x],sampling_rate=16000).to("mps")
    with torch.no_grad(): model.generate(**i2)
    t0=time.time()
    for _ in range(3):
        i2=proc([x],sampling_rate=16000).to("mps")
        with torch.no_grad(): model.generate(**i2)
    print(f"{sec:3d}s clip -> {(time.time()-t0)/3*1000:6.0f} ms  (M2 Pro fp32 MPS)")
