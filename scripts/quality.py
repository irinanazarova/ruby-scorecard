#!/usr/bin/env python3
"""Training-data quality probe.

For each resource in data/scorecard.json, fetch its docs page and score it with the open
FineWeb-Edu classifier (HuggingFaceFW/fineweb-edu-classifier) — the model HuggingFace used to
build FineWeb-Edu, which keeps documents scoring >= 3 on a 0-5 "educational quality" scale. This
is the closest public proxy for "would a modern pretraining corpus keep this page". We also record
the C4 curly-brace heuristic: C4 drops any page containing "{", which silently removes code.

Being in Common Crawl is necessary but not sufficient; this measures the second gate (quality
filtering). Run on a disposable Fly machine via fetch/quality-on-fly.sh. `--print` -> JSON on stdout.
"""
import json, sys, re, time, urllib.request, os

MODEL = "HuggingFaceFW/fineweb-edu-classifier"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRINT_ONLY = "--print" in sys.argv

import torch
from transformers import AutoTokenizer, AutoModelForSequenceClassification

tok = AutoTokenizer.from_pretrained(MODEL)
model = AutoModelForSequenceClassification.from_pretrained(MODEL)
model.eval()

CHROME = re.compile(r"(?is)<(script|style|svg|nav|head|header|footer|aside)\b.*?</\1>")

def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ruby-scorecard/1.0 quality-probe (+https://ruby.evilmartians.com)"})
        return urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "ignore")
    except Exception:
        return ""

def to_text(html):
    html = CHROME.sub(" ", html)
    text = re.sub(r"(?s)<[^>]+>", " ", html)
    text = re.sub(r"&[a-z#0-9]+;", " ", text)
    return re.sub(r"\s+", " ", text).strip()

def edu_score(text):
    inputs = tok(text, return_tensors="pt", truncation=True, max_length=512)
    with torch.no_grad():
        logit = model(**inputs).logits.squeeze(-1).float().item()
    return max(0.0, min(logit, 5.0))

rows = json.load(open(os.path.join(ROOT, "data", "scorecard.json")))["rows"]
out = {}
for r in rows:
    name = r["name"]
    text = to_text(fetch(r["docs"]))
    if len(text) < 50:
        out[name] = {"edu": None, "note": "no readable text"}
        print(f"{name:24s} (no text)", file=sys.stderr)
        continue
    score = round(edu_score(text), 2)
    entry = {"edu": score, "edu_int": int(round(score)), "keep": score >= 3,
             "c4_curly": "{" in text, "chars": len(text)}
    out[name] = entry
    print(f"{name:24s} edu={score:.2f} keep={entry['keep']} curly={entry['c4_curly']}", file=sys.stderr)
    time.sleep(0.3)

if PRINT_ONLY:
    print(json.dumps(out))
else:
    path = os.path.join(ROOT, "data", "quality.json")
    json.dump(out, open(path, "w"), indent=1)
    print(f"wrote {path}", file=sys.stderr)
