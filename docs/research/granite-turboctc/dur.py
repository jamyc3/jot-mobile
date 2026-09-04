import json,warnings; warnings.filterwarnings("ignore")
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer
norm=EnglishTextNormalizer()
rows=[json.loads(l) for l in open("granite_all.jsonl")]
B=[(0,5),(5,10),(10,20),(20,40),(40,1e9)]
print(f"{'duration':>12}{'clips':>7}{'norm WER':>10}{'del%':>8}{'ins%':>8}  (Granite vs Jot, Jot as ref)")
print("-"*60)
for lo,hi in B:
    sel=[r for r in rows if lo<=r['dur']<hi]
    if not sel: continue
    R=[norm(r['jot']) for r in sel]; H=[norm(r['granite']) for r in sel]
    p=[(a,b) for a,b in zip(R,H) if a.strip() and b.strip()]
    o=jiwer.process_words([x[0] for x in p],[x[1] for x in p])
    tot=o.hits+o.substitutions+o.deletions
    lab=f"{lo}-{hi}s" if hi<1e9 else f"{lo}s+"
    print(f"{lab:>12}{len(sel):>7}{o.wer*100:>9.1f}%{o.deletions/tot*100:>7.1f}%{o.insertions/tot*100:>7.1f}%")
# total audio / speed
print(f"\ntotal audio {sum(r['dur'] for r in rows)/60:.0f} min, compute {sum(r['sec'] for r in rows):.0f}s, RTFx {sum(r['dur'] for r in rows)/sum(r['sec'] for r in rows):.0f}x (M2 Pro, fp32, MPS)")
