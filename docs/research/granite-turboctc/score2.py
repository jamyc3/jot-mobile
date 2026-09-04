import json,re,warnings; warnings.filterwarnings("ignore")
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer
norm=EnglishTextNormalizer()
rows=[json.loads(l) for l in open("granite_pcs.jsonl")]
n=len(rows)
COLS=[("Jot/Parakeet","jot"),("Granite raw","granite"),("Granite+PCS","granite_pcs")]
up=lambda s: bool(re.search(r'[A-Z]',s)); pu=lambda s: bool(re.search(r'[.,?!;:]',s))
CONTR=re.compile(r"\b\w+'(m|re|ve|ll|d|s|t)\b",re.I)

print("FORMATTING")
print(f"{'':16}{'has caps':>10}{'has punct':>11}{'contractions':>14}{'sentences/clip':>16}")
for lab,k in COLS:
    c=sum(up(r[k]) for r in rows); q=sum(pu(r[k]) for r in rows)
    ct=sum(len(CONTR.findall(r[k])) for r in rows)
    sent=sum(len(re.findall(r'[.?!]',r[k])) for r in rows)/n
    print(f"{lab:16}{c/n:>9.0%}{q/n:>11.0%}{ct:>14}{sent:>16.1f}")

print("\nDIVERGENCE FROM JOT'S SHIPPED OUTPUT")
print(f"{'':16}{'normalized':>12}{'UNnormalized':>14}")
for lab,k in COLS[1:]:
    R=[norm(r['jot']) for r in rows]; H=[norm(r[k]) for r in rows]
    pr=[(a,b) for a,b in zip(R,H) if a.strip() and b.strip()]
    nw=jiwer.process_words([x[0] for x in pr],[x[1] for x in pr]).wer*100
    rw=jiwer.process_words([r['jot'] for r in rows],[r[k] for r in rows]).wer*100
    print(f"{lab:16}{nw:>11.1f}%{rw:>13.1f}%")

print("\nACRONYM RECOVERY (81 ALL-CAPS acronyms in Jot's output)")
ACRO=re.compile(r'\b[A-Z]{2,6}\b'); STOP={"I","A","OK","TV"}
for lab,k in COLS[1:]:
    exact=lower=miss=0
    for r in rows:
        for a in set(ACRO.findall(r['jot'])):
            if a in STOP: continue
            t=r[k]
            if re.search(r'\b'+re.escape(a)+r'\b',t): exact+=1
            elif a.lower() in t.lower(): lower+=1
            else: miss+=1
    tot=exact+lower+miss
    print(f"  {lab:14} exact ALL-CAPS match {exact:3d}/{tot} ({exact/tot:.0%})   right letters wrong case {lower:3d}   wrong letters {miss:3d}")

print("\n=== SIDE BY SIDE (first 8 clips) ===")
for r in rows[:8]:
    print(f"\n  JOT : {r['jot'][:150]}")
    print(f"  RAW : {r['granite'][:150]}")
    print(f"  PCS : {r['granite_pcs'][:150]}")
