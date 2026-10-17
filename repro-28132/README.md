# Repro harness for #28132 — jobs missing from `/v1/jobs/statuses`

A self-contained Docker harness that reproduces (and verifies the fix for)
[#28132][issue]: jobs that share a `ModifyIndex` are silently dropped from
`/v1/jobs/statuses` (the endpoint behind the web UI **Jobs** page) while
remaining visible in `/v1/jobs`, the CLI, and the topology page.

It runs against **whatever `nomad` binary you point it at**, so you can A/B an
unpatched build against a patched one and watch the behavior flip.

## TL;DR

```sh
cd repro-28132
./ab.sh                 # builds upstream + fork binaries, runs the harness on each
```

Expected: the upstream binary prints **BUG PRESENT** (jobs missing from
`/v1/jobs/statuses`); the fork binary prints **FIXED** (same collisions, nothing
dropped).

## Root cause (one line)

In `nomad/state/schema.go`, `jobTableSchema()` declares the jobs-table
`modify_index` index `Unique: true`. But `ModifyIndex` is **not** unique across
jobs: when a single Raft transaction writes several jobs at once — e.g. multiple
service jobs whose allocations reach a terminal state in one batched
`UpdateAllocsFromClient`, or a batch of reschedule evals — they all receive the
same `ModifyIndex`. A unique go-memdb index keeps only the last writer per key,
so the rest are dropped from any query that iterates this index. `Job.Statuses`
(backing `/v1/jobs/statuses`) iterates it via `JobsByModifyIndex`; `/v1/jobs`
iterates the unique `id` index and is unaffected.

The fix is to make the index non-unique:

```diff
   "modify_index": {
       Name:         "modify_index",
       AllowMissing: false,
-      Unique:       true,
+      Unique:       false,
       Indexer: &memdb.UintFieldIndex{
           Field: "ModifyIndex",
       },
   },
```

## What the harness does

1. Brings up 1 server + 1 client in Docker (alpine + the bind-mounted binary,
   `raw_exec` driver — no nested Docker, no Consul; the bug is purely in the
   server state store).
2. Submits N `service` jobs (default 20). Each job's single task sleeps until
   **one shared wall-clock epoch**, with `restart`/`reschedule` disabled and
   `update { max_parallel = 0 }` (no deployment, so job status is alloc-driven).
3. At that epoch every task exits at once. The client reports all the
   completions inside a single server-side alloc-update batch window
   (`batchUpdateInterval`, 50ms), so `setJobStatuses` rewrites all those jobs to
   `dead` in **one** Raft transaction → they share a `ModifyIndex`.
4. Compares `/v1/jobs` against `/v1/jobs/statuses` and prints a verdict.

Synchronizing the exits is what makes the otherwise timing-dependent collision
deterministic in a tiny cluster, with no changes to the binary under test.

## Files

| file | purpose |
|---|---|
| `ab.sh` | build both binaries from two git refs and run the harness on each |
| `run.sh` | drive the cluster for **one** binary and print a verdict |
| `compose.yml` | 1 server + 1 client; the binary is bind-mounted from `./nomad-bin` |
| `conf/` | agent configs, the cgroup-v2 entrypoint, and the synchronized-sleep task |

## Usage

### Both at once

```sh
cd repro-28132
./ab.sh                        # default refs: origin/main and fork/main
./ab.sh --count 30 --settle 25 # extra args pass through to run.sh
```

`ab.sh` builds via throwaway `git worktree`s, so your working tree is untouched.
Override the refs/output with env vars:

```sh
HASHICORP_REF=origin/main FORK_REF=fix-jobs-statuses-modifyindex-collision ./ab.sh
OUT=/tmp ./ab.sh
```

### One binary

```sh
CGO_ENABLED=0 go build -o /tmp/nomad .   # build whatever you want to test
cd repro-28132
./run.sh /tmp/nomad
```

Options: `--count N` (jobs, default 20), `--settle S` (seconds to the
synchronized exit, default 30), `--port P` (host API port, default 4646),
`--keep` (leave the cluster up; tear down later with `docker compose down -v`).

`run.sh` self-tears-down at the end, so back-to-back runs need no manual cleanup.
After a cancelled or `--keep` run: `docker compose down -v && rm -rf jobs nomad-bin`.

## Expected output

Unpatched (`Unique: true`):

```
ModifyIndex distribution (from /v1/jobs):
  >> 7 job(s) @ ModifyIndex 75
  >> 8 job(s) @ ModifyIndex 76
  >> 3 job(s) @ ModifyIndex 78
/v1/jobs            = 20
/v1/jobs/statuses   = 5
BUG PRESENT: 15 jobs MISSING from /v1/jobs/statuses
```

Patched (`Unique: false`) — same collisions occur, none are dropped:

```
/v1/jobs            = 20
/v1/jobs/statuses   = 20
FIXED: jobs share a ModifyIndex yet ALL 20 appear in /v1/jobs/statuses
```

## Notes / non-obvious findings

- A reschedule alone does **not** trigger it: a service job stays `running`
  through a reschedule (the replacement alloc is non-terminal), and
  `setJobStatus` only rewrites a job on an actual status change. You need a
  status change for multiple jobs within one batched transaction.
- A running deployment short-circuits job status to `running`, which is why the
  jobs disable deployments — to make status alloc-driven and reach `dead`.
- The harness includes a safety guard: it aborts unless the cluster leader is on
  a private Docker subnet, so it can never act against a real cluster even if
  your shell has `NOMAD_ADDR`/tokens set.

## Requirements

Docker (with `docker compose`), Go (to build the binaries), `jq`, `curl`.

[issue]: https://github.com/hashicorp/nomad/issues/28132

---

# UI: spurious "Error fetching jobs ... status undefined" toast

A second, unrelated jobs page bug, reproduced with the same cluster.

The jobs index aborts its in-flight blocking queries on every page change,
filter change, and live update. When an abort lands after the 200 headers,
during the body read, ember-data JSON-parses the rejected read and the
controller receives a `SyntaxError` instead of an `AbortError`. The old
`e.name !== 'AbortError'` guard misses it, so `notifyFetchError` shows a sticky
"Error fetching jobs: The backend returned an error with status undefined"
toast even though every request returned 200.

The fix checks the request's own `AbortSignal.aborted` instead of the error
name (branch `fix-jobs-index-abort-toast`).

## TL;DR

```sh
cd repro-28132
./ui-toast.sh --port 5646
```

Expected: the base binary prints **BUG PRESENT**, the fix binary prints
**FIXED**, and the script exits 0. The first run builds two UI-embedded
binaries and takes several minutes; `SKIP_BUILD=1` reuses them.

## What it does

1. Builds a nomad binary with the UI embedded for each ref (mirrors
   `make dev-ui`) in throwaway worktrees.
2. Runs each binary in the compose cluster and seeds 30 running service jobs
   (3 pages of 10).
3. Drives `/ui/jobs` in headless Chrome straight against the agent (no ember
   dev proxy): Next, Next, Previous, First, Last, First, then a filter change,
   for 3 rounds.
4. Records every critical toast and every error the controller logs, then
   prints a verdict.

## Usage

```sh
./ui-toast.sh [--count N] [--rounds R] [--port P] [--keep]
BASE_REF=origin/main FIX_REF=fix-jobs-index-abort-toast ./ui-toast.sh
SKIP_BUILD=1 ./ui-toast.sh        # reuse $OUT/nomad-ui-base and $OUT/nomad-ui-fix
```

`CHROME` overrides the browser; `OUT` (default `/tmp`) sets where binaries and
build logs go. `playwright-core` is installed on first run into `.ui-deps/`.

## Expected output

Base:

```
toasts shown: 3   logged fetch errors: 13
    toast: Error fetching jobs The backend returned an error with status undefined while fetching jobs
    13x error fetching job allocs: SyntaxError: Unexpected token 'A', "AbortError"... is not valid JSON
BUG PRESENT: superseded queries raised the "status undefined" toast
```

Fix:

```
toasts shown: 0   logged fetch errors: 0
FIXED: paging and filtering aborted queries without any error toast
```

The toast uses `preventDuplicates`, so one toast per page load can stand for
many errors; each round reloads the page, hence one toast per round.

## Additional requirements

Node, pnpm, Chrome or Chromium, and `go-bindata-assetfs` (installed by
`make bootstrap`).
