#!/usr/bin/env bash
#
# Demonstrate the jobs page "Error fetching jobs ... status undefined" toast:
# the jobs index aborts superseded blocking queries on every page/filter
# change, and an abort that lands during the body read reaches the controller
# as a SyntaxError, which the old `e.name !== 'AbortError'` guard reports.
#
# Builds a nomad binary WITH THE UI EMBEDDED for two refs, runs each in the
# compose cluster, drives /ui/jobs in headless Chrome, and prints a verdict.
# The browser talks to the agent directly (no ember dev proxy).
#
# Usage:
#   ./ui-toast.sh [--count N] [--rounds R] [--port P] [--keep]
#
#   --count N    service jobs to seed (default 30, i.e. 3 pages of 10)
#   --rounds R   page/filter passes per binary (default 3)
#   --port P     host port for the server API/UI (default 4646)
#   --keep       leave the last cluster running at the end
#
# Env overrides:
#   BASE_REF     ref with the bug   (default: origin/main)
#   FIX_REF      ref with the fix   (default: fork/fix-jobs-index-abort-toast)
#   OUT          binary output dir  (default: /tmp)
#   CHROME       Chrome/Chromium    (default: first found on PATH)
#   SKIP_BUILD=1 reuse $OUT/nomad-ui-base and $OUT/nomad-ui-fix
#
set -u

# Hard isolation from any real cluster (see run.sh).
unset NOMAD_ADDR NOMAD_TOKEN NOMAD_CLIENT_CERT NOMAD_CLIENT_KEY NOMAD_CACERT \
      NOMAD_NAMESPACE NOMAD_REGION NOMAD_TLS_SERVER_NAME 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
cd "$HERE"

COUNT=30
ROUNDS=3
PORT=4646
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --count)  COUNT="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unexpected arg: $1"; exit 2 ;;
  esac
done

BASE_REF="${BASE_REF:-origin/main}"
FIX_REF="${FIX_REF:-fork/fix-jobs-index-abort-toast}"
OUT="${OUT:-/tmp}"
ADDR="http://127.0.0.1:${PORT}"
DC="docker compose"
DEPS="$HERE/.ui-deps"

