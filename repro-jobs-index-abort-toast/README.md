# Repro harness: jobs page "Error fetching jobs ... status undefined" toast

The jobs index (`/ui/jobs`) shows a perpetually recurring "Error fetching 
jobs: The backend returned an error with status undefined while fetching 
jobs" toast during normal paging, filtering, and live updates, even though 
every request returns 200.

## Cause

The jobs index aborts its in-flight blocking queries on every page change,
filter change, and live update. When an abort lands after the 200 headers,
during the body read, ember-data JSON-parses the rejected read and the
controller receives a `SyntaxError` instead of an `AbortError`. The old
`e.name !== 'AbortError'` guard misses it, so `notifyFetchError` raises the
toast, and the error has no HTTP status.

The fix (branch `fix-jobs-index-abort-toast`) checks the request's own
`AbortSignal.aborted` instead of the error name.

## Run

```sh
cd repro-jobs-index-abort-toast
./ui-toast.sh --port 5646                # build both binaries, then test each
./ui-toast.sh --port 5646   # reuse $OUT/nomad-ui-base and $OUT/nomad-ui-fix
```
note: use SKIP_BUILD=1 if you are running it an additional time so you don't
have to wait for it to build the binaries again.

Options: `--count N` (jobs, default 30), `--rounds R` (page/filter passes,
default 3), `--port P` (host API/UI port, default 4646), `--keep` (leave the
fix cluster up).

Env: `BASE_REF` (default `origin/main`), `FIX_REF` (default
`fork/fix-jobs-index-abort-toast`), `OUT` (binaries and build logs, default
`/tmp`), `CHROME` (browser binary).

## What it does

- Builds a nomad binary with the UI embedded for each ref (mirrors
  `make dev-ui`) in throwaway worktrees.
- Runs each in a 1-server / 1-client Docker cluster and seeds 30 running
  service jobs (3 pages of 10).
- Drives `/ui/jobs` in headless Chrome straight against the agent: Next, Next,
  Previous, First, Last, First, then a filter change, per round.
- Records every critical toast and every error the controller logs, then
  prints BUG PRESENT or FIXED per binary. Exits 0 when base is BUG and fix is
  FIXED.
- Aborts unless the cluster leader is on a private Docker subnet, and drops
  `NOMAD_*` env vars, so it never touches a real cluster.

## Expected output

```
base (origin/main, expect BUG)
    toasts shown: 3   logged fetch errors: 13
        toast: Error fetching jobs The backend returned an error with status undefined while fetching jobs
        13x error fetching job allocs: SyntaxError: Unexpected token 'A', "AbortError"... is not valid JSON
    BUG PRESENT: superseded queries raised the "status undefined" toast

fix (fork/fix-jobs-index-abort-toast, expect FIXED)
    toasts shown: 0   logged fetch errors: 0
    FIXED: paging and filtering aborted queries without any error toast

base: BUG   fix: FIXED
```

The toast uses `preventDuplicates`, so one toast per page load can stand for
many errors.

## Files

| file | purpose |
|---|---|
| `ui-toast.sh` | build both binaries, run the cluster and browser check for each, print verdicts |
| `ui-toast-check.js` | headless Chrome driver; prints toasts and logged errors as JSON |
| `compose.yml` | 1 server + 1 client; the binary is bind-mounted from `./nomad-bin` |
| `conf/` | agent configs and the cgroup-v2 client entrypoint |

## Requirements

Docker with `docker compose`, Go, Node, pnpm, Chrome or Chromium, `jq`,
`curl`, and `go-bindata-assetfs` (installed by `make bootstrap`).
`playwright-core` is installed on first run into `.ui-deps/`.
