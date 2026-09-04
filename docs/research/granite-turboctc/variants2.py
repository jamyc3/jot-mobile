import json,time
from pcs import Punctuator
from strip import strip_fmt
p=Punctuator()
gp={json.loads(l)["id"]:json.loads(l) for l in open("granite_pcs.jsonl")}
nm={json.loads(l)["id"]:json.loads(l) for l in open("nemo_all.jsonl")}
rows=[json.loads(l) for l in open("nemoen_all.jsonl")]
out=open("variants2.jsonl","w")
for r in rows:
    i=r["id"]; g=gp.get(i,{}); n=nm.get(i,{})
    ne=r["nemotron_en"].strip()
    out.write(json.dumps({"id":i,"dur":r["dur"],
      "parakeet":r["jot"],
      "parakeet_pcs":p(strip_fmt(r["jot"])),
      "nemotron_en":ne,
      "nemotron_en_pcs_ontop":p(ne),
      "nemotron_multi":n.get("nemotron","").strip(),
      "granite":r["granite"],
      "granite_pcs":g.get("granite_pcs","")})+"\n")
out.close(); print("built",len(rows))
