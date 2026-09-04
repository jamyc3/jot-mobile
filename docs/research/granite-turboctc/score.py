import json, re, sys, warnings
warnings.filterwarnings("ignore")
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer
norm=EnglishTextNormalizer()

rows=[json.loads(l) for l in open(sys.argv[1] if len(sys.argv)>1 else "granite_real.jsonl")]
print(f"clips={len(rows)}  audio={sum(r['dur'] for r in rows)/60:.1f} min  compute={sum(r['sec'] for r in rows):.1f}s  RTFx={sum(r['dur'] for r in rows)/sum(r['sec'] for r in rows):.0f}x\n")

# ---------- 1. formatting analysis (the product-relevant axis) ----------
def has_upper(s): return bool(re.search(r'[A-Z]', s))
def has_punct(s): return bool(re.search(r'[.,?!;:]', s))
g_up=sum(has_upper(r['granite']) for r in rows); j_up=sum(has_upper(r['jot']) for r in rows)
g_pu=sum(has_punct(r['granite']) for r in rows); j_pu=sum(has_punct(r['jot']) for r in rows)
n=len(rows)
print("FORMATTING (raw model output, no post-processing)")
print(f"  transcripts containing ANY capital letter : Jot/Parakeet {j_up:3d}/{n} ({j_up/n:.0%})   Granite {g_up:3d}/{n} ({g_up/n:.0%})")
print(f"  transcripts containing ANY punctuation    : Jot/Parakeet {j_pu:3d}/{n} ({j_pu/n:.0%})   Granite {g_pu:3d}/{n} ({g_pu/n:.0%})")

CONTR=re.compile(r"\b\w+'(m|re|ve|ll|d|s|t)\b", re.I)
g_c=sum(len(CONTR.findall(r['granite'])) for r in rows); j_c=sum(len(CONTR.findall(r['jot'])) for r in rows)
print(f"  contractions emitted (I'm, don't, we're) : Jot/Parakeet {j_c:4d}          Granite {g_c:4d}")

# ---------- 2. agreement on WORDS ----------
gs=[norm(r['granite']) for r in rows]; js=[norm(r['jot']) for r in rows]
pairs=[(j,g) for j,g in zip(js,gs) if j.strip() and g.strip()]
J=[p[0] for p in pairs]; G=[p[1] for p in pairs]
out=jiwer.process_words(J,G)
print(f"\nWORD-LEVEL DIVERGENCE (Whisper/OpenASR normalization; Jot output as the reference)")
print(f"  normalized WER = {out.wer*100:.1f}%   sub={out.substitutions} del={out.deletions} ins={out.insertions} hits={out.hits}")
raw=jiwer.process_words([r['jot'] for r in rows],[r['granite'] for r in rows])
print(f"  UNnormalized   = {raw.wer*100:.1f}%   <- what a user would actually see change")
print(f"  => {raw.wer*100-out.wer*100:.1f} points of the difference is pure casing/punctuation/number formatting")

# ---------- 3. per-clip disagreements ----------
scored=[]
for r in rows:
    a,b=norm(r['jot']),norm(r['granite'])
    if not a.strip() or not b.strip(): continue
    w=jiwer.process_words([a],[b])
    scored.append((w.wer,len(a.split()),r))
scored.sort(key=lambda x:-x[0])
agree=sum(1 for s in scored if s[0]==0)
print(f"\n  clips where the two agree word-for-word (normalized): {agree}/{len(scored)} ({agree/len(scored):.0%})")
print(f"\n=== 12 LARGEST DISAGREEMENTS (for adjudication — neither is ground truth) ===")
for wer,nw,r in scored[:12]:
    print(f"\n[{wer*100:.0f}% diff, {nw}w, {r['dur']:.0f}s]")
    print(f"  JOT     : {r['jot'][:200]}")
    print(f"  GRANITE : {r['granite'][:200]}")
