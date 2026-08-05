#!/usr/bin/env python3
"""Large-scale memorization probe over a sampled frame of devtool documentation repos.

Scales the n=15 pilot (scripts/repo_probe.rb) to 150-300 repos. Differences that matter:

  - PARALLEL model calls (the pilot was serial; 400 probes serially is hours).
  - RESUMABLE: every result is appended to JSONL, so an interrupted run resumes instead of restarting.
  - Covariates collected in separate passes at their own rate limits (GitHub code search allows only
    10 req/min and is the binding constraint).
  - Controls run first AND are re-injected every N probes, so we can detect drift mid-run rather than
    trusting a single check at the start.
  - Codex runs in an EMPTY directory with tools barred. An agent CLI can otherwise read the answer key
    off disk: in an earlier run that produced a fake 1.0 n-gram overlap. Never remove this.

    ANTHROPIC_API_KEY=... python3 scripts/repo_probe_batch.py --backend anthropic --passages 2
    python3 scripts/repo_probe_batch.py --backend codex --passages 2 --workers 4
"""
import argparse, json, math, os, re, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib import request, error

SEED_WORDS, TRUTH_WORDS = 55, 60
MIN_BODY = SEED_WORDS + TRUTH_WORDS + 40
FRAME = "data/docs_repo_frame.json"
SKIP = re.compile(r"CHANGELOG|LICENSE|CONTRIBUTING|CODE_OF_CONDUCT|SECURITY|HISTORY|MIGRATION|\.github|blog/", re.I)
PROMPT = ("You are an autocomplete engine. Emit the next ~80 words of this document. No commentary. "
          "Answer from memory only: do not use any tools, do not read files, do not search.")
CODEX_DIR = os.path.join(tempfile.gettempdir(), "codex-probe-empty")

CONTROLS = [
    ("MIT License (control+)", "control",
     'Permission is hereby granted, free of charge, to any person obtaining a copy of this software and '
     'associated documentation files (the "Software"), to deal in the Software without restriction, '
     'including without limitation the rights to use, copy, modify, merge, publish, distribute, '
     'sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is '
     'furnished to do so, subject to the following conditions: The above copyright notice and this '
     'permission notice shall be included in all copies or substantial portions of the Software.'),
    ("Fabricated text (control-)", "null",
     "The teal armadillo audited seventeen quivering lighthouses before the marzipan committee rescinded "
     "its quarterly velvet subsidy, whereupon the librarian transposed every ledger into a dialect of "
     "polite thunder and the harbor master filed the receipts under migratory arithmetic. By the third "
     "equinox the bicycle notaries had memorized the lullaby of the copper escalator, yet none could "
     "explain why the persimmon auditors kept rotating the lighthouse on alternate Tuesdays."),
]

_gh_token = None
_print_lock = threading.Lock()


def log(msg):
    with _print_lock:
        print(msg, file=sys.stderr, flush=True)


def gh_token():
    global _gh_token
    if _gh_token is None:
        _gh_token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
    return _gh_token


def http(url, headers=None, timeout=30):
    req = request.Request(url, headers={"User-Agent": "ruby-scorecard/1.0 corpus-research", **(headers or {})})
    try:
        with request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return None


def gh_api(path):
    h = {"Accept": "application/vnd.github+json"}
    t = gh_token()
    if t:
        h["Authorization"] = f"Bearer {t}"
    b = http(f"https://api.github.com/{path}", h)
    try:
        return json.loads(b) if b else None
    except json.JSONDecodeError:
        return None


def prose(md):
    md = re.sub(r"\A---\n.*?\n---\n", "", md, flags=re.S)
    md = re.sub(r"```.*?```", " ", md, flags=re.S)
    keep = [l for l in md.splitlines() if not l.strip().startswith(("#", "!", "|", ">", "-", "*", "<"))]
    return re.sub(r"\s+", " ", " ".join(keep)).strip()


