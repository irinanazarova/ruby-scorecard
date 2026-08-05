#!/usr/bin/env python3
"""Targeted supplement: devtool products under source-available / "OSaaS" licenses.

The random docs-repo frame contains ZERO repos under FSL, BUSL, SSPL, Elastic or O'Saasy licenses,
because those licenses are rare in absolute terms even though they cover very prominent products.
So the license question cannot be answered from the random sample alone.

This is a PURPOSIVE sample, not a random one. It supports a *comparison between license classes*
(do source-available docs get memorized less than permissive ones?) and does NOT support any
population estimate. Every row is flagged `purposive: true` so it can never be pooled by accident.

Matched permissive controls are included deliberately: comparable products, comparable prominence,
different license. Without them a low hit rate for source-available repos would be uninterpretable,
since these are also mostly large monorepos whose docs prose differs in kind.

    python3 scripts/build_osaas_frame.py     -> data/osaas_frame.json
"""
import json, subprocess, sys

# (repo, expected class) - expectation recorded so a classifier disagreement is visible, not silent.
TARGETS = [
    # --- source-available / OSaaS ---
    ("basecamp/fizzy",            "source_available"),
    ("getsentry/sentry",          "source_available"),
    ("getsentry/sentry-docs",     "source_available"),
    ("hashicorp/terraform",       "source_available"),
    ("hashicorp/vault",           "source_available"),
    ("cockroachdb/cockroach",     "source_available"),
    ("elastic/elasticsearch",     "source_available"),
    ("n8n-io/n8n",                "source_available"),
    ("airbytehq/airbyte",         "source_available"),
    ("directus/directus",         "source_available"),
    ("timescale/timescaledb",     "source_available"),
    ("mongodb/mongo",             "source_available"),
    ("redis/redis",               "source_available"),
    ("dgraph-io/dgraph",          "source_available"),
    ("outline/outline",           "source_available"),
    # --- copyleft (also non_permissive to a corpus builder, different legal family) ---
    ("grafana/grafana",           "copyleft"),
    ("calcom/cal.com",            "copyleft"),
    ("plausible/analytics",       "copyleft"),
    ("metabase/metabase",         "copyleft"),
    ("minio/minio",               "copyleft"),
    ("immich-app/immich",         "copyleft"),
    ("nocodb/nocodb",             "copyleft"),
    # --- permissive controls: comparable products, comparable prominence ---
    ("supabase/supabase",         "permissive"),
    ("hoppscotch/hoppscotch",     "permissive"),
    ("meilisearch/meilisearch",   "permissive"),
    ("PostHog/posthog",           "permissive"),
    ("clickhouse/clickhouse",     "permissive"),
    ("apache/superset",           "permissive"),
    ("langfuse/langfuse",         "permissive"),
    ("triggerdotdev/trigger.dev", "permissive"),
]


def gh(path):
    p = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return None


def main():
    rows = []
    for repo, expected in TARGETS:
        i = gh(f"repos/{repo}")
        if not i or i.get("message"):
            print(f"  MISSING {repo}", file=sys.stderr)
            continue
        rows.append({
            "repo": i["full_name"], "owner": i["owner"]["login"],
            "stars": i["stargazers_count"], "forks": i["forks_count"],
            "license": (i.get("license") or {}).get("spdx_id") or "NONE",
            "owner_type": i["owner"]["type"],
            "created": i["created_at"][:10], "pushed": i["pushed_at"][:10],
            "default_branch": i["default_branch"], "size_kb": i.get("size", 0),
            "owner_top_stars": i["stargazers_count"],
            "expected_class": expected, "purposive": True, "anchor": False,
            "source": "osaas_supplement",
        })
        print(f"  {i['full_name']:<32} github_spdx={(i.get('license') or {}).get('spdx_id') or 'NONE':<16} "
              f"stars={i['stargazers_count']}", file=sys.stderr)

    out = {
        "built": "2026-08-04", "sample_size": len(rows),
        "method": ("PURPOSIVE supplement of devtool products under source-available/OSaaS and copyleft "
                   "licenses, with matched permissive controls. The random docs-repo frame contained no "
                   "FSL/BUSL/SSPL/Elastic/O'Saasy repos at all. Supports license-class COMPARISON only, "
                   "never a population estimate. GitHub reports NOASSERTION for nearly every "
                   "source-available license, so classes come from scripts/classify_licenses.py reading "
                   "the actual licence text."),
        "sample": rows,
    }
    json.dump(out, open("data/osaas_frame.json", "w"), indent=2)
    open("data/osaas_frame.json", "a").write("\n")
    print(f"\n{len(rows)} repos -> data/osaas_frame.json", file=sys.stderr)


if __name__ == "__main__":
    main()
