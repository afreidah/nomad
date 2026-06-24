#!/usr/bin/env bash
#
# Demonstrate the NamespaceIDTokenizer pagination bug against a LIVE Nomad.
#
# /v1/jobs (the jobs list) paginates with NamespaceIDTokenizer, whose cursor is
# the string "<namespace>.<id>" compared as a whole. memdb iterates the
# (Namespace, ID) index with a separator that sorts below '-', but '.' sorts
# above '-', so for namespaces like "team" vs "team-a" the cursor order and the
# iteration order disagree. Pages then duplicate jobs and can strand a whole
# namespace.
#
# This brings up the same disposable cluster as run.sh, creates jobs in
# namespaces "team" and "team-a", walks /v1/jobs page by page following the
# X-Nomad-NextToken cursor, and lists anything duplicated or never returned.
#
# Usage: ./ns-order-demo.sh /path/to/nomad [--count N] [--per P] [--port P] [--keep]
#
set -u

unset NOMAD_ADDR NOMAD_TOKEN NOMAD_CLIENT_CERT NOMAD_CLIENT_KEY NOMAD_CACERT \
      NOMAD_NAMESPACE NOMAD_REGION NOMAD_TLS_SERVER_NAME 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

BIN=""
COUNT=4         # jobs per namespace
PER=4           # page size (== COUNT puts the page boundary at the team/team-a seam)
PORT=4646
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --per)   PER="$2"; shift 2 ;;
    --port)  PORT="$2"; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    *) [ -z "$BIN" ] && { BIN="$1"; shift; } || { echo "unexpected arg: $1"; exit 2; } ;;
  esac
done
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "ERROR: pass an executable nomad binary" >&2; exit 2; }

ADDR="http://127.0.0.1:${PORT}"
DC="docker compose"
NS="namespace=*"
PG_HDR="$HERE/.pg_hdr"; PG_BODY="$HERE/.pg_body"; PG_IDS="$HERE/.pg_ids"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m%s\033[0m\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
q()    { curl -s -m 5 "$ADDR/$1"; }
teardown(){ $DC down -v >/dev/null 2>&1; rm -f "$PG_HDR" "$PG_BODY" "$PG_IDS"; rm -rf "$HERE/jobs-ns"; }

fetch_page() { # per_page next_token -> body in $PG_BODY, cursor in PG_NEXT
  local url="$ADDR/v1/jobs?$NS&per_page=$1"
  [ -n "$2" ] && url="$url&next_token=$2"
  curl -s -m 5 -D "$PG_HDR" -o "$PG_BODY" "$url"
  PG_NEXT="$(tr -d '\r' < "$PG_HDR" | awk -F': ' 'tolower($1)=="x-nomad-nexttoken"{print $2}')"
}

# ---------------------------------------------------------------------------
step "0. Binary under test"
teardown   # clear any leftover cluster so the bind-mounted binary isn't busy
cp "$BIN" "$HERE/nomad-bin" && chmod +x "$HERE/nomad-bin" || die "could not stage $BIN"
info "version: $("$HERE/nomad-bin" version | head -1)"
info "jobs/namespace=$COUNT  per_page=$PER  api=$ADDR"

step "1. Bring up cluster (1 server + 1 client)"
teardown
HOST_PORT="$PORT" $DC up -d >/dev/null 2>&1 || die "docker compose up failed"
printf '    waiting for leader'
for _ in $(seq 1 40); do q v1/status/leader | grep -q '"' && break; printf '.'; sleep 1; done
printf '\n'
LEADER="$(q v1/status/leader | tr -d '"')"
case "$LEADER" in
  172.*|10.*|192.168.*) ok "leader = $LEADER (local docker — guard ok)" ;;
  *) teardown; die "leader $LEADER is not a local docker address — refusing to continue" ;;
esac
printf '    waiting for client node'
for _ in $(seq 1 40); do
  [ "$(q v1/nodes | jq -r '[.[]|select(.Status=="ready")]|length')" = "1" ] && break
  printf '.'; sleep 1
done
printf '\n'

