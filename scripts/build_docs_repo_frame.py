#!/usr/bin/env python3
"""Build a reproducible sampling frame of DEVTOOL PRODUCT documentation repos, then draw a
stratified random sample for the memorization study.

Why this frame: hand-picking repos reintroduces the selection bias a larger sample is meant to
remove. So we enumerate repos that ARE documentation sites by construction (via their docs-framework
config file: Mintlify, Docusaurus, VitePress, Nextra, MkDocs), then screen for *product* docs.

The product screen is the important part. A naive frame is swamped by hobby sites: the first draw
returned "Constitution-of-Bangladesh" and a Mintlify demo repo. The signal that separates a real
devtool product from a weekend project is not the docs repo's own stars, it is **how prominent the
owner's biggest repo is**. AnyCable's docs repo has 10 stars while its org's main repo has 2,366.
That screen also buys a scientific benefit: it splits two variables the pilot conflated, letting us
test docs-repo stars and product prominence as separate predictors.

Stages are cached, so re-screening does not re-enumerate:
    data/docs_repo_candidates.json   every hydrated candidate (slow to build, reused)
    data/docs_repo_frame.json        the drawn sample

    python3 scripts/build_docs_repo_frame.py            # uses cache if present
    REBUILD=1 python3 scripts/build_docs_repo_frame.py  # force re-enumeration
"""
import json, os, random, subprocess, sys, time
from collections import defaultdict

SEED = 20260726
SAMPLE_N = int(os.environ.get("SAMPLE_N", "180"))
MIN_OWNER_STARS = int(os.environ.get("MIN_OWNER_STARS", "100"))   # product-likeness threshold
CAND = "data/docs_repo_candidates.json"
OUT = "data/docs_repo_frame.json"

QUERIES = [
    ("mintlify",    "mintlify filename:mint.json"),
    ("mintlify2",   "navigation filename:docs.json"),
    ("docusaurus",  "presets filename:docusaurus.config.js"),
    ("docusaurus2", "presets filename:docusaurus.config.ts"),
    ("vitepress",   "defineConfig path:.vitepress"),
    ("nextra",      "nextra filename:theme.config.tsx"),
    ("mkdocs",      "site_name filename:mkdocs.yml"),
]
PAGES = 5   # 100/page; code search caps out at 1000 results per query

ANCHORS = ["supabase/supabase", "workos/authkit", "resend/resend-node", "anycable/anycable",
           "anycable/docs.anycable.io", "vercel/next.js", "netlify/cli", "clerk/javascript",
           "prisma/web", "stripe/stripe-node", "tailwindlabs/tailwindcss.com", "honojs/website"]

# Strata over PRODUCT prominence (owner's top repo), so the sample spans real devtool scale.
STRATA = [(100, 316), (317, 1000), (1001, 3162), (3163, 10000), (10001, 31622), (31623, 10**9)]


def gh(args, retries=4):
    for i in range(retries):
        p = subprocess.run(["gh", "api"] + args, capture_output=True, text=True)
        if p.returncode == 0:
            try:
                return json.loads(p.stdout)
            except json.JSONDecodeError:
                return None
        err = (p.stderr or "").lower()
        if "rate limit" in err or "403" in err or "was submitted too quickly" in err:
            time.sleep(20 * (i + 1))
            continue
        return None
    return None


def enumerate_frame():
    found = {}
    for name, q in QUERIES:
        for page in range(1, PAGES + 1):
            d = gh(["-X", "GET", "search/code", "-f", f"q={q}",
                    "-f", "per_page=100", "-f", f"page={page}"])
            items = (d or {}).get("items") or []
            if not items:
                break
            for it in items:
                found.setdefault(it["repository"]["full_name"], name)
            print(f"  {name} p{page}: +{len(items)} (frame={len(found)})", file=sys.stderr)
            time.sleep(7)
    return found


def hydrate(names):
    rows = []
    for i, n in enumerate(names):
        info = gh([f"repos/{n}"])
        if not info or info.get("message"):
            continue
        rows.append({
            "repo": info["full_name"], "owner": info["owner"]["login"],
            "stars": info["stargazers_count"], "forks": info["forks_count"],
            "license": (info.get("license") or {}).get("spdx_id") or "NONE",
            "owner_type": info["owner"]["type"], "created": info["created_at"][:10],
            "pushed": info["pushed_at"][:10], "archived": info.get("archived", False),
            "default_branch": info["default_branch"], "size_kb": info.get("size", 0),
        })
        if (i + 1) % 100 == 0:
            print(f"  hydrated {i+1}/{len(names)}", file=sys.stderr)
    return rows


def owner_top_stars_one(owner):
    """Prominence of an owner's biggest repo. Search API allows 30/min, so callers pace at ~2.2s."""
    d = gh(["-X", "GET", "search/repositories", "-f", f"q=user:{owner}",
            "-f", "sort=stars", "-f", "order=desc", "-f", "per_page=1"])
    items = (d or {}).get("items") or []
    return items[0]["stargazers_count"] if items else 0


def save_owner_cache(cache):
    """Checkpoint after every batch: an interrupted run must not throw away measured owners."""
    blob = json.load(open(CAND))
    blob["owner_stars"] = cache
    tmp = CAND + ".tmp"
    json.dump(blob, open(tmp, "w"), indent=2)
    os.replace(tmp, CAND)


