# Namespace+ID pagination repro (hashicorp/nomad#28211)

A/B harness showing that paging across namespaces such as `team` and `team-a`
stalls on upstream main and works with the fix.

## The bug

`NamespaceIDTokenizer` builds the cursor `"<namespace>.<id>"` and compares it
to `next_token` as one string, so the `.` separator (0x2E) takes part in the
comparison. `-` is 0x2D, so `"team-a.x" < "team.x"`, while the state store
iterates `team` before `team-a`. With a page boundary at that seam, the server
hands back the same `next_token` forever: the `team` objects repeat on every
page and the `team-a` objects are never returned.

The tokenizer is shared by every endpoint that pages on Namespace+ID: jobs,
variables, CSI and host volumes, and service registrations. This harness walks
`/v1/jobs` and `/v1/vars`.

## Run

Requires docker (with compose), go, jq, curl.

```
git fetch origin main
git fetch https://github.com/afreidah/nomad fix-namespace-id-tokenizer-ordering:fix-namespace-id-tokenizer-ordering
FIX_REF=fix-namespace-id-tokenizer-ordering ./ab.sh
```

The script:

- builds `nomad` for `BASE_REF` and `FIX_REF` in throwaway git worktrees
  (working tree untouched; binaries in `./.bin`)
- for each binary, starts a single server in docker (no client needed)
- creates namespaces `team` and `team-a` with 4 jobs and 4 variables each
- pages `/v1/jobs` and `/v1/vars` with `per_page=4`, following
  `X-Nomad-NextToken`
- reports repeated tokens, duplicated objects, and objects never returned
- exits 0 iff base shows the bug and fix does not

Options: `--count N` (objects per namespace, default 4), `--per P` (page size,
default 4), `--port P` (host API port, default 4646), `--keep` (leave the last
server up). Env: `BASE_REF` (default `origin/main`), `FIX_REF` (default
`fork/fix-namespace-id-tokenizer-ordering`), `OUT` (binary dir), `SKIP_BUILD=1`
(reuse binaries from a previous run).

## Expected output

```
==> 3. Page /v1/jobs (per_page=4)
      page  1:  4 item(s)  next_token=team-a.j1
      page  2:  4 item(s)  next_token=team-a.j1
    jobs: page 2 returned the next_token it was given (team-a.j1); repeats forever
    jobs: duplicated: team/j1 team/j2 team/j3 team/j4
    jobs: never returned: team-a/j1 team-a/j2 team-a/j3 team-a/j4
...
base: BUG   fix: FIXED
```

With the fix, page 2 returns the four `team-a` objects and no `next_token`.
