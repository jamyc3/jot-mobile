import warnings,subprocess,numpy as np,torch,json,time,os; warnings.filterwarnings("ignore")
from transformers import AutoModel, AutoProcessor
MID="nvidia/nemotron-3.5-asr-streaming-0.6b"
proc=AutoProcessor.from_pretrained(MID)
model=AutoModel.from_pretrained(MID,dtype=torch.float32).to("mps").eval()
REC="/Users/vsriram/Library/Application Support/Jot/Recordings/"
rows=[json.loads(l) for l in open("granite_all.jsonl")]
def load(p):
    q=subprocess.run(["ffmpeg","-v","quiet","-i",p,"-f","f32le","-ac","1","-ar","16000","-"],capture_output=True)
    if q.returncode!=0 or not q.stdout: return None
    return np.frombuffer(q.stdout,dtype=np.float32).copy()
a=load(REC+rows[0]["id"])
i=proc([a],sampling_rate=16000,return_tensors="pt"); i={k:(v.to("mps") if hasattr(v,'to') else v) for k,v in i.items()}
with torch.no_grad(): model.generate(**i)
out=open("nemo_all.jsonl","w"); ta=tt=0.0
for k,r in enumerate(rows):
    a=load(REC+r["id"])
    if a is None or len(a)<1600: continue
    t0=time.time()
    i=proc([a],sampling_rate=16000,return_tensors="pt"); i={k2:(v.to("mps") if hasattr(v,'to') else v) for k2,v in i.items()}
    with torch.no_grad(): o=model.generate(**i)
    txt=proc.batch_decode(o.sequences,skip_special_tokens=True)[0]
    el=time.time()-t0; ta+=len(a)/16000; tt+=el
    r["nemotron"]=txt; r["nemo_sec"]=el
    out.write(json.dumps(r)+"\n"); out.flush()
    if k%50==0: print(f"  {k}/{len(rows)} RTFx={ta/max(tt,1e-9):.0f}x",flush=True)
out.close()
print(f"DONE audio={ta:.0f}s compute={tt:.0f}s RTFx={ta/tt:.0f}x")
