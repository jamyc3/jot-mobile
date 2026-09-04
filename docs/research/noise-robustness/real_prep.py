#!/usr/bin/env python3
"""Generate every fix-variant for the two REAL recordings (fan, water)."""
import os, subprocess

FILTERS = {
    "hpf": "highpass=f=80",
    "afftdn": "afftdn=nr=24:nf=-25",
    "anlmdn": "anlmdn=s=0.001",
    "rnnoise": "arnndn=m=rnnn/sh.rnnn",
}
names = ["fan", "water"]
manifest = []

for n in names:
    raw = f"real/raw/{n}.wav"
    manifest.append(raw)                                  # baseline (do nothing)
    for cond, af in FILTERS.items():
        out = f"real/proc/{n}__{cond}.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", raw,
                        "-af", af, "-ar", "16000", "-ac", "1", out], check=True)
        manifest.append(out)

# DeepFilterNet full + mild
for atten, cond in [(100, "dfn"), (12, "dfnmild")]:
    subprocess.run(["./deep-filter", "-a", str(atten), "-o", f"real/dfn_{cond}",
                    "real/raw/fan.wav", "real/raw/water.wav"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for n in names:
        src = f"real/dfn_{cond}/{n}.wav"
        dst = f"real/proc/{n}__{cond}.wav"
        os.replace(src, dst)
        manifest.append(dst)

open("manifest_real.txt", "w").write("\n".join(manifest) + "\n")
open("manifest_real_vad.txt", "w").write("\n".join(f"real/raw/{n}.wav" for n in names) + "\n")
print(f"real variants: {len(manifest)} files")
print("\n".join(manifest))
