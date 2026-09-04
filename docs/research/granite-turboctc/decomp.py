import json,re,warnings; warnings.filterwarnings("ignore")
import jiwer
rows=[json.loads(l) for l in open("granite_pcs.jsonl")]

# contraction expansion map (apply to BOTH sides -> neutralises the axis)
EXP=[(r"\bcan't\b","can not"),(r"\bwon't\b","will not"),(r"\bn't\b"," not"),
     (r"\b(i)'m\b",r"\1 am"),(r"\b(\w+)'re\b",r"\1 are"),(r"\b(\w+)'ve\b",r"\1 have"),
     (r"\b(\w+)'ll\b",r"\1 will"),(r"\blet's\b","let us"),(r"\b(it|that|there|he|she|what|who)'s\b",r"\1 is"),
     (r"\b(\w+)'d\b",r"\1 would")]
def decontract(s):
    s=s.lower()
    for a,b in EXP: s=re.sub(a,b,s)
    return s
def strippunct(s): return re.sub(r"[.,?!;:\"]"," ",s)
def clean(s): return " ".join(s.split())

def wer(f_jot,f_hyp,key):
    R=[clean(f_jot(r['jot'])) for r in rows]; H=[clean(f_hyp(r[key])) for r in rows]
    p=[(a,b) for a,b in zip(R,H) if a.strip() and b.strip()]
    return jiwer.process_words([x[0] for x in p],[x[1] for x in p]).wer*100

ident=lambda s:s
low=lambda s:s.lower()
for key,lab in (("granite_pcs","Granite+PCS"),):
    print(f"DECOMPOSITION of the {lab} vs Jot difference\n")
    a=wer(ident,ident,key);                                            print(f"  raw, as the user would see it                 {a:5.1f}%")
    b=wer(low,low,key);                                                print(f"  ignore CASING                                 {b:5.1f}%   (-{a-b:.1f})")
    c=wer(lambda s:strippunct(s.lower()),lambda s:strippunct(s.lower()),key)
    print(f"  ignore casing + PUNCTUATION                   {c:5.1f}%   (-{b-c:.1f})")
    d=wer(lambda s:strippunct(decontract(s)),lambda s:strippunct(decontract(s)),key)
    print(f"  ignore casing + punct + CONTRACTIONS          {d:5.1f}%   (-{c-d:.1f})")
    print(f"\n  -> remaining {d:.1f}% is genuine word difference (numbers/ITN + real ASR errors)")

# over-segmentation / over-capitalisation
w=lambda s:len(s.split())
jw=sum(w(r['jot']) for r in rows); gw=sum(w(r['granite_pcs']) for r in rows)
js=sum(len(re.findall(r'[.?!]',r['jot'])) for r in rows); gs=sum(len(re.findall(r'[.?!]',r['granite_pcs'])) for r in rows)
jc=sum(len(re.findall(r'[.,?!]',r['jot'])) for r in rows); gc=sum(len(re.findall(r'[.,?!]',r['granite_pcs'])) for r in rows)
print(f"\nSENTENCE / PUNCT DENSITY per 100 words")
print(f"  Jot/Parakeet : {js/jw*100:5.2f} sentence enders, {jc/jw*100:5.2f} punctuation marks")
print(f"  Granite+PCS  : {gs/gw*100:5.2f} sentence enders, {gc/gw*100:5.2f} punctuation marks  ({gs/jw*jw/js/ (gw/jw):.1f}x Jot's rate)")

# mid-sentence capitalisation (proper-noun invention)
def midcaps(t):
    toks=t.split(); out=0
    for i,x in enumerate(toks):
        if i==0: continue
        if re.match(r'^[A-Z][a-z]+$',x) and not re.search(r'[.?!]$',toks[i-1]): out+=1
    return out
print(f"\nMID-SENTENCE CAPITALISED WORDS (proper-noun invention)")
print(f"  Jot/Parakeet : {sum(midcaps(r['jot']) for r in rows)}")
print(f"  Granite+PCS  : {sum(midcaps(r['granite_pcs']) for r in rows)}")
