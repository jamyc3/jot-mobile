import json,random,re
random.seed(7)
rows=[json.loads(l) for l in open("variants2.jsonl")]
rows=[r for r in rows if len(r["parakeet"].split())>=15 and all(r.get(k,"").strip() for k in
      ("parakeet","parakeet_pcs","nemotron_en","granite_pcs"))]
random.shuffle(rows); sel=rows[:50]

def build(path,keys,title,instr):
    keymap={}
    with open(path,"w") as f:
        f.write(title+"\n\n"+instr+"\n\n"+"="*70+"\n")
        for i,r in enumerate(sel,1):
            ks=keys[:]; random.shuffle(ks)
            keymap[str(i)]={chr(65+j):k for j,k in enumerate(ks)}
            f.write(f"\n### CLIP {i}\n")
            for j,k in enumerate(ks):
                f.write(f"  {chr(65+j)}: {r[k].strip()}\n")
        f.write("\n"+"="*70+"\n")
    json.dump(keymap,open(path+".key","w"),indent=0)
    print(f"{path}: {len(sel)} clips x {len(keys)} variants")

build("judge_A.txt",["parakeet","parakeet_pcs"],
"# BLIND PUNCTUATION COMPARISON — TASK A",
"""Each clip below shows the SAME transcript twice. The WORDS ARE IDENTICAL.
Only the punctuation and capitalization differ.

Judge ONLY punctuation and capitalization quality for a speech-to-text dictation
app whose output is pasted straight into chat messages, code comments and tickets.
Consider: correct sentence boundaries, comma placement, not over- or
under-punctuating, correct capitalization of proper nouns and sentence starts.

Do NOT judge word accuracy, grammar, or content - the words are identical.""")

build("judge_B.txt",["parakeet","nemotron_en","granite_pcs"],
"# BLIND TRANSCRIPT COMPARISON — TASK B",
"""Each clip below shows the same audio transcribed by three different systems.
The words may differ slightly - IGNORE that. 

Judge ONLY the FORMATTING quality for a speech-to-text dictation app whose output
is pasted straight into chat messages, code comments and tickets. Consider:
sentence boundaries, comma placement, over/under-punctuation, capitalization of
proper nouns and sentence starts, and whether contractions read naturally.""")
