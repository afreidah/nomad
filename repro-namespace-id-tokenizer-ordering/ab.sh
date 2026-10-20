#!/usr/bin/env bash
#
# A/B demo for hashicorp/nomad#28211: NamespaceIDTokenizer compares the
# "<namespace>.<id>" cursor as one joined string, so '.' (0x2E) takes part in
# the comparison. For namespaces "team" and "team-a", '-' (0x2D) < '.', so the
# cursor orders "team-a.*" before "team.*" while the state store iterates
# "team" first. Paging across that seam repeats the same next_token forever,
# duplicates "team" objects, and never returns the "team-a" ones.
#
# Builds a nomad binary for two refs, runs each as a single dev-style server in
# docker, creates jobs and variables in namespaces "team" and "team-a", walks
# /v1/jobs and /v1/vars page by page following X-Nomad-NextToken, and prints a
# verdict. Exit 0 iff the base ref shows the bug and the fix ref does not.
#
# Usage:
#   ./ab.sh [--count N] [--per P] [--port P] [--keep]
#
#   --count N    jobs and variables per namespace (default 4)
#   --per P      page size (default 4; == count puts a page boundary at the
#                team/team-a seam)
#   --port P     host port for the server API (default 4646)
#   --keep       leave the last cluster running at the end
#
# Env overrides:
#   BASE_REF     ref with the bug   (default: origin/main)
#   FIX_REF      ref with the fix   (default: fork/fix-namespace-id-tokenizer-ordering)
#   OUT          binary output dir  (default: ./.bin)
#   SKIP_BUILD=1 reuse $OUT/nomad-base and $OUT/nomad-fix
#
set -u

# Hard isolation from any real cluster: drop inherited NOMAD_* vars; a leader
# guard below refuses to continue unless the server is on a docker subnet.
unset NOMAD_ADDR NOMAD_TOKEN NOMAD_CLIENT_CERT NOMAD_CLIENT_KEY NOMAD_CACERT \
      NOMAD_NAMESPACE NOMAD_REGION NOMAD_TLS_SERVER_NAME 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
cd "$HERE"

COUNT=4
PER=4
PORT=4646
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --per)   PER="$2"; shift 2 ;;
    --port)  PORT="$2"; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unexpected arg: $1"; exit 2 ;;
  esac
done

BASE_REF="${BASE_REF:-origin/main}"
FIX_REF="${FIX_REF:-fork/fix-namespace-id-tokenizer-ordering}"
OUT="${OUT:-$HERE/.bin}"
ADDR="http://127.0.0.1:${PORT}"
DC="docker compose"
PAGE_CAP=50

