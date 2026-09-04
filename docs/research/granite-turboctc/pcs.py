"""Python port of IBM's punctuator.js (English punct_cap_seg model).

Model: 1-800-BAD-CODE punct_cap_seg_en, as shipped in the official
ibm-granite/granite-speech-streaming-webgpu demo space.
Labels: pre=[<NULL>,'¿']  post=[<NULL>,<ACRONYM>,'.',',','?']  cap=per-char  seg=sentence end.

DIVERGENCE FROM THE REFERENCE JS (deliberate, it is a bug fix):
IBM's punctuator.js decodes each token by looking the id back up in the vocab
(`pcsVocabReverse[tokenId]`). For an out-of-vocabulary character that resolves
to UNK, that yields the literal string "<unk>", which is then emitted into the
user-visible text — and the per-character capitaliser may even upper-case it,
producing "front<Unk>end" for "front-end". Measured on 420 real dictations:
19/420 (4.5%) of outputs contained a literal <unk>.

Fix: remember the SOURCE text each token consumed and emit that instead of the
vocab string, so an unknown character passes through unchanged. Any Swift port
must do the same.
"""
import json
import numpy as np
import onnxruntime as ort

PRE = ["", "¿"]
POST = ["", "<ACRONYM>", ".", ",", "?"]
BOS, EOS, PAD, UNK = 1, 2, 3, 0


class Punctuator:
    def __init__(self, model="pcs/punct_cap_seg_en.onnx", vocab="pcs/pcs_vocab.json", threads=0):
        so = ort.SessionOptions()
        if threads:
            so.intra_op_num_threads = threads
        self.s = ort.InferenceSession(model, so, providers=["CPUExecutionProvider"])
        self.vocab = json.load(open(vocab))["vocab"]
        self.maxlen = max(len(k) for k in self.vocab)

    def tokenize(self, text):
        """Greedy longest-match unigram. Returns (ids, pieces) where pieces[i]
        is the source text token i consumed — for a known token that is the
        vocab string, for UNK it is the raw character that failed to match."""
        rem = "▁" + text.lower().replace(" ", "▁")
        ids, pieces = [BOS], [""]
        while rem:
            for L in range(min(len(rem), self.maxlen), 0, -1):
                p = rem[:L]
                if p in self.vocab:
                    ids.append(self.vocab[p])
                    pieces.append(p)
                    rem = rem[L:]
                    break
            else:
                ids.append(UNK)
                pieces.append(rem[0])   # pass the unknown character through
                rem = rem[1:]
        ids.append(EOS)
        pieces.append("")
        return ids, pieces

    def __call__(self, text):
        if not text or not text.strip():
            return text
        ids, pieces = self.tokenize(text)
        pre, post, cap, seg = self.s.run(None, {"input_ids": np.array([ids], dtype=np.int64)})
        pre, post, cap, seg = pre[0], post[0], cap[0], seg[0]
        out, cur = [], []
        for i in range(len(ids) - 2):
            tok = pieces[i + 1]
            oi = i + 1
            if tok.startswith("▁") and cur:
                cur.append(" ")
            cs = 1 if tok.startswith("▁") else 0
            for j in range(cs, len(tok)):
                ch = tok[j]
                if j == cs and pre[oi] == 1:
                    cur.append(PRE[1])
                if j < 16 and cap[oi][j]:
                    ch = ch.upper()
                cur.append(ch)
                pl = post[oi]
                if pl == 1:
                    cur.append(".")
                elif j == len(tok) - 1 and pl > 1:
                    cur.append(POST[pl])
            if seg[oi]:
                out.append("".join(cur))
                cur = []
        if cur:
            out.append("".join(cur))
        return " ".join(out)


if __name__ == "__main__":
    p = Punctuator()
    for t in ["use the front-end design skill look up online",
              "i do not think even the jwt is needed here",
              "it can host around 5,000 pages and gemini 3.1 flash"]:
        print(f"  in : {t}\n  out: {p(t)}\n")
