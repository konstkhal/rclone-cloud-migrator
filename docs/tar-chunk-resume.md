# TAR-CHUNK Resume Contract (v5.8.0)

Specification for the resume, naming, and completion semantics of the TAR-CHUNK
pipeline in `smart_migrator.sh`. Written in response to a silent partial
migration of `gdrive:Staging/cryo_chamber/docu_trans_process` (2026-09-12 to
2026-09-18).

## 1. Observed failure

The pipeline exited 0 and logged `All 10 chunk(s) ... processed successfully`
while 86,975 files (169.96 GiB) of the frozen manifest had never been archived.

| Quantity | Value |
|---|---|
| Frozen manifest (2026-09-12 13:51) | 136,031 files, 52 batches at 5 GB |
| Items actually archived and purged | 49,058 |
| Left in source, reported as complete | 86,975 (169.96 GiB) |

Mapping every surviving source file back to its manifest line yields exactly
three runs, which rules out scattered per-file misses:

```
gone     lines      1 ..   3253    archived as part035-036
PRESENT  lines   3254 ..  90228    n=86975, never processed
gone     lines  90229 .. 136031    archived as part037-052
```

No data was lost. The gap is unarchived, not deleted.

## 2. Root cause

`PACKER_NEXT_CHUNK_IDX` carries two different quantities that are only equal by
accident:

1. the next tar **name** index on the destination (`Packer::init`, reconciled
   from the remote's highest `partNNN.tar` when no state file exists);
2. the count of batches of the **current frozen manifest** already completed,
   which `Packer::run_tar_chunk_pipeline` uses as a positional skip:

```bash
PACKER_CHUNKS=("${PACKER_CHUNKS[@]:$PACKER_NEXT_CHUNK_IDX}")
```

They diverge whenever a manifest is frozen while a naming offset is already in
force. That is exactly what happened:

- **2026-09-12** - manifest frozen this run (`PACKER_MANIFEST_REUSED=no`), so no
  skip was applied and content correctly started at batch 1. The index was 34
  purely as a naming offset, so the tars were named `part035`, `part036`. The
  run was killed by SIGTERM after two batches and persisted `36`.
- **2026-09-13 onward** - manifest reused, so the skip fired: 36 batches
  dropped, when only 2 batches of that manifest had ever run. Batches 3 to 36
  (manifest lines 3254 to 90228) were jumped in a single step and never
  revisited.

The chunk loop itself is correct; it processes every batch it is handed. The
fault is the single slice above.

## 3. Required behaviour

### 3.1 Manifest base offset

A frozen manifest gains a companion state file recording the naming offset in
force at freeze time:

```
state/.manifest_base__<task_key>.state    # single integer, atomic write
```

- Written by `Packer::scan_payload` at the moment the manifest is frozen
  (`PACKER_MANIFEST_REUSED=no`), with the value of `PACKER_NEXT_CHUNK_IDX` at
  that instant. Same write-to-temp-then-mv discipline as
  `Packer::persist_chunk_idx`.
- Written unconditionally on every freeze, overwriting any prior value, so a
  manifest deleted by hand and rescanned can never be read against a base left
  behind by an earlier freeze.
- Read on every run that reuses a manifest.

### 3.2 Resume arithmetic

When `PACKER_MANIFEST_REUSED == yes`:

```
skip = PACKER_NEXT_CHUNK_IDX - PACKER_MANIFEST_BASE_IDX
```

Guards, all fatal via `Diagnostics::halt_chunk_pipeline`, never a silent
continue:

| Condition | Action |
|---|---|
| base state file missing for a reused manifest | HALT. Do not assume 0 - that assumption is what produced this bug. Operator deletes the manifest to force a rescan. |
| `skip < 0` | HALT. State is inconsistent with the manifest. |
| `skip > ${#PACKER_CHUNKS[@]}` | HALT. Index points past the plan. |
| `skip == ${#PACKER_CHUNKS[@]}` | Normal completion, subject to 3.4. |

The existing `pending_purge` resume filter (`Packer::apply_resume_filter`) is
unchanged and still runs first.

### 3.3 Naming invariant

The tar name index is `PACKER_MANIFEST_BASE_IDX + position`, where `position` is
1-based within the current manifest's batch list. Under 3.1 and 3.2 this cannot
collide: the base is reconciled from the destination's highest existing part, so
generated names always start above it.

**Decided: no pre-flight collision check.** It was an addition beyond the scope
agreed in Phase 1, and with 3.1 and 3.2 in place the only residual case it would
catch is a hand-edited `.chunk_idx__` state file; a lost one is already handled
by the reconciliation in `Packer::init`. It does not protect `part001` to
`part034`, because the fixed arithmetic never generates those names.

It follows from 3.2 that the loop's existing naming (`chunk_idx` starting at
`PACKER_NEXT_CHUNK_IDX`, incremented per batch) already satisfies the invariant:
the first processed batch is at position `skip + 1` and is named
`NEXT_CHUNK_IDX + 1`, which is `BASE + position`. No change to the naming code
is required.

