#!/usr/bin/env bash
#
# Drive the disposable Nomad cluster and demonstrate the /v1/jobs/statuses
# missing-jobs bug (hashicorp/nomad#28132) with WHATEVER nomad binary you point
# it at. Works with a stock release binary (bug present) or a patched build
# (bug gone) — the script just reports what it observes and gives a verdict.
#
# Usage:
#   ./run.sh /path/to/nomad [--count N] [--settle S] [--port P] [--keep]
#
#   /path/to/nomad   nomad binary to test (required). Used as both the agent
#                    binary in the containers AND the CLI to submit jobs.
#   --count N        number of service jobs (default 20)
#   --settle S       seconds until the synchronized task exit (default 30)
#   --port P         host port to publish the server API on (default 4646)
#   --keep           leave the cluster running at the end (default: tear down)
#
# What it does: brings up 1 server + 1 client, submits N tiny `service` jobs
# whose single task exits at the SAME wall-clock instant (restart/reschedule
# off, so they settle to `dead`). Those simultaneous completions are written to
# Raft in one batched transaction, giving the jobs a shared ModifyIndex. It then
# compares /v1/jobs (authoritative, the CLI/topology list) against
# /v1/jobs/statuses (what the web UI jobs page uses).
#
set -u

# ---------------------------------------------------------------------------
# Hard isolation from any real cluster. This shell may inherit NOMAD_* vars
# from your profile (NOMAD_ADDR/TOKEN/CACERT/...). Drop them all and pin every
# call to the local container. A guard below aborts if the leader we reach is
# NOT on a private docker subnet, so we can never act on a remote cluster.
# ---------------------------------------------------------------------------
unset NOMAD_ADDR NOMAD_TOKEN NOMAD_CLIENT_CERT NOMAD_CLIENT_KEY NOMAD_CACERT \
      NOMAD_NAMESPACE NOMAD_REGION NOMAD_TLS_SERVER_NAME 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

BIN=""
COUNT=20
SETTLE=30
PORT=4646
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --count)  COUNT="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) [ -z "$BIN" ] && { BIN="$1"; shift; } || { echo "unexpected arg: $1"; exit 2; } ;;
  esac
done

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "ERROR: pass an executable nomad binary, e.g. ./run.sh /usr/local/bin/nomad" >&2
  exit 2
fi

ADDR="http://127.0.0.1:${PORT}"
DC="docker compose"
NS="namespace=*"

