#!/usr/bin/env python3
"""Pooled scoring for the #440 measurement.

Per-member scoring undercounts. Several corpus members live in the SAME
recovered file (identical commit): #126, #127 and #131 all sit in
run-review.sh at 789d77ae. A reviewer reading that file may legitimately
report any of them, but per-member scoring credits only the one indexed to
that run and records the others as misses.

Pooled scoring asks the question the decision rule actually cares about:
when the reviewer is handed a file containing known no-successor defects,
how many of those defects does it find?

A member counts as FOUND if any run whose recovered file is byte-identical
to that member's file reports a finding within tolerance of its line.
"""
import json
import os
import sys
import hashlib
import re

HERE = os.path.dirname(os.path.abspath(__file__))
TOL = int(os.environ.get("LINE_TOLERANCE", "25"))


def slug(i): return i.replace("#", "-").replace("/", "-")


def digest(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def findings(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        return []
    return (d.get("structured_output") or {}).get("findings") or []


def main(variant):
    with open(os.path.join(HERE, "corpus.json"), encoding="utf-8") as fh:
        corpus = json.load(fh)
    rdir = os.path.join(HERE, "results", variant)

    # Map each member to the digest of its recovered file.
    dig = {}
    for m in corpus:
        f = os.path.join(HERE, "files", slug(m["id"]), os.path.basename(m["path"]))
        if os.path.exists(f):
            dig[m["id"]] = digest(f)

    # Collect findings from every completed run, keyed by that run's file digest.
    by_digest = {}
    for m in corpus:
        r = os.path.join(rdir, slug(m["id"]) + ".json")
        if not os.path.exists(r) or m["id"] not in dig:
            continue
        by_digest.setdefault(dig[m["id"]], []).extend(findings(r))

    ran = [m for m in corpus if os.path.exists(os.path.join(rdir, slug(m["id"]) + ".json"))]
    # A member is scorable if some run covered a file identical to its own.
    scorable = [m for m in corpus if dig.get(m["id"]) in by_digest]

    found, missed = [], []
    for m in scorable:
        base = os.path.basename(m["path"])
        want = m["line"]
        hit = False
        for f in by_digest[dig[m["id"]]]:
            loc = f.get("location") or ""
            parts = loc.split(":")
            if len(parts) < 2:
                continue
            if parts[0].split("/")[-1] != base:
                continue
            try:
                line = int(re.sub(r"[^0-9].*$", "", parts[1]) or -1)
            except ValueError:
                continue
            if want - TOL <= line <= want + TOL:
                hit = True
                break
        (found if hit else missed).append(m)

    print(f"=== {variant} (pooled) ===")
    print(f"runs completed: {len(ran)}   members scorable: {len(scorable)}")
    for m in sorted(scorable, key=lambda x: x["id"]):
        mark = "FOUND" if m in found else "miss "
        print(f"  {mark} {m['id']:<24} {m['path']}:{m['line']}  [{m['category']}]")
    n = len(scorable)
    pct = (100 * len(found) // n) if n else 0
    print(f"\npooled re-find: {len(found)}/{n} ({pct}%)")
    return len(found), n


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "narrowed")
