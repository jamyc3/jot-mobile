import json,os,glob
from collections import Counter,defaultdict
for task,variants in (("A",["parakeet","parakeet_pcs"]),("B",["parakeet","nemotron_en","granite_pcs"])):
    key=json.load(open(f"judge_{task}.txt.key"))
    files=sorted(glob.glob(f"judge_{task}_*.json"))
    if not files: print(f"Task {task}: no verdicts yet"); continue
    print(f"\n=== TASK {task} — {len(files)} judges ===")
    per=defaultdict(Counter); votes=defaultdict(list)
    for f in files:
        name=os.path.basename(f).replace(f"judge_{task}_","").replace(".json","")
        try: v=json.load(open(f))
        except Exception as e: print(f"  {name}: unreadable ({e})"); continue
        c=Counter()
        for clip,letter in v.items():
            if clip not in key: continue
            if letter=="TIE": var="TIE"
            else: var=key[clip].get(letter)
            if var: c[var]+=1; votes[clip].append(var)
        print(f"  {name:8} " + "  ".join(f"{k}={c[k]}" for k in variants+["TIE"] if c[k]))
        for k,n in c.items(): per[k][name]=n
    # majority
    maj=Counter()
    for clip,vs in votes.items():
        if len(vs)<2: continue
        w,n=Counter(vs).most_common(1)[0]
        maj["split" if n==1 else w]+=1
    print(f"  MAJORITY across judges: " + "  ".join(f"{k}={v}" for k,v in maj.most_common()))
