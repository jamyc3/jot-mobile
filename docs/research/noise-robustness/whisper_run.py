#!/usr/bin/env python3
"""Transcribe clean + noisy clips with Whisper small.en (one model load).
Whisper was trained on 680k h of diverse/noisy web audio — the point is to
see whether it degrades LESS in noise than Parakeet, which would demonstrate
that a noise-robust *checkpoint* (not a front-end) is the real fix."""
import glob, json, os, subprocess, time

MODEL = "models/ggml-small.en.bin"
files = sorted(glob.glob("clean/*.wav")) + sorted(glob.glob("proc/*__noisy__*.wav"))
print(f"transcribing {len(files)} files with whisper small.en…")

t = time.time()
# -otxt writes <input>.txt beside each input; one model load for all files.
subprocess.run(["whisper-cli", "-m", MODEL, "-otxt", "-np", "-nt", *files],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f"whisper done in {time.time()-t:.0f}s")

out = []
missing = 0
for f in files:
    txt = f + ".txt"
    if os.path.exists(txt):
        text = open(txt).read().strip().replace("\n", " ")
    else:
        text = ""; missing += 1
    out.append(json.dumps({"path": f, "text": text}))
open("out_whisper.jsonl", "w").write("\n".join(out) + "\n")
print(f"wrote out_whisper.jsonl ({len(out)} lines, {missing} missing sidecars)")
