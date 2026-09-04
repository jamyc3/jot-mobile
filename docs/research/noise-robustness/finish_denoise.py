#!/usr/bin/env python3
"""Rename DFN-enhanced files + generate RNNoise variants + build manifest.
Pure-Python (single process) because the large bash loops hang in this shell.
"""
import glob, os, shutil, subprocess, time

man = []

# 1. DFN enhanced files are already rendered in dfn_full/ and dfn_mild/;
#    copy them into proc/ under the {cond} naming score.py expects.
for src_dir, cond in [("dfn_full", "dfn"), ("dfn_mild", "dfnmild")]:
    for f in sorted(glob.glob(f"{src_dir}/*.wav")):
        nb = os.path.basename(f).replace("__noisy__", f"__{cond}__")
        dst = f"proc/{nb}"
        shutil.copy(f, dst)
        man.append(dst)
print(f"DFN renamed: {len(man)}")

# 2. RNNoise (ffmpeg arnndn) on every noisy clip.
t = time.time()
noisy = sorted(glob.glob("proc/*__noisy__*.wav"))
for i, f in enumerate(noisy):
    b = os.path.basename(f)[:-4]
    id_, _, noise, snr = b.split("__")
    dst = f"proc/{id_}__rnnoise__{noise}__{snr}.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", f,
                    "-af", "arnndn=m=rnnn/sh.rnnn", "-ar", "16000", "-ac", "1", dst],
                   check=True)
    man.append(dst)
    if (i + 1) % 50 == 0:
        print(f"  rnnoise {i+1}/{len(noisy)}  ({time.time()-t:.0f}s)")
print(f"RNNoise generated: {len(noisy)} in {time.time()-t:.0f}s")

with open("manifest_denoise.txt", "w") as fh:
    fh.write("\n".join(man) + "\n")
print(f"manifest_denoise.txt: {len(man)} files")
