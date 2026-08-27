#!/usr/bin/env bash
# Unpack the recovered corpus source and the raw measurement results.
#
# Both are stored as archives rather than as loose files on purpose. The
# recovered files are immutable snapshots of historically-buggy code, and the
# measurement indexes them BY LINE NUMBER. The repo's shared pre-commit hooks
# (shfmt via lint-shell.sh, prettier) auto-format staged source in place, and
# on the first commit attempt they silently reformatted six of them — shifting
# the lines the corpus points at and breaking the evidence round-trip. An
# archive is opaque to a formatter that selects files by type.
#
# results.tar.gz holds the 141 raw reviewer outputs (47 members x 3 variants).
# score-pooled.py reads results/<variant>/*.json, so unpack before scoring.
#
# Usage: ./unpack-corpus.sh   (then run ./measure.sh or ./score-pooled.py)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "${HERE}/files" ]]; then
  printf 'files/ already present — remove it first to re-unpack\n' >&2
  exit 1
fi

tar -xzf "${HERE}/files.tar.gz" -C "${HERE}"
n_files=$(find "${HERE}/files" -type f | wc -l)
printf 'unpacked %s recovered files\n' "${n_files// /}"

if [[ -d "${HERE}/results" ]]; then
  printf 'results/ already present — left as-is\n' >&2
elif [[ -f "${HERE}/results.tar.gz" ]]; then
  tar -xzf "${HERE}/results.tar.gz" -C "${HERE}"
  n_results=$(find "${HERE}/results" -name '*.json' | wc -l)
  printf 'unpacked %s raw reviewer results\n' "${n_results// /}"
fi

# Validate: every corpus member must contain its evidence at its recorded line.
python3 - "${HERE}" <<'PYEOF'
import json, os, re, sys
here = sys.argv[1]
corpus = json.load(open(os.path.join(here, "corpus.json")))


def slug(i):
    return i.replace("#", "-").replace("/", "-")


def norm(s):
    return re.sub(r"\\\\", r"\\", s).strip()


bad = []
for m in corpus:
    f = os.path.join(here, "files", slug(m["id"]), os.path.basename(m["path"]))
    if not os.path.exists(f):
        bad.append(m["id"])
        continue
    lines = open(f, encoding="utf-8", errors="replace").read().split("\n")
    i = m["line"] - 1
    actual = lines[i] if 0 <= i < len(lines) else ""
    if not (norm(m["evidence"]) in norm(actual) or norm(actual) in norm(m["evidence"])):
        bad.append(m["id"])

print(f"evidence round-trip: {len(corpus) - len(bad)}/{len(corpus)}")
if bad:
    print("BROKEN — the corpus cannot be measured against:", file=sys.stderr)
    for b in bad:
        print(f"  {b}", file=sys.stderr)
    sys.exit(1)
PYEOF
