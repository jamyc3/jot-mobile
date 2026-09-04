import json,re,warnings; warnings.filterwarnings("ignore")
rows=[json.loads(l) for l in open("granite_all.jsonl")]
ACRO=re.compile(r'\b[A-Z]{2,6}\b')
STOP={"I","A","OK","TV"}
hit=miss=0; ex=[]
for r in rows:
    for a in set(ACRO.findall(r['jot'])):
        if a in STOP: continue
        g=r['granite'].lower()
        if a.lower() in g.split() or a.lower() in g:
            hit+=1
        else:
            miss+=1
            if len(ex)<14: ex.append((a,r['jot'][:85],r['granite'][:85]))
print(f"ALL-CAPS acronyms in Jot output: {hit+miss} occurrences across 420 clips")
print(f"  Granite reproduced the same letters (lowercased): {hit} ({hit/(hit+miss):.0%})")
print(f"  Granite produced something else                 : {miss} ({miss/(hit+miss):.0%})")
print("\n  examples where Granite differs:")
for a,j,g in ex: print(f"    [{a}]  JOT: {j}\n           GRA: {g}")
