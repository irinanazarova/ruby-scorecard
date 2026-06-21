#!/usr/bin/env python3
"""Training-data quality probe.

For each resource in data/scorecard.json, fetch its docs page and score it with the open
FineWeb-Edu classifier (HuggingFaceFW/fineweb-edu-classifier) — the model HuggingFace used to
build FineWeb-Edu, which keeps documents scoring >= 3 on a 0-5 "educational quality" scale. This
is the closest public proxy for "would a modern pretraining corpus keep this page". We also record
the C4 curly-brace heuristic: C4 strips every line containing "{" (a code-line proxy), so code-heavy
pages lose their code and can then fall below C4's length filter. c4_curly flags pages with any "{".

Being in Common Crawl is necessary but not sufficient; this measures the second gate (quality
filtering). Run on a disposable Fly machine via fetch/quality-on-fly.sh. `--print` -> JSON on stdout.
"""
import json, sys, re, time, urllib.request, os
from concurrent.futures import ThreadPoolExecutor

MODEL = "HuggingFaceFW/fineweb-edu-classifier"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRINT_ONLY = "--print" in sys.argv
# --details NAME : instead of scoring resources, score the found vs not-crawled pages of one
# coverage-detail target (data/coverage_details.json) to test whether the missing pages are missing
# because they'd fail the quality filter, or just were not crawled. Caps each bucket for runtime.
DETAILS = sys.argv[sys.argv.index("--details") + 1] if "--details" in sys.argv else None
CAP = int(sys.argv[sys.argv.index("--cap") + 1]) if "--cap" in sys.argv else 120
ONLY = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
# --extra-urls "u1,u2": score these as an extra "extra" bucket in --details mode (ad-hoc page checks).
EXTRA = sys.argv[sys.argv.index("--extra-urls") + 1].split(",") if "--extra-urls" in sys.argv else []

import torch
from transformers import AutoTokenizer, AutoModelForSequenceClassification

torch.set_num_threads(os.cpu_count() or 4)
tok = AutoTokenizer.from_pretrained(MODEL)
model = AutoModelForSequenceClassification.from_pretrained(MODEL)
model.eval()

def edu_scores_batch(texts, bs=16):
    scores = []
    for i in range(0, len(texts), bs):
        inp = tok(texts[i:i + bs], return_tensors="pt", truncation=True, max_length=512, padding=True)
        with torch.no_grad():
            logits = model(**inp).logits.squeeze(-1).float().tolist()
        if not isinstance(logits, list):
            logits = [logits]
        scores.extend(max(0.0, min(l, 5.0)) for l in logits)
        print(f"  scored {min(i + bs, len(texts))}/{len(texts)}", file=sys.stderr)
    return scores

CHROME = re.compile(r"(?is)<(script|style|svg|nav|head|header|footer|aside)\b.*?</\1>")

def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ruby-scorecard/1.0 quality-probe (+https://ruby.evilmartians.com)"})
        return urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "ignore")
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

def score_doc(url):
    text = to_text(fetch(url))
    if len(text) < 50:
        return {"edu": None, "note": "no readable text"}
    score = round(edu_score(text), 2)
    return {"edu": score, "edu_int": int(round(score)), "keep": score >= 3,
            "c4_curly": "{" in text, "chars": len(text)}

def evenly(items, cap):
    if len(items) <= cap:
        return items
    step = len(items) / cap
    return [items[int(i * step)] for i in range(cap)]

if DETAILS:
    det = json.load(open(os.path.join(ROOT, "data", "coverage_details.json")))[DETAILS]
    junk = re.compile(r"(?i)\.(atom|xml|json|rss|png|jpg|svg|pdf|css|js)$|%")
    def normurls(lst):
        seen, urls = set(), []
        for p in lst:
            if junk.search(p):
                continue
            u = "https://" + p.lstrip("/") if not p.startswith("http") else p
            if u not in seen:
                seen.add(u); urls.append(u)
        return urls
    buckets = {"found": evenly(normurls(det["found"]), CAP),
               "not_crawled": evenly(normurls(det["not_crawled"]), CAP)}
    if ONLY:
        buckets = {ONLY: buckets[ONLY]}
    if EXTRA:
        buckets["extra"] = [u.strip() for u in EXTRA if u.strip()]
    out = {"target": DETAILS, "docs": det.get("docs"), "buckets": {}}
    for bname, urls in buckets.items():
        # Fetch concurrently (network-bound), then score in batches (torch forward pass batches well).
        print(f"[{bname}] fetching {len(urls)} ...", file=sys.stderr)
        with ThreadPoolExecutor(max_workers=16) as ex:
            texts = list(ex.map(lambda u: to_text(fetch(u)), urls))
        have = [i for i, t in enumerate(texts) if len(t) >= 50]
        print(f"[{bname}] scoring {len(have)} with text ({len(urls) - len(have)} empty) ...", file=sys.stderr)
        batch_scores = edu_scores_batch([texts[i] for i in have])
        score_by_idx = dict(zip(have, batch_scores))
        scored = []
        for i, (u, text) in enumerate(zip(urls, texts)):
            if i not in score_by_idx:
                e = {"edu": None, "note": "no readable text"}
            else:
                score = round(score_by_idx[i], 2)
                e = {"edu": score, "edu_int": int(round(score)), "keep": score >= 3,
                     "c4_curly": "{" in text, "chars": len(text)}
            e["url"] = u
            scored.append(e)
        vals = [e["edu"] for e in scored if e.get("edu") is not None]
        vals_sorted = sorted(vals)
        n = len(vals)
        out["buckets"][bname] = {
            "n_urls": len(urls), "n_scored": n,
            "avg": round(sum(vals) / n, 2) if n else None,
            "median": round(vals_sorted[n // 2], 2) if n else None,
            "keep_ge3": sum(1 for v in vals if v >= 3),
            "below2": sum(1 for v in vals if v < 2),
            "pages": scored,
        }
    if PRINT_ONLY:
        print(json.dumps(out))
    else:
        path = os.path.join(ROOT, "data", "quality_details.json")
        json.dump(out, open(path, "w"), indent=1)
        print(f"wrote {path}", file=sys.stderr)
    sys.exit(0)

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
