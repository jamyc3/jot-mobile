import json,re,warnings; warnings.filterwarnings("ignore")
rows=[json.loads(l) for l in open("variants2.jsonl")]
KEYS=["parakeet","parakeet_pcs","nemotron_en","nemotron_en_pcs_ontop","granite","granite_pcs"]
CONTR=re.compile(r"\b\w+'(m|re|ve|ll|d|s|t)\b",re.I)
print(f"{'variant':22}{'caps%':>7}{'punct%':>8}{'contr':>7}{'sent/100w':>11}{'marks/100w':>12}{'words':>8}")
for k in KEYS:
    n=len(rows); w=sum(len(r[k].split()) for r in rows)
    caps=sum(bool(re.search(r'[A-Z]',r[k])) for r in rows)/n*100
    pun=sum(bool(re.search(r'[.,?!]',r[k])) for r in rows)/n*100
    ct=sum(len(CONTR.findall(r[k])) for r in rows)
    se=sum(len(re.findall(r'[.?!]',r[k])) for r in rows)/w*100
    mk=sum(len(re.findall(r'[.,?!]',r[k])) for r in rows)/w*100
    print(f"{k:22}{caps:>6.0f}%{pun:>7.0f}%{ct:>7}{se:>11.2f}{mk:>12.2f}{w:>8}")