step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    \033[32m%s\033[0m\n' "$*"; }
bad()   { printf '    \033[1;31m%s\033[0m\n' "$*"; }
die()   { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
bold()  { printf '\n\033[1;35m========================================================================\033[0m\n'; }

q() { curl -s -m 5 "$ADDR/$1"; }
teardown() { $DC down -v >/dev/null 2>&1; }

for c in docker go jq curl; do command -v "$c" >/dev/null || die "$c is required"; done
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# Build a static nomad binary for a ref in a throwaway worktree, so the
# working tree is untouched.
# ---------------------------------------------------------------------------
build() { # label  ref  outfile
  local label="$1" ref="$2" out="$3"
  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || die "ref '$ref' not found; fetch it or set BASE_REF/FIX_REF"
  local sha; sha="$(git -C "$REPO" rev-parse --short "$ref")"
  local wt="$REPO/.repro-wt-nsid-$label"
  info "building $label from $ref ($sha) -> $out"
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$REPO" worktree add --detach -f "$wt" "$ref" >/dev/null 2>&1 \
    || die "could not create worktree $wt for $ref"
  if ! ( cd "$wt" && CGO_ENABLED=0 go build -o "$out" . ) >"$OUT/nomad-$label.build.log" 2>&1; then
    git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
    die "build of $ref failed; see $OUT/nomad-$label.build.log"
  fi
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
  ok "$("$out" version | head -1)  ($label = $ref @ $sha)"
}

# ---------------------------------------------------------------------------
# Seed namespaces "team" and "team-a" with COUNT jobs and COUNT variables each.
# Jobs only need to be registered, not running, so there is no client.
# ---------------------------------------------------------------------------
seed() {
  local W=${#COUNT} ns i id n
  for ns in team team-a; do
    curl -s -m 5 -o /dev/null -X PUT "$ADDR/v1/namespace/$ns" -d "{\"Name\":\"$ns\"}" \
      || die "could not create namespace $ns"
  done
  for ns in team team-a; do
    n=0
    for i in $(seq 1 "$COUNT"); do
      id="j$(printf "%0${W}d" "$i")"
      curl -s -m 5 -o /dev/null -X POST "$ADDR/v1/jobs?namespace=$ns" -d @- <<EOF && n=$((n+1))
{"Job":{"ID":"$id","Name":"$id","Namespace":"$ns","Type":"service","Datacenters":["*"],
 "TaskGroups":[{"Name":"g","Count":1,
  "Tasks":[{"Name":"t","Driver":"raw_exec",
   "Config":{"command":"/bin/sleep","args":["86400"]},
   "Resources":{"CPU":10,"MemoryMB":16}}]}]}}
EOF
    done
    info "namespace $ns: submitted $n/$COUNT jobs"
  done
  for ns in team team-a; do
    n=0
    for i in $(seq 1 "$COUNT"); do
      id="v$(printf "%0${W}d" "$i")"
      # the keyring can lag leader election by a moment; retry briefly
      for _ in $(seq 1 10); do
        curl -s -m 5 -o /dev/null -w '%{http_code}' -X PUT "$ADDR/v1/var/$id?namespace=$ns" \
          -d "{\"Items\":{\"k\":\"v\"}}" | grep -q '^200$' && { n=$((n+1)); break; }
        sleep 1
      done
    done
    info "namespace $ns: wrote $n/$COUNT variables"
  done
}

# ---------------------------------------------------------------------------
# walk <name> <path> <jq id expr>
# Pages through <path> with per_page=PER following X-Nomad-NextToken and
# compares what came back against one unpaginated listing. Sets WALK=CLEAN|BROKEN.
# ---------------------------------------------------------------------------
walk() {
  local name="$1" path="$2" idx="$3"
  local hdr body seen all
  hdr="$(mktemp)"; body="$(mktemp)"; seen="$(mktemp)"; all="$(mktemp)"

  q "$path?namespace=*" | jq -r ".[] | $idx" | sort > "$all"
  info "$name: $(wc -l < "$all" | tr -d ' ') total, in server order:"
  q "$path?namespace=*" | jq -r ".[] | $idx" | sed 's/^/        /'

  local tok="" page=0 next cnt end=""
  while :; do
    page=$((page + 1))
    [ "$page" -gt "$PAGE_CAP" ] && { end=cap; break; }
    local url="$ADDR/$path?namespace=*&per_page=$PER"
    [ -n "$tok" ] && url="$url&next_token=$tok"
    curl -s -m 5 -D "$hdr" -o "$body" "$url"
    next="$(tr -d '\r' < "$hdr" | awk -F': ' 'tolower($1)=="x-nomad-nexttoken"{print $2}')"
    cnt="$(jq -r ".[] | $idx" < "$body" | tee -a "$seen" | wc -l | tr -d ' ')"
    printf '      page %2d: %2d item(s)  next_token=%s\n' "$page" "$cnt" "${next:-<none>}"
    [ -z "$next" ]       && { end=ok; break; }
    [ "$next" = "$tok" ] && { end=repeat; break; }
    tok="$next"
  done

  local dupe miss
  dupe="$(sort "$seen" | uniq -d | tr '\n' ' ')"
  miss="$(comm -23 "$all" <(sort -u "$seen") | tr '\n' ' ')"
  rm -f "$hdr" "$body" "$seen" "$all"

  WALK=CLEAN
  case "$end" in
    ok)     ok "$name: walk ended after $page page(s)" ;;
    repeat) bad "$name: page $page returned the next_token it was given ($tok); repeats forever"; WALK=BROKEN ;;
    cap)    bad "$name: walk hit the $PAGE_CAP-page cap; cursor never terminated"; WALK=BROKEN ;;
  esac
  if [ -n "$dupe" ]; then bad "$name: duplicated: $dupe"; WALK=BROKEN; else ok "$name: duplicated: none"; fi
  if [ -n "$miss" ]; then bad "$name: never returned: $miss"; WALK=BROKEN; else ok "$name: never returned: none"; fi
}

# run_one <label> <binary> -> sets RESULT to BUG|FIXED
run_one() {
  local label="$1" bin="$2"
  bold; echo "Running against: $label"; echo "  $bin"; bold

  step "1. Bring up server"
  # tear down first: a running server holds ./nomad-bin open
  teardown
  cp "$bin" "$HERE/nomad-bin" && chmod +x "$HERE/nomad-bin" || die "could not copy $bin"
  HOST_PORT="$PORT" $DC up -d >/dev/null 2>&1 || die "docker compose up failed (port $PORT in use? try --port)"
  printf '    waiting for leader'
  for _ in $(seq 1 40); do q v1/status/leader | grep -q '"' && break; printf '.'; sleep 1; done
  printf '\n'
  local leader; leader="$(q v1/status/leader | tr -d '"')"
  case "$leader" in
    172.*|10.*|192.168.*) ok "leader = $leader (local docker - guard ok)" ;;
    *) teardown; die "leader '$leader' is not a local docker address - refusing to continue" ;;
  esac

  step "2. Seed namespaces 'team' and 'team-a' with $COUNT jobs and $COUNT variables each"
  seed

  step "3. Page /v1/jobs (per_page=$PER)"
  walk jobs v1/jobs '"\(.Namespace)/\(.ID)"'; local wj="$WALK"

  step "4. Page /v1/vars (per_page=$PER)"
  walk vars v1/vars '"\(.Namespace)/\(.Path)"'; local wv="$WALK"

  step "5. Result"
  if [ "$wj" = CLEAN ] && [ "$wv" = CLEAN ]; then
    printf '    \033[1;32mFIXED\033[0m: every object returned exactly once and both walks ended\n'
    RESULT=FIXED
  else
    printf '    \033[1;31mBUG PRESENT\033[0m: jobs=%s vars=%s\n' "$wj" "$wv"
    RESULT=BUG
  fi
}

# ---------------------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  bold; echo "Building both binaries"; bold
  build base "$BASE_REF" "$OUT/nomad-base"
  build fix  "$FIX_REF"  "$OUT/nomad-fix"
fi

run_one "base ($BASE_REF, expect BUG)"  "$OUT/nomad-base"; R_BASE="$RESULT"
teardown
run_one "fix ($FIX_REF, expect FIXED)" "$OUT/nomad-fix";  R_FIX="$RESULT"

bold
echo "base: $R_BASE   fix: $R_FIX"
bold
if [ "$KEEP" = "1" ]; then
  info "leaving the fix server up (--keep): $ADDR"
  info "tear down later with:  $DC down -v   (from $HERE)"
else
  teardown
  rm -f "$HERE/nomad-bin"
fi
[ "$R_BASE" = "BUG" ] && [ "$R_FIX" = "FIXED" ]
