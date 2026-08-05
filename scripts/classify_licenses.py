#!/usr/bin/env python3
"""Classify repository licenses by reading the actual LICENSE text, not GitHub's metadata.

Why this exists: GitHub's classifier reports `NOASSERTION` ("Other") for every source-available /
"OSaaS" license. Fizzy, Sentry, Terraform, n8n, CockroachDB and Elasticsearch all come back
identical to a repo with a hand-rolled licence file. Any analysis keyed on GitHub's `spdx_id`
therefore collapses the entire commercial-source-available category into "unknown", which is exactly
the category we want to measure.

Classes (chosen to match what corpus builders actually gate on):
  permissive       MIT / Apache / BSD / ISC / Unlicense  -> kept by The Stack
  no_license       no LICENSE file found                 -> kept by The Stack v2/v3, dropped by v1
  copyleft         GPL / AGPL / LGPL / MPL               -> dropped as non_permissive
  source_available FSL / BUSL / SSPL / Elastic / O'Saasy -> dropped as non_permissive
  content          CC-BY / CC-BY-SA / CC-BY-NC           -> CC-BY(-SA) usually kept, NC dropped
  proprietary      all rights reserved                   -> dropped

Note on ordering: source_available is tested BEFORE permissive on purpose. The O'Saasy license
embeds the MIT grant verbatim and then adds restrictions, so a naive "does it contain the MIT
words" check calls it permissive, the opposite of its intent.

    python3 scripts/classify_licenses.py data/docs_repo_frame.json
"""
import json, re, subprocess, sys, time
from urllib import request

# Rails ships MIT-LICENSE, not LICENSE; missing that filename misreported it as unlicensed, so this
# list is deliberately generous. A missed filename looks exactly like "no license", which is the
# single most consequential misclassification for this study.
LICENSE_FILES = ["LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "LICENCE.md", "LICENSE.markdown",
                 "COPYING", "COPYING.txt", "LICENSE-AGPL", "LICENSE.rst",
                 "MIT-LICENSE", "MIT-LICENSE.txt", "MIT-LICENSE.md", "LICENSE-MIT", "LICENSE-APACHE",
                 "UNLICENSE", "LICENSE.BSD", "license", "license.md", "license.txt"]

# Order matters: the first match wins. Restrictive-but-MIT-quoting licenses must be caught first.
PATTERNS = [
    ("source_available", r"o'?saasy|functional source license|\bFSL-1\.1|business source license|"
                         r"\bBUSL|server side public license|\bSSPL|elastic license|sustainable use license|"
                         r"commons clause|fair source|\bBSL\b|polyform"),
    ("proprietary",      r"all rights reserved(?!.{0,400}(permission is hereby granted|redistribution))"),
    ("copyleft",         r"gnu affero|affero general public|gnu general public license|"
                         r"lesser general public|mozilla public license|\bAGPL\b|\bGPL\b|\bLGPL\b"),
    ("content",          r"creative commons|\bCC[- ]BY\b|attribution-sharealike|attribution 4\.0"),
    ("permissive",       r"permission is hereby granted, free of charge|apache license|"
                         r"redistribution and use in source and binary forms|\bISC License\b|"
                         r"this is free and unencumbered software"),
]


def gh_json(path):
    p = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return None


def fetch(url):
    try:
        req = request.Request(url, headers={"User-Agent": "ruby-scorecard/1.0 license-audit"})
        with request.urlopen(req, timeout=25) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return None


def license_text(repo, branch):
    for f in LICENSE_FILES:
        t = fetch(f"https://raw.githubusercontent.com/{repo}/{branch}/{f}")
        if t and len(t.strip()) > 40:
            return f, t
    return None, None


def classify(text):
    if not text:
        return "no_license", None
    head = text[:8000]
    for cls, pat in PATTERNS:
        m = re.search(pat, head, re.I | re.S)
        if m:
            return cls, m.group(0)[:60]
    return "unknown", None


def label(text):
    """Human-readable licence name for the source-available family."""
    if not text:
        return None
    h = text[:3000]
    for name, pat in [("O'Saasy", r"o'?saasy"), ("FSL-1.1", r"functional source license|FSL-1\.1"),
                      ("BUSL-1.1", r"business source license|BUSL"), ("SSPL", r"server side public"),
                      ("Elastic License", r"elastic license"), ("Sustainable Use", r"sustainable use"),
                      ("Commons Clause", r"commons clause"), ("PolyForm", r"polyform")]:
        if re.search(pat, h, re.I):
            return name
    return None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/docs_repo_frame.json"
    blob = json.load(open(path))
    rows = blob["sample"] if "sample" in blob else blob["candidates"]

    for i, r in enumerate(rows):
        branch = r.get("default_branch")
        if not branch:
            info = gh_json(f"repos/{r['repo']}")
            branch = (info or {}).get("default_branch", "main")
            r["default_branch"] = branch
        fname, text = license_text(r["repo"], branch)
        cls, ev = classify(text)
        r["license_class"] = cls
        r["license_file"] = fname
        r["license_label"] = label(text) or r.get("license")
        r["license_evidence"] = ev
        if (i + 1) % 25 == 0:
            print(f"  {i+1}/{len(rows)}", file=sys.stderr)

    json.dump(blob, open(path, "w"), indent=2)
    open(path, "a").write("\n")

    from collections import Counter
    print("\nlicense_class distribution:", file=sys.stderr)
    for k, v in Counter(r["license_class"] for r in rows).most_common():
        print(f"  {k:<18} {v}", file=sys.stderr)
    sa = [r for r in rows if r["license_class"] == "source_available"]
    if sa:
        print("\nsource-available repos found:", file=sys.stderr)
        for r in sa:
            print(f"  {r['repo']:<38} {r.get('license_label')}  (github said: {r.get('license')})", file=sys.stderr)


if __name__ == "__main__":
    main()