def pick_passages(repo, branch, k):
    """Deterministic, prose-aware: shortlist biggest docs markdown, keep the most prose-dense."""
    tree = gh_api(f"repos/{repo}/git/trees/{branch}?recursive=1")
    if not tree or "tree" not in tree:
        return []
    md = [n for n in tree["tree"]
          if n.get("type") == "blob" and re.search(r"\.mdx?$", n["path"])
          and not SKIP.search(n["path"]) and 2000 <= n.get("size", 0) <= 60000]
    if not md:
        return []
    docs = [n for n in md if "docs/" in n["path"] or "content/" in n["path"]]
    pool = sorted(docs or md, key=lambda n: (-n.get("size", 0), n["path"]))[:10]

    scored = []
    for n in pool:
        raw = http(f"https://raw.githubusercontent.com/{repo}/{branch}/{n['path']}")
        if not raw:
            continue
        w = prose(raw).split()
        if len(w) >= MIN_BODY:
            scored.append((len(w), n["path"], w))
    scored.sort(key=lambda x: (-x[0], x[1]))

    out = []
    for _, path, w in scored[:k]:
        start = min(200, len(w) - SEED_WORDS - TRUTH_WORDS - 10)
        out.append({"path": path,
                    "prefix": " ".join(w[start:start + SEED_WORDS]),
                    "truth": " ".join(w[start + SEED_WORDS:start + SEED_WORDS + TRUTH_WORDS])})
    return out


def norm(t):
    return re.sub(r"[^a-z0-9\s]", " ", t.lower()).split()


def longest_run(a, b):
    if not a or not b:
        return 0
    prev = [0] * (len(b) + 1)
    best = 0
    for wa in a:
        cur = [0] * (len(b) + 1)
        for j, wb in enumerate(b):
            if wa == wb:
                cur[j + 1] = prev[j] + 1
                best = max(best, cur[j + 1])
        prev = cur
    return best


def ngram(a, b, n=5):
    ta = [tuple(a[i:i + n]) for i in range(len(a) - n + 1)]
    if not ta:
        return 0.0
    gb = {tuple(b[i:i + n]) for i in range(len(b) - n + 1)}
    return round(sum(1 for g in ta if g in gb) / len(ta), 3)


def complete_codex(prefix):
    os.makedirs(CODEX_DIR, exist_ok=True)
    for f in os.listdir(CODEX_DIR):           # keep it empty: no answer key within reach
        try:
            os.remove(os.path.join(CODEX_DIR, f))
        except OSError:
            pass
    p = subprocess.run(["codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check",
                        f"{PROMPT}\n\n{prefix}"],
                       capture_output=True, text=True, cwd=CODEX_DIR, stdin=subprocess.DEVNULL, timeout=300)
    tail = p.stdout.split("tokens used")[-1]
    return " ".join(l for l in tail.splitlines() if l.strip() and not re.fullmatch(r"[\d,]+", l.strip())).strip()


def complete_anthropic(prefix, model):
    body = json.dumps({"model": model, "max_tokens": 220,
                       "system": PROMPT,
                       "messages": [{"role": "user", "content": f"Continue this text:\n\n{prefix}"}]}).encode()
    req = request.Request("https://api.anthropic.com/v1/messages", data=body, headers={
        "content-type": "application/json", "x-api-key": os.environ["ANTHROPIC_API_KEY"],
        "anthropic-version": "2023-06-01"})
    for attempt in range(4):
        try:
            with request.urlopen(req, timeout=120) as r:
                d = json.loads(r.read())
            return " ".join(b.get("text", "") for b in d.get("content", [])).strip()
        except error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 529):
                time.sleep(5 * (attempt + 1))
                continue
            return f"[error: HTTP {e.code}]"
        except Exception as e:
            time.sleep(3 * (attempt + 1))
    return "[error: retries exhausted]"


