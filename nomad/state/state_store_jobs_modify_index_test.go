// Copyright IBM Corp. 2015, 2026
// SPDX-License-Identifier: BUSL-1.1

package state

import (
	"fmt"
	"testing"

	"github.com/hashicorp/go-memdb"
	"github.com/hashicorp/nomad/ci"
	"github.com/hashicorp/nomad/nomad/mock"
	"github.com/hashicorp/nomad/nomad/structs"
	"github.com/shoenig/test/must"
)

// TestStateStore_JobsByModifyIndex_SharedModifyIndex is a regression test for
// jobs sharing a ModifyIndex being dropped from JobsByModifyIndex, which backs
// the Job.Statuses RPC and the UI jobs page.
//
// Several jobs can share a ModifyIndex when a single Raft transaction writes
// them together (for example, rescheduling allocations after a node goes down).
// The jobs-table "modify_index" index must therefore be non-unique; if it is
// marked Unique, colliding jobs collapse into a single index entry and the rest
// silently disappear from any query that iterates this index, while remaining
// visible via the unique "id" index (used by /v1/jobs and the CLI).
func TestStateStore_JobsByModifyIndex_SharedModifyIndex(t *testing.T) {
	ci.Parallel(t)

	for _, n := range []int{2, 3, 7} {
		t.Run(fmt.Sprintf("cluster_of_%d", n), func(t *testing.T) {
			state := testStateStore(t)

			// n jobs written at the same index => identical ModifyIndex.
			const sharedIndex = 1000
			want := make([]string, 0, n+2)
			for i := range n {
				job := mock.Job()
				job.ID = fmt.Sprintf("shared-%d", i)
				want = append(want, job.ID)
				must.NoError(t, state.UpsertJob(structs.MsgTypeTestSetup, sharedIndex, nil, job))
			}
			// a couple of control jobs with their own unique indexes.
			for i, idx := range []uint64{1001, 1002} {
				job := mock.Job()
				job.ID = fmt.Sprintf("unique-%d", i)
				want = append(want, job.ID)
				must.NoError(t, state.UpsertJob(structs.MsgTypeTestSetup, idx, nil, job))
			}

			ws := memdb.NewWatchSet()
			iter, err := state.JobsByModifyIndex(ws, SortDefault)
			must.NoError(t, err)

			got := make([]string, 0, len(want))
			for raw := iter.Next(); raw != nil; raw = iter.Next() {
				got = append(got, raw.(*structs.Job).ID)
			}

			// every job must be returned; none dropped due to a shared index.
			must.SliceContainsAll(t, want, got,
				must.Sprintf("JobsByModifyIndex dropped jobs sharing a ModifyIndex: want %v, got %v", want, got))
			must.Len(t, len(want), got,
				must.Sprintf("expected %d jobs, got %d: %v", len(want), len(got), got))
		})
	}
}