step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    \033[32m%s\033[0m\n' "$*"; }
warn()  { printf '    \033[33m%s\033[0m\n' "$*"; }
die()   { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

q() { curl -s -m 5 "$ADDR/$1"; }   # query helper, always local

jobs_total()    { q "v1/jobs?$NS" | jq 'length'; }
statuses_total(){ q "v1/jobs/statuses?$NS&per_page=1000" | jq 'length'; }
status_counts() { q "v1/jobs?$NS" | jq -r 'group_by(.Status)[]|"\(.[0].Status)=\(length)"' | tr '\n' ' '; }
mi_hist()       { q "v1/jobs?$NS" | jq -r '.[].ModifyIndex' | sort -n | uniq -c \
                    | awk '{print ($1>1?"      >> ":"         ")$1" job(s) @ ModifyIndex "$2}'; }
shared_mi()     { q "v1/jobs?$NS" | jq -r '.[].ModifyIndex' | sort -n | uniq -d | tr '\n' ' '; }
dropped()       { comm -23 \
                    <(q "v1/jobs?$NS"                       | jq -r '.[].ID' | sort) \
                    <(q "v1/jobs/statuses?$NS&per_page=1000" | jq -r '.[].ID' | sort); }

cleanup_jobs_dir() { rm -rf "$HERE/jobs"; }
teardown() { $DC down -v >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
step "0. Binary under test"
cp "$BIN" "$HERE/nomad-bin" || die "could not copy $BIN -> ./nomad-bin"
chmod +x "$HERE/nomad-bin"
VER="$("$HERE/nomad-bin" version | head -1)"
info "source : $BIN"
info "version: $VER"
info "jobs=$COUNT  settle=${SETTLE}s  api=$ADDR  keep=$KEEP"

# ---------------------------------------------------------------------------
step "1. Bring up cluster (1 server + 1 client)"
teardown
HOST_PORT="$PORT" $DC up -d >/dev/null 2>&1 || die "docker compose up failed"
printf '    waiting for leader'
for _ in $(seq 1 40); do q v1/status/leader | grep -q '"' && break; printf '.'; sleep 1; done
printf '\n'
LEADER="$(q v1/status/leader | tr -d '"')"
[ -n "$LEADER" ] || die "no leader (is docker running? is port $PORT free?)"
# SAFETY GUARD: the leader must be on a private docker subnet, never a real host.
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
[ "$(q v1/nodes | jq -r '[.[]|select(.Status=="ready")]|length')" = "1" ] \
  || die "client node never became ready"
ok "node ready: $(q v1/nodes | jq -r '.[0].Name')"

# ---------------------------------------------------------------------------
step "2. Generate $COUNT service jobs with a synchronized exit"
TARGET=$(( $(date +%s) + SETTLE ))
cleanup_jobs_dir; mkdir -p "$HERE/jobs"
W=${#COUNT}
for i in $(seq 1 "$COUNT"); do
  id="j$(printf "%0${W}d" "$i")"
  cat > "$HERE/jobs/$id.nomad.hcl" <<EOF
job "$id" {
  datacenters = ["dc1"]
  type        = "service"

  # no deployment, so the job's status is driven purely by its allocations
  update {
    max_parallel = 0
  }

  group "g" {
    count = 1

    # task exit -> no restart, no reschedule -> the job settles to "dead"
    restart {
      attempts = 0
      mode     = "fail"
    }
    reschedule {
      attempts  = 0
      unlimited = false
    }

    task "t" {
      driver = "raw_exec"
      config {
        command = "/synced-sleep.sh"
        args    = ["$TARGET"]            # every alloc exits at this same epoch
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }
  }
}
EOF
done
info "all $COUNT tasks will exit together at epoch $TARGET ($(date -d "@$TARGET" '+%H:%M:%S'))"

# ---------------------------------------------------------------------------
step "3. Submit jobs"
n=0
for f in "$HERE"/jobs/*.nomad.hcl; do
  "$HERE/nomad-bin" job run -address="$ADDR" -detach "$f" >/dev/null 2>&1 && n=$((n+1))
done
info "submitted $n/$COUNT"
if [ "$n" -eq 0 ]; then
  warn "submit failed for every job — showing the error from one submit:"
  "$HERE/nomad-bin" job run -address="$ADDR" -detach "$HERE"/jobs/*.nomad.hcl 2>&1 \
    | sed -n '1,8p' | sed 's/^/        /'
  teardown; die "no jobs were submitted (see error above)"
fi
printf '    waiting for all to run'
for _ in $(seq 1 30); do
  [ "$(q "v1/jobs?$NS" | jq '[.[]|select(.Status=="running")]|length')" = "$COUNT" ] && break
  printf '.'; sleep 1
done
printf '\n'
ok "status: $(status_counts)"

# ---------------------------------------------------------------------------
step "4. Baseline while running (each job has its own ModifyIndex)"
info "/v1/jobs            = $(jobs_total)"
info "/v1/jobs/statuses   = $(statuses_total)"
s="$(shared_mi)"
[ -z "$s" ] && ok "no shared ModifyIndexes yet, statuses == jobs (bug dormant)" \
            || warn "already-shared ModifyIndexes: $s"

# ---------------------------------------------------------------------------
step "5. Trigger: wait for the synchronized exit (all jobs -> dead at once)"
printf '    waiting for tasks to exit and settle'
for _ in $(seq 1 $(( SETTLE + 40 )) ); do
  d="$(q "v1/jobs?$NS" | jq '[.[]|select(.Status=="dead")]|length')"
  [ "$d" = "$COUNT" ] && break
  printf '.'; sleep 1
done
printf '\n'
ok "status: $(status_counts)"

# ---------------------------------------------------------------------------
step "6. Result"
JT="$(jobs_total)"; ST="$(statuses_total)"; SH="$(shared_mi)"
echo
info "ModifyIndex distribution (from /v1/jobs):"
mi_hist
echo
info "/v1/jobs            = $JT   (authoritative: CLI, topology, scheduler)"
info "/v1/jobs/statuses   = $ST   (what the web UI jobs page renders)"
echo
DROP="$(dropped)"
NDROP="$( [ -n "$DROP" ] && printf '%s\n' "$DROP" | wc -l | tr -d ' ' || echo 0 )"

if [ -z "$SH" ]; then
  warn "INCONCLUSIVE: no two jobs shared a ModifyIndex this run (their exits did"
  warn "not land in one batch window). Re-run, or raise --count / lower --settle."
elif [ "$ST" -lt "$JT" ]; then
  printf '    \033[1;31mBUG PRESENT\033[0m: %s job(s) share a ModifyIndex and %s are MISSING from\n' \
    "$(printf '%s\n' "$SH" | wc -w | tr -d ' ')" "$NDROP"
  printf '    \033[1;31m\033[0m/v1/jobs/statuses while present in /v1/jobs:\n'
  printf '%s\n' "$DROP" | sed 's/^/        dropped: /'
  printf '    \033[1;31m=> this binary has the unique-index bug (UI would hide these jobs)\033[0m\n'
else
  printf '    \033[1;32mFIXED\033[0m: jobs share a ModifyIndex (%s) yet ALL %s appear in\n' "$SH" "$JT"
  printf '    \033[1;32m\033[0m/v1/jobs/statuses — nothing dropped. The non-unique index retains them.\n'
fi

# ---------------------------------------------------------------------------
step "7. Cleanup"
if [ "$KEEP" = "1" ]; then
  info "leaving cluster up (--keep). API: $ADDR"
  info "tear down later with:  $DC down -v   (from $HERE)"
else
  teardown
  cleanup_jobs_dir
  ok "cluster torn down"
fi