def main():
    if os.path.exists(CAND) and not os.environ.get("REBUILD"):
        rows = json.load(open(CAND))["candidates"]
        print(f"cache: {len(rows)} candidates from {CAND}", file=sys.stderr)
    else:
        print("Enumerating docs repos by framework fingerprint...", file=sys.stderr)
        frame = enumerate_frame()
        for a in ANCHORS:
            frame.setdefault(a, "anchor")
        print(f"frame: {len(frame)} candidates; hydrating...", file=sys.stderr)
        rows = hydrate(sorted(frame))
        for r in rows:
            r["source"] = frame[r["repo"]]
        os.makedirs("data", exist_ok=True)
        json.dump({"built": "2026-07-27", "candidates": rows}, open(CAND, "w"), indent=2)
        print(f"cached {len(rows)} -> {CAND}", file=sys.stderr)

    for r in rows:
        r["anchor"] = r["repo"] in ANCHORS

    live = [r for r in rows if not r["archived"] and r["pushed"] >= "2024-01-01"]

    # Product screen: cheap pre-filter, then owner prominence.
    pre = [r for r in live if r["owner_type"] == "Organization" or r["stars"] >= 10 or r["anchor"]]

    # Measuring all ~1,350 owners costs ~1h at 30 req/min. Instead: shuffle ONCE with the seed
    # (so the draw stays random and reproducible), then measure lazily, walking the shuffled list
    # and filling strata until each is full. Same sample, a fraction of the calls.
    rng = random.Random(SEED)
    order = [r for r in pre if not r["anchor"]]
    rng.shuffle(order)
    order = [r for r in pre if r["anchor"]] + order       # anchors measured first, always included

    cache = json.load(open(CAND)).get("owner_stars", {}) if os.path.exists(CAND) else {}
    print(f"live={len(live)} pre-screened={len(pre)} (owner cache: {len(cache)}); "
          f"measuring prominence lazily...", file=sys.stderr)

    per = max(1, SAMPLE_N // len(STRATA))
    buckets = defaultdict(list)
    sample, measured, calls = [], 0, 0

    def band_of(v):
        for lo, hi in STRATA:
            if lo <= v <= hi:
                return (lo, hi)
        return None

    max_calls = int(os.environ.get("MAX_OWNER_CALLS", "700"))
    for r in order:
        # Stop when every stratum is full, or when the lookup budget is spent. Sparse top strata
        # would otherwise walk the whole pre-screened list (~1h at 30 req/min).
        if not r["anchor"] and (all(len(buckets[b]) >= per for b in STRATA) or calls >= max_calls):
            break
        o = r["owner"]
        if o not in cache:
            cache[o] = owner_top_stars_one(o)
            calls += 1
            time.sleep(2.2)
            if calls % 25 == 0:
                save_owner_cache(cache)
                filled = sum(min(len(buckets[b]), per) for b in STRATA)
                print(f"  measured {calls} owners; strata filled {filled}/{per*len(STRATA)}", file=sys.stderr)
        r["owner_top_stars"] = cache[o]
        measured += 1

        if r["anchor"]:
            sample.append(r)
            continue
        if r["owner_top_stars"] < MIN_OWNER_STARS:
            continue
        b = band_of(r["owner_top_stars"])
        if b and len(buckets[b]) < per:
            buckets[b].append(r)
            sample.append(r)

    save_owner_cache(cache)
    products = measured
    print(f"measured {measured} repos ({calls} new owner lookups)", file=sys.stderr)

    out = {
        "seed": SEED, "built": "2026-07-27", "min_owner_stars": MIN_OWNER_STARS,
        "candidates": len(rows), "live": len(live), "repos_measured": products,
        "sample_size": len(sample),
        "strata_counts": {f"{lo}-{hi}": len(buckets[(lo, hi)]) for lo, hi in STRATA},
        "method": ("Docs repos enumerated by docs-framework config fingerprint (Mintlify, Docusaurus, "
                   "VitePress, Nextra, MkDocs). Screened to devtool PRODUCTS by owner prominence "
                   f"(owner's top repo >= {MIN_OWNER_STARS} stars), which keeps low-star docs repos of "
                   "real products (e.g. anycable/docs.anycable.io, 10 stars, org top repo 2366) while "
                   "dropping hobby sites. Stratified by owner_top_stars, sampled with a fixed seed. "
                   "docs-repo stars and owner_top_stars are recorded separately so they can be tested "
                   "as independent predictors. Anchors force-included and flagged."),
        "sample": sorted(sample, key=lambda r: -r["owner_top_stars"]),
    }
    json.dump(out, open(OUT, "w"), indent=2)
    open(OUT, "a").write("\n")
    print(f"\nsample={len(sample)} -> {OUT}", file=sys.stderr)
    for lo, hi in STRATA:
        got = len([r for r in sample if lo <= r["owner_top_stars"] <= hi])
        print(f"  owner_top_stars {lo:>6}-{hi:<11} pool={len(buckets[(lo,hi)]):<5} sampled={got}", file=sys.stderr)


if __name__ == "__main__":
    main()
