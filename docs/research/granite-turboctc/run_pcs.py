import json, time
from pcs import Punctuator
p=Punctuator()
rows=[json.loads(l) for l in open("granite_all.jsonl")]
# warm
p(rows[0]["granite"])
t0=time.time(); tot_chars=0
out=open("granite_pcs.jsonl","w")
for i,r in enumerate(rows):
    t1=time.time()
    r["granite_pcs"]=p(r["granite"])
    r["pcs_sec"]=time.time()-t1
    tot_chars+=len(r["granite"])
    out.write(json.dumps(r)+"\n")
    if i%100==0: print(f"  {i}/{len(rows)}", flush=True)
out.close()
el=time.time()-t0
print(f"DONE {len(rows)} transcripts in {el:.1f}s = {el/len(rows)*1000:.0f} ms/transcript (CPU, onnxruntime)")
