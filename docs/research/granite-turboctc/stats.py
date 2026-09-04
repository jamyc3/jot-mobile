import json,glob,os,math
from collections import Counter,defaultdict
def binom_p(k,n,p):  # two-sided-ish: P(X<=k) under Binom(n,p)
    return sum(math.comb(n,i)*p**i*(1-p)**(n-i) for i in range(k+1))

print("=== LETTER-POSITION CHECK (labels were shuffled PER CLIP) ===")
for task,keys,pnull in (("A",["parakeet","parakeet_pcs"],0.5),
                        ("B",["parakeet","nemotron_en","granite_pcs"],1/3)):
    key=json.load(open(f"judge_{task}.txt.key"))
    print(f"\n--- Task {task} ---")
    letters=Counter(); variants=Counter(); tot=0
    per_judge={}
    for f in sorted(glob.glob(f"judge_{task}_*.json")):
        name=os.path.basename(f).split("_")[-1].replace(".json","")
        v=json.load(open(f)); lc=Counter(); vc=Counter()
        for clip,letter in v.items():
            if clip not in key or letter=="TIE": continue
            lc[letter]+=1; vc[key[clip][letter]]+=1
        per_judge[name]=vc
        letters+=lc; variants+=vc; tot+=sum(vc.values())
        print(f"  {name:7} letters {dict(sorted(lc.items()))}  ->  variants " +
              " ".join(f"{k}={vc[k]}" for k in keys))
    print(f"\n  POOLED letters  : {dict(sorted(letters.items()))}   (near-even = judges were not picking a position)")
    print(f"  POOLED variants : " + "  ".join(f"{k}={variants[k]}" for k in keys) + f"   n={tot}")
    exp=tot*pnull
    best=max(keys,key=lambda k:variants[k]); worst=min(keys,key=lambda k:variants[k])
    sd=math.sqrt(tot*pnull*(1-pnull))
    z=(variants[best]-exp)/sd
    print(f"  expected per variant if judges were choosing at random: {exp:.1f} (sd {sd:.1f})")
    print(f"  '{best}' got {variants[best]}  ->  z = {z:+.1f}, p = {1-binom_p(variants[best]-1,tot,pnull):.2g}")

    # inter-judge agreement
    names=list(per_judge)
    files={n:json.load(open(f"judge_{task}_{n}.json")) for n in names}
    agree=0; n=0
    for clip in key:
        picks=[files[x].get(clip) for x in names]
        picks=[key[clip][p] for p in picks if p and p!="TIE" and p in key[clip]]
        if len(picks)==3:
            n+=1
            if len(set(picks))==1: agree+=1
    print(f"  all 3 judges picked the SAME variant on {agree}/{n} clips ({agree/n:.0%}; chance = {pnull**2:.0%})")
