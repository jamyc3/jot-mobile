import json,re
rows=[json.loads(l) for l in open("granite_pcs.jsonl")]
def dens(r):
    w=len(r['granite_pcs'].split())
    return (len(re.findall(r'[.?!]',r['granite_pcs']))/w) if w>12 else 0
rows.sort(key=dens,reverse=True)
print("=== WORST OVER-SEGMENTATION (PCS chopping mid-clause) ===")
for r in rows[:5]:
    print(f"\n  JOT : {r['jot'][:170]}")
    print(f"  PCS : {r['granite_pcs'][:170]}")
print("\n\n=== INVENTED PROPER NOUNS (mid-sentence caps PCS added) ===")
seen=0
for r in rows:
    toks=r['granite_pcs'].split()
    bad=[x for i,x in enumerate(toks) if i>0 and re.match(r'^[A-Z][a-z]+$',x)
         and not re.search(r'[.?!]$',toks[i-1]) and x.lower() not in r['jot'].lower().split()[:0]+[]
         and x not in r['jot']]
    if len(bad)>=2 and seen<5:
        seen+=1
        print(f"\n  caps added: {bad[:6]}")
        print(f"  JOT : {r['jot'][:150]}")
        print(f"  PCS : {r['granite_pcs'][:150]}")
