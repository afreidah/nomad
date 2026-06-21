#!/usr/bin/env bash
#
# Build two nomad binaries from two git refs and run the repro harness against
# each — the upstream (hashicorp) one first, then the fork (with the fix).
#
# Usage:
#   ./ab.sh [run.sh args...]
#   ./ab.sh --count 30 --settle 25
#
# Refs/output are overridable via env:
#   HASHICORP_REF   ref to build the "current upstream main" binary (default: origin/main)
#   FORK_REF        ref to build the "fork main / fixed" binary       (default: fork/main)
#   OUT             where to write the built binaries                 (default: /tmp)
#
# A maintainer cloning a single remote can point both at local refs, e.g.:
#   HASHICORP_REF=main FORK_REF=fix-jobs-statuses-modifyindex-collision ./ab.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"

HASHICORP_REF="${HASHICORP_REF:-origin/main}"
FORK_REF="${FORK_REF:-fork/main}"
OUT="${OUT:-/tmp}"

bold() { printf '\n\033[1;35m========================================================================\033[0m\n'; }

build() { # label  ref  outfile
  local label="$1" ref="$2" out="$3"
  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || { echo "ERROR: ref '$ref' not found (set HASHICORP_REF/FORK_REF)"; exit 2; }
  local sha; sha="$(git -C "$REPO" rev-parse --short "$ref")"
  local wt="$REPO/.repro-wt-$label"
  echo ">> building $label from $ref ($sha) -> $out"
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$REPO" worktree add --detach -f "$wt" "$ref" >/dev/null
  ( cd "$wt" && CGO_ENABLED=0 go build -o "$out" . )
  git -C "$REPO" worktree remove --force "$wt"
  echo "   $("$out" version | head -1)  ($label = $ref @ $sha)"
}

bold; echo "Building both binaries"; bold
build hashicorp "$HASHICORP_REF" "$OUT/nomad-hashicorp-main"
build fork      "$FORK_REF"      "$OUT/nomad-fork-main"

# Upstream first, then the fork.
for entry in "hashicorp (current upstream main, expect BUG):$OUT/nomad-hashicorp-main" \
             "fork (your main, expect FIXED):$OUT/nomad-fork-main"; do
  label="${entry%%:*}"; bin="${entry##*:}"
  bold; echo "Running harness against: $label"; echo "  $bin"; bold
  "$HERE/run.sh" "$bin" "$@"
done

bold; echo "Done. Upstream dropped jobs from /v1/jobs/statuses; the fork kept them."; bold
