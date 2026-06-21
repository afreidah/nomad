#!/bin/sh
# Sleep until an absolute wall-clock epoch ($1), then exit. Every alloc is given
# the SAME target epoch, so they all exit at the same instant regardless of when
# each one started. That makes the client report all their completions inside a
# single server-side alloc-update batch window (default 50ms), which coalesces
# the resulting job-status writes into one Raft transaction — the exact
# condition that gives the colliding jobs a shared ModifyIndex.
target="$1"
now="$(date +%s)"
s=$(( target - now ))
[ "$s" -lt 1 ] && s=1
exec sleep "$s"