step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    \033[32m%s\033[0m\n' "$*"; }
warn()  { printf '    \033[33m%s\033[0m\n' "$*"; }
die()   { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
bold()  { printf '\n\033[1;35m========================================================================\033[0m\n'; }

q() { curl -s -m 5 "$ADDR/$1"; }
teardown() { $DC down -v >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Prerequisites: Chrome, node, and a private playwright-core install.
# ---------------------------------------------------------------------------
CHROME="${CHROME:-$(command -v google-chrome google-chrome-stable chromium chromium-browser 2>/dev/null | head -1)}"
[ -n "$CHROME" ] && [ -x "$CHROME" ] || die "no Chrome/Chromium found; set CHROME=/path/to/chrome"
command -v node >/dev/null || die "node is required"
command -v pnpm >/dev/null || [ "${SKIP_BUILD:-0}" = "1" ] || die "pnpm is required to build the UI"
if [ ! -d "$DEPS/node_modules/playwright-core" ]; then
  info "installing playwright-core into $DEPS"
  npm install --silent --prefix "$DEPS" playwright-core@1.55.0 >/dev/null 2>&1 \
    || die "npm install playwright-core failed"
fi

# ---------------------------------------------------------------------------
# Build a binary with the UI embedded (mirrors `make dev-ui`) in a throwaway
# worktree, so the working tree is untouched.
# ---------------------------------------------------------------------------
build_ui() { # label  ref  outfile
  local label="$1" ref="$2" out="$3"
  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || die "ref '$ref' not found (set BASE_REF/FIX_REF)"
  local sha; sha="$(git -C "$REPO" rev-parse --short "$ref")"
  local wt="$REPO/.repro-wt-ui-$label"
  info "building $label from $ref ($sha) -> $out  (UI build takes a few minutes)"
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$REPO" worktree add --detach -f "$wt" "$ref" >/dev/null
  if ! ( cd "$wt" \
         && pnpm install --frozen-lockfile --silent \
         && pnpm -F nomad-ui build >/dev/null \
         && go-bindata-assetfs -pkg agent -prefix ui -modtime 1480000000 -tags ui \
              -o bindata_assetfs.go ./ui/dist/... \
         && mv bindata_assetfs.go command/agent \
         && CGO_ENABLED=0 go build -tags ui -o "$out" . ) >"$OUT/nomad-ui-$label.build.log" 2>&1; then
    git -C "$REPO" worktree remove --force "$wt"
    die "build of $ref failed; see $OUT/nomad-ui-$label.build.log"
  fi
  git -C "$REPO" worktree remove --force "$wt"
  ok "$("$out" version | head -1)  ($label = $ref @ $sha)"
}

seed_jobs() {
  local W=${#COUNT} i id
  for i in $(seq 1 "$COUNT"); do
    id="web-$(printf "%0${W}d" "$i")"
    curl -s -m 5 -o /dev/null -X POST "$ADDR/v1/jobs" -d @- <<EOF
{"Job":{"ID":"$id","Name":"$id","Type":"service","Datacenters":["*"],
 "TaskGroups":[{"Name":"g","Count":1,
  "Tasks":[{"Name":"t","Driver":"raw_exec",
   "Config":{"command":"/bin/sleep","args":["86400"]},
   "Resources":{"CPU":10,"MemoryMB":16}}]}]}}
EOF
  done
}

# run_one <label> <binary> -> sets RESULT to BUG|FIXED|INCONCLUSIVE
run_one() {
  local label="$1" bin="$2"
  bold; echo "Running UI check against: $label"; echo "  $bin"; bold

  step "1. Bring up cluster (1 server + 1 client)"
  # tear down first: a running cluster holds ./nomad-bin open
  teardown
  cp "$bin" "$HERE/nomad-bin" && chmod +x "$HERE/nomad-bin" || die "could not copy $bin"
  HOST_PORT="$PORT" $DC up -d >/dev/null 2>&1 || die "docker compose up failed"
  printf '    waiting for leader'
  for _ in $(seq 1 40); do q v1/status/leader | grep -q '"' && break; printf '.'; sleep 1; done
  printf '\n'
  local leader; leader="$(q v1/status/leader | tr -d '"')"
  case "$leader" in
    172.*|10.*|192.168.*) ok "leader = $leader (local docker - guard ok)" ;;
    *) teardown; die "leader '$leader' is not a local docker address - refusing to continue" ;;
  esac
  printf '    waiting for client node'
  for _ in $(seq 1 40); do
    [ "$(q v1/nodes | jq -r '[.[]|select(.Status=="ready")]|length')" = "1" ] && break
    printf '.'; sleep 1
  done
  printf '\n'
  q ui/ | grep -qi '<html' || die "this binary does not serve /ui (built without the ui tag?)"

  step "2. Seed $COUNT running service jobs"
  seed_jobs
  printf '    waiting for all to run'
  for _ in $(seq 1 60); do
    [ "$(q 'v1/jobs?namespace=*' | jq '[.[]|select(.Status=="running")]|length')" = "$COUNT" ] && break
    printf '.'; sleep 1
  done
  printf '\n'
  ok "running: $(q 'v1/jobs?namespace=*' | jq '[.[]|select(.Status=="running")]|length')/$COUNT"

  step "3. Drive $ADDR/ui/jobs in headless Chrome ($ROUNDS round(s) of paging + filter)"
  local res
  res="$(NODE_PATH="$DEPS/node_modules" node "$HERE/ui-toast-check.js" "$ADDR" "$CHROME" "$ROUNDS")" \
    || { teardown; die "browser check failed"; }

  step "4. Result"
  local nt nund nerr
  nt="$(jq '.toasts|length' <<<"$res")"
  nund="$(jq '[.toasts[]|select(test("status undefined"))]|length' <<<"$res")"
  nerr="$(jq '.errors|length' <<<"$res")"
  info "toasts shown: $nt   logged fetch errors: $nerr"
  jq -r '.toasts|unique[]' <<<"$res" | sed 's/^/        toast: /'
  jq -r '.errors|group_by(.label+.name+.message)[]|"\(length)x \(.[0].label): \(.[0].name): \(.[0].message)"' \
    <<<"$res" | sed 's/^/        /'
  echo
  if [ "$nund" -gt 0 ]; then
    printf '    \033[1;31mBUG PRESENT\033[0m: superseded queries raised the "status undefined" toast\n'
    RESULT=BUG
  elif [ "$nt" -gt 0 ]; then
    warn "INCONCLUSIVE: toasts shown, but none were the 'status undefined' kind (see above)"
    RESULT=INCONCLUSIVE
  else
    printf '    \033[1;32mFIXED\033[0m: paging and filtering aborted queries without any error toast\n'
    RESULT=FIXED
  fi
}

# ---------------------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  bold; echo "Building both binaries with the UI embedded"; bold
  build_ui base "$BASE_REF" "$OUT/nomad-ui-base"
  build_ui fix  "$FIX_REF"  "$OUT/nomad-ui-fix"
fi

run_one "base ($BASE_REF, expect BUG)" "$OUT/nomad-ui-base"; R_BASE="$RESULT"
teardown
run_one "fix ($FIX_REF, expect FIXED)" "$OUT/nomad-ui-fix";  R_FIX="$RESULT"

bold
echo "base: $R_BASE   fix: $R_FIX"
bold
if [ "$KEEP" = "1" ]; then
  info "leaving the fix cluster up (--keep): $ADDR/ui/jobs"
  info "tear down later with:  $DC down -v   (from $HERE)"
else
  teardown
  rm -f "$HERE/nomad-bin"
fi
[ "$R_BASE" = "BUG" ] && [ "$R_FIX" = "FIXED" ]