### 3.4 Completion contract

Before returning 0, the pipeline must prove the work is actually finished:

- **`purge=yes`** - after the async purge queue drains, re-list the source
  (`rclone lsf -R --files-only`). If any file remains, log an ERROR naming the
  count and total bytes, and exit non-zero. Cost is one recursive listing per
  run: measured at 143 s over the current 86,975-file remainder on 2026-09-18,
  so roughly 4 minutes over a full 136k-file tree.
- **`purge=no`** - the source is intentionally untouched, so assert instead that
  every batch of the plan was processed.
- **`--dry-run`** - assertion skipped.

An exit 0 from the TAR-CHUNK pipeline means the source is drained (or, under
`purge=no`, the plan is fully consumed). It may not mean anything weaker.

Interface, as pinned by the Phase 3 suite:

```
Packer::assert_complete <src> <purge> <processed_count> <planned_count>
```

Reads `DRY_RUN_FLAG` from the global scope, as the rest of the script does.
Returns 0 when the contract holds, 1 when it does not, after logging an ERROR
naming the count of files still present.

## 4. Recovery procedure for docu_trans_process

Runs only after the above ships and passes a dry-run. Preconditions: the
systemd unit `docu-trans-process-migration.service` stays disabled until the
run is launched by hand.

1. Delete `state/.manifest__gdrive_Staging_cryo_chamber_docu_trans_process__*.tsv`
   to force a fresh scan of the drained source (86,975 files remain).
2. The fresh scan sets `PACKER_MANIFEST_BASE_IDX = 52` from the destination's
   highest existing part, and records it per 3.1.
3. Chunks are named `part053` onward into the existing
   `docu_trans_process_chunks` prefix, keeping one unified archive.
4. Interruption is now safe: a SIGTERM at batch k persists `52 + k`, and the
   next run skips `(52 + k) - 52 = k` batches, which is the true count.

## 5. Test suite

`tests/resume_arithmetic.bats`, run with `bats tests/`. The harness
(`tests/helpers/load.bash`) reuses the same brace-matching extraction
`run_tar_chunk_task.sh` performs, so the suite always exercises the current
function bodies in `smart_migrator.sh` rather than a copy that can drift.
`rclone` is replaced by a test double (`tests/helpers/bin/rclone`) that records
every invocation and answers listings from files, so no test can reach a remote.
`Diagnostics::halt_chunk_pipeline` is stubbed, because the real one calls `exit`
and because a stub lets a test assert which guard fired.

The regression pin models the 2026-09-12 sequence directly: a manifest frozen
while a naming offset of 34 was in force, two batches completed, index persisted
as 36, resume expected to skip 2 rather than 36.

At Phase 3 close on 2026-09-18, before any implementation existed, the suite
stood at 14 of 15 failing. The one that passed, destination-offset
reconciliation in `Packer::init`, is existing correct behaviour now pinned
against regression.

Phase 4 closed the same day with 15 of 15 passing. ShellCheck over
`smart_migrator.sh` matches the committed baseline exactly (10x SC2086, 1x
SC2004, both pre-existing and untouched); the two SC2317 findings the change
introduced are suppressed at the line, with the reason recorded there.

## 6. Out of scope

- Reformatting either script with `shfmt`. No `.editorconfig` or flag set is
  committed, so a run would rewrite both files wholesale.
- The sibling defect in `archive_cryo_loose.sh` (Vikunja #86), where a missing
  `src_dir` marks a folder DONE and abandons its remaining chunks. Same class of
  false-success, different code path, tracked separately.