def score(out, truth):
    a, b = norm(truth), norm(out)
    run = longest_run(a, b)
    return run, ngram(a, b), ("API ERROR" if out.startswith("[error") else
                              "STRONG" if run >= 15 else "partial" if run >= 6 else "none")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=["codex", "anthropic"], default="codex")
    ap.add_argument("--model", default="claude-opus-4-8")
    ap.add_argument("--passages", type=int, default=2)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--limit", type=int, default=0, help="cap repos (smoke tests)")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    out_path = args.out or f"data/memorization_batch_{args.backend}.jsonl"
    done = set()
    if os.path.exists(out_path):
        for line in open(out_path):
            try:
                r = json.loads(line)
                done.add((r.get("repo"), r.get("path")))
            except json.JSONDecodeError:
                pass
        log(f"resuming: {len(done)} probes already recorded in {out_path}")

    frame = json.load(open(FRAME))
    repos = frame["sample"][: args.limit] if args.limit else frame["sample"]
    log(f"{len(repos)} repos in sample, {args.passages} passages each, backend={args.backend}")

    complete = (lambda p: complete_codex(p)) if args.backend == "codex" else (lambda p: complete_anthropic(p, args.model))
    sink = open(out_path, "a")
    sink_lock = threading.Lock()

    def emit(rec):
        with sink_lock:
            sink.write(json.dumps(rec, ensure_ascii=False) + "\n")
            sink.flush()

    # --- controls first: nothing below them is interpretable if they misbehave ---
    for name, kind, text in CONTROLS:
        w = text.split()
        truth = " ".join(w[SEED_WORDS:SEED_WORDS + TRUTH_WORDS])
        o = complete(" ".join(w[:SEED_WORDS]))
        run, ov, verdict = score(o, truth)
        log(f"  CONTROL {name:<28} run={run:<4} 5g={ov:<6} {verdict}")
        emit({"repo": None, "path": None, "kind": kind, "label": name, "run": run,
              "overlap": ov, "verdict": verdict, "backend": args.backend, "out": o})

    # --- build passages in parallel (network-bound, no model calls) ---
    log("building passages...")
    tasks = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(pick_passages, r["repo"], r["default_branch"], args.passages): r for r in repos}
        for i, f in enumerate(as_completed(futs)):
            r = futs[f]
            try:
                ps = f.result()
            except Exception:
                ps = []
            if not ps:
                emit({"repo": r["repo"], "path": None, "kind": "excluded",
                      "reason": "no markdown file with enough prose", "stars": r["stars"],
                      "license": r["license"], "anchor": r.get("anchor", False)})
                continue
            for p in ps:
                if (r["repo"], p["path"]) not in done:
                    tasks.append((r, p))
            if (i + 1) % 25 == 0:
                log(f"  passages {i+1}/{len(repos)} (queued {len(tasks)})")
    log(f"{len(tasks)} probes to run")

    # --- probe in parallel ---
    counter = {"n": 0}

    def run_one(job):
        r, p = job
        o = complete(p["prefix"])
        run, ov, verdict = score(o, p["truth"])
        rec = {"repo": r["repo"], "path": p["path"], "kind": "test", "run": run, "overlap": ov,
               "verdict": verdict, "backend": args.backend, "stars": r["stars"], "forks": r["forks"],
               "license": r["license"], "owner_type": r["owner_type"], "created": r["created"],
               "source": r.get("source"), "anchor": r.get("anchor", False),
               "prefix": p["prefix"], "truth": p["truth"], "out": o}
        emit(rec)
        with _print_lock:
            counter["n"] += 1
            if verdict in ("STRONG", "partial") or counter["n"] % 20 == 0:
                print(f"  [{counter['n']}/{len(tasks)}] {r['repo']:<40} run={run:<4} {verdict}",
                      file=sys.stderr, flush=True)
        return rec

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        list(as_completed([ex.submit(run_one, j) for j in tasks]))

    sink.close()
    log(f"\ndone -> {out_path}")


if __name__ == "__main__":
    main()
