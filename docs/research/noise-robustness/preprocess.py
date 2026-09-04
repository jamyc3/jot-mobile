#!/usr/bin/env python3
"""Build the noise-robustness condition matrix.

For each clean clip: decode->16k mono, synthesize wind + water noise, mix at
SNR {10,5} dB (relative to active-speech RMS), then render high-pass and
denoiser (afftdn, anlmdn) variants of every noisy clip. Writes transcription
manifests keyed by a parseable filename: {id}__{cond}__{noise}__snr{NN}.wav
"""
import os, subprocess, wave, struct, numpy as np

SR = 16000
NOISES = ["wind", "water"]
SNRS = [10, 5]
rng = np.random.default_rng(1234)

os.makedirs("clean", exist_ok=True)
os.makedirs("proc", exist_ok=True)

def read_wav16(path):
    with wave.open(path) as w:
        n = w.getnframes()
        raw = w.readframes(n)
    return np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0

def write_wav16(path, x):
    x = np.clip(x, -1.0, 1.0)
    pcm = (x * 32767.0).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())

def decode16k(src, dst):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error",
                    "-i", src, "-ac", "1", "-ar", str(SR), dst], check=True)

def colored_noise(n, beta):
    """beta=1 -> pink (1/f power), beta=2 -> brown/red (1/f^2 power)."""
    white = rng.standard_normal(n)
    X = np.fft.rfft(white)
    f = np.arange(len(X)); f[0] = 1
    X = X / (f ** (beta / 2.0))
    y = np.fft.irfft(X, n=n)
    return y / (np.std(y) + 1e-12)

def moving_avg(x, k):
    """O(n) box smoother via cumsum (envelope only, edges padded)."""
    k = min(k, len(x))
    c = np.cumsum(np.insert(x, 0, 0.0))
    ma = (c[k:] - c[:-k]) / k
    pad = len(x) - len(ma); left = pad // 2
    return np.concatenate([np.full(left, ma[0]), ma, np.full(pad - left, ma[-1])])

def make_wind(n):
    base = colored_noise(n, 2.0)                       # low-frequency rumble
    lfo = np.abs(colored_noise(n, 2.0))                # slow gusts
    lfo /= (lfo.max() + 1e-9)
    env = 0.4 + 0.6 * moving_avg(lfo, SR)              # ~1s smoothing = gust cadence
    y = base * env
    return y / (np.std(y) + 1e-12)

def make_water(n):
    y = colored_noise(n, 1.0)                          # broadband pink hiss
    # cheap high-pass: subtract a slow moving average -> lift mid/high band
    k = 64
    ma = np.convolve(y, np.ones(k) / k, mode="same")
    y = y - 0.9 * ma
    return y / (np.std(y) + 1e-12)

def active_rms(x):
    peak = np.abs(x).max()
    voiced = x[np.abs(x) > 0.12 * peak] if peak > 0 else x
    if voiced.size < SR // 5:
        voiced = x
    return np.sqrt(np.mean(voiced ** 2)) + 1e-12

def mix(clean, noise, snr_db):
    s = active_rms(clean)
    n = np.sqrt(np.mean(noise ** 2)) + 1e-12
    target_n = s / (10 ** (snr_db / 20.0))
    return clean + noise * (target_n / n)

def ff(src, dst, af):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error",
                    "-i", src, "-af", af, "-ar", str(SR), "-ac", "1", dst], check=True)

FILTERS = {
    "hpf":    "highpass=f=80",
    "afftdn": "afftdn=nr=24:nf=-25",
    "anlmdn": "anlmdn=s=0.001",
}

rows = [l.rstrip("\n").split("\t") for l in open("testset.tsv")]
m_v3, m_vad, m_v2 = [], [], []

for id_, src, wc, dur, tx in rows:
    clean = f"clean/{id_}.wav"
    decode16k(src, clean)
    m_v3.append(clean); m_v2.append(clean)
    x = read_wav16(clean)
    for noise in NOISES:
        bed = make_wind(len(x)) if noise == "wind" else make_water(len(x))
        for snr in SNRS:
            noisy = f"proc/{id_}__noisy__{noise}__snr{snr:02d}.wav"
            write_wav16(noisy, mix(x, bed, snr))
            m_v3.append(noisy); m_vad.append(noisy)
            if noise == "water" and snr == 5:
                m_v2.append(noisy)
            for cond, af in FILTERS.items():
                out = f"proc/{id_}__{cond}__{noise}__snr{snr:02d}.wav"
                ff(noisy, out, af)
                m_v3.append(out)

open("manifest_v3.txt", "w").write("\n".join(dict.fromkeys(m_v3)) + "\n")
open("manifest_vad.txt", "w").write("\n".join(m_vad) + "\n")
open("manifest_v2.txt", "w").write("\n".join(dict.fromkeys(m_v2)) + "\n")
print(f"clips={len(rows)}  v3_files={len(set(m_v3))}  vad_files={len(m_vad)}  v2_files={len(set(m_v2))}")
