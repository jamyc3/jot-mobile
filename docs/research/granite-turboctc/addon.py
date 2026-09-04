import json,random,re,warnings; warnings.filterwarnings("ignore")
from pcs import Punctuator
from strip import strip_fmt
p=Punctuator()
nv={json.loads(l)["id"]:json.loads(l) for l in open("nemoen_all.jsonl")}
gj={json.loads(l)["id"]:json.loads(l) for l in open("granite_vs_new.jsonl")}
rows=[]
for i,r in nv.items():
    g=gj.get(i)
    if not g: continue
    rows.append({"id":i,
      "parakeet_addon": p(strip_fmt(g["jot_new"])),
      "nemotron_addon": p(strip_fmt(r["nemotron_en"].strip())),
      "granite_addon":  p(g["granite"])})
json.dump(rows,open("addon.json","w"))
print("clips:",len(rows))
KEYS=["parakeet_addon","nemotron_addon","granite_addon"]
CONTR=re.compile(r"\b\w+'(m|re|ve|ll|d|s|t)\b",re.I)
DIG=re.compile(r'\b\d[\d,]*\b'); WN=re.compile(r'\b(one|two|three|four|five|six|seven|eight|nine|ten|twenty|thirty|hundred|thousand|million|billion)\b',re.I)
BIG=re.compile(r'\b\d{5,}\b')
print(f"\n{'ALL THREE WITH THE ADD-ON':30}{'contractions':>14}{'marks/100w':>12}{'% digits':>10}{'runaway':>9}")
for k in KEYS:
    w=sum(len(r[k].split()) for r in rows)
    d=sum(len(DIG.findall(r[k])) for r in rows); ww=sum(len(WN.findall(r[k])) for r in rows)
    print(f"  {k:28}{sum(len(CONTR.findall(r[k])) for r in rows):>14}"
          f"{sum(len(re.findall(r'[.,?!]',r[k])) for r in rows)/w*100:>12.1f}"
          f"{d/(d+ww)*100:>9.0f}%{sum(1 for r in rows if BIG.search(r[k])):>9}")
# blind judging file
random.seed(21)
sel=[r for r in rows if len(r["parakeet_addon"].split())>=15]
random.shuffle(sel); sel=sel[:50]
keymap={}
with open("judge_C.txt","w") as f:
    f.write("""# BLIND COMPARISON — TASK C

Each clip shows the same audio transcribed by three different systems, each then passed
through the SAME punctuation/capitalization model. The words differ slightly between them -
IGNORE word accuracy entirely.

Judge ONLY the FORMATTING quality for a speech-to-text dictation app whose output is pasted
straight into chat messages, code comments and tickets. Consider: sentence boundaries, comma
placement, over/under-punctuation, capitalization of proper nouns, whether contractions read
naturally, and whether numbers are rendered sensibly.

======================================================================
""")
    for i,r in enumerate(sel,1):
        ks=KEYS[:]; random.shuffle(ks)
        keymap[str(i)]={chr(65+j):k for j,k in enumerate(ks)}
        f.write(f"\n### CLIP {i}\n")
        for j,k in enumerate(ks): f.write(f"  {chr(65+j)}: {r[k].strip()}\n")
json.dump(keymap,open("judge_C.txt.key","w"))
print(f"\njudge_C.txt: {len(sel)} clips x 3")