step "2. Create namespaces 'team' and 'team-a' and submit $COUNT jobs in each"
"$HERE/nomad-bin" namespace apply -address="$ADDR" team   >/dev/null 2>&1 || die "could not create namespace team"
"$HERE/nomad-bin" namespace apply -address="$ADDR" team-a >/dev/null 2>&1 || die "could not create namespace team-a"
rm -rf "$HERE/jobs-ns"; mkdir -p "$HERE/jobs-ns"
W=${#COUNT}
submit() { # namespace
  local ns="$1" i id f n=0
  for i in $(seq 1 "$COUNT"); do
    id="j$(printf "%0${W}d" "$i")"
    f="$HERE/jobs-ns/${ns}-${id}.nomad.hcl"
    cat > "$f" <<EOF
job "$id" {
  namespace   = "$ns"
  datacenters = ["dc1"]
  type        = "service"
  group "g" {
    count = 1
    task "t" {
      driver = "raw_exec"
      config {
        command = "/bin/sleep"
        args    = ["100000"]
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }
  }
}
EOF
    "$HERE/nomad-bin" job run -address="$ADDR" -detach "$f" >/dev/null 2>&1 && n=$((n+1))
  done
  info "namespace $ns: submitted $n/$COUNT"
}
submit team
submit team-a

TOTAL=$(( COUNT * 2 ))
printf '    waiting for all %d jobs to register' "$TOTAL"
for _ in $(seq 1 30); do
  [ "$(q "v1/jobs?$NS&per_page=1000" | jq 'length')" = "$TOTAL" ] && break
  printf '.'; sleep 1
done
printf '\n'
ok "/v1/jobs total = $(q "v1/jobs?$NS&per_page=1000" | jq 'length')"

step "3. The order /v1/jobs returns them in (one big page)"
q "v1/jobs?$NS&per_page=1000" | jq -r '.[] | "      \(.Namespace)/\(.ID)"'

step "4. Now page through /v1/jobs with per_page=$PER, following next_token"
: > "$PG_IDS"
tok=""; page=0; PG_END=""
while :; do
  page=$(( page + 1 ))
  [ "$page" -gt 50 ] && { PG_END="cap"; break; }
  fetch_page "$PER" "$tok"
  cnt="$(jq -r '.[] | "\(.Namespace)/\(.ID)"' < "$PG_BODY" 2>/dev/null | tee -a "$PG_IDS" | wc -l | tr -d ' ')"
  printf '    page %2d: %2d job(s)   next_token=%s\n' "$page" "$cnt" "${PG_NEXT:-<none>}"
  [ -z "$PG_NEXT" ]       && { PG_END="ok";     break; }
  [ "$PG_NEXT" = "$tok" ] && { PG_END="repeat"; break; }
  tok="$PG_NEXT"
done

step "5. Result"
DUPE="$(sort "$PG_IDS" | uniq -d | tr '\n' ' ')"
MISS="$(comm -23 <(q "v1/jobs?$NS&per_page=1000" | jq -r '.[] | "\(.Namespace)/\(.ID)"' | sort) <(sort -u "$PG_IDS") | tr '\n' ' ')"
case "$PG_END" in
  ok)     info "walk ended after $page page(s): server returned no next_token." ;;
  repeat) printf '    \033[1;31mwalk could not finish\033[0m: page %s returned the same next_token (%s) it was given — repeats forever.\n' "$page" "$tok" ;;
  cap)    printf '    \033[1;31mwalk hit the 50-page safety cap\033[0m: cursor never terminated.\n' ;;
esac
[ -n "$DUPE" ] && printf '    \033[1;31mduplicated\033[0m (returned on >1 page): %s\n' "$DUPE" || ok "duplicated: none"
[ -n "$MISS" ] && printf '    \033[1;31mnever returned\033[0m (exist in /v1/jobs but no page showed them): %s\n' "$MISS" || ok "never returned: none"

step "6. Cleanup"
if [ "$KEEP" = "1" ]; then
  info "leaving cluster up (--keep). API: $ADDR ; tear down with: $DC down -v"
else
  teardown
  ok "cluster torn down"
fi
