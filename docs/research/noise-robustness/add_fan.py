#!/usr/bin/env python3
"""Add an exhaust-fan noise condition to the existing bench and re-transcribe.

Bathroom exhaust fan = steady broadband air rush + low-frequency motor hum
(60/120/180 Hz), constant over time (no gusts). Reuses the clean/ wavs already
rendered; writes proc/{id}__{cond}__fan__snrNN.wav and appends transcripts to
the existing out_v3 / out_vad jsonl so score.py picks up the new 'fan' bucket.
"""
import os, subprocess, wave, numpy as np

SR = 16000
SNRS = [10, 5]
rng = np.random.default_rng(4242)

def read_wav16(path):
    with wave.open(path) as w:
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0

def write_wav16(path, x):
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())

def colored_noise(n, beta):
    X = np.fft.rfft(rng.standard_normal(n))
    f = np.arange(len(X)); f[0] = 1
    y = np.fft.irfft(X / (f ** (beta / 2.0)), n=n)
    return y / (np.std(y) + 1e-12)

def make_fan(n):
    broadband = colored_noise(n, 0.9)                  # near-pink, broad — the speech masker
    t = np.arange(n) / SR
    hum = (0.5*np.sin(2*np.pi*60*t) + 0.3*np.sin(2*np.pi*120*t) + 0.15*np.sin(2*np.pi*180*t))
    hum /= (np.std(hum) + 1e-12)                        # steady low-freq motor hum
    y = broadband + 0.35 * hum
    return y / (np.std(y) + 1e-12)

def active_rms(x):
    peak = np.abs(x).max()
    v = x[np.abs(x) > 0.12 * peak] if peak > 0 else x
    if v.size < SR // 5: v = x
    return np.sqrt(np.mean(v ** 2)) + 1e-12

def mix(clean, noise, snr):
    tn = active_rms(clean) / (10 ** (snr / 20.0))
    return clean + noise * (tn / (np.sqrt(np.mean(noise ** 2)) + 1e-12))

def ff(src, dst, af):
    subprocess.run(["ffmpeg","-nostdin","-y","-loglevel","error","-i",src,"-af",af,"-ar",str(SR),"-ac","1",dst], check=True)

FILTERS = {"hpf":"highpass=f=80", "afftdn":"afftdn=nr=24:nf=-25", "anlmdn":"anlmdn=s=0.001"}

ids = [l.split("\t")[0] for l in open("testset.tsv")]
m_v3, m_vad = [], []
for id_ in ids:
    x = read_wav16(f"clean/{id_}.wav")
    bed = make_fan(len(x))
    for snr in SNRS:
        noisy = f"proc/{id_}__noisy__fan__snr{snr:02d}.wav"
        write_wav16(noisy, mix(x, bed, snr))
        m_v3.append(noisy); m_vad.append(noisy)
        for cond, af in FILTERS.items():
            out = f"proc/{id_}__{cond}__fan__snr{snr:02d}.wav"
            ff(noisy, out, af); m_v3.append(out)

open("manifest_fan_v3.txt","w").write("\n".join(m_v3)+"\n")
open("manifest_fan_vad.txt","w").write("\n".join(m_vad)+"\n")
print(f"fan files: v3={len(m_v3)} vad={len(m_vad)}")
