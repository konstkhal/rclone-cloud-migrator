#!/usr/bin/env bats
#
# Pins the TAR-CHUNK resume contract specified in docs/tar-chunk-resume.md.
#
# The defect these tests exist for: PACKER_NEXT_CHUNK_IDX carries both the
# destination tar NAME index and the count of batches of the current frozen
# manifest already completed. The two diverge whenever a manifest is frozen
# while a naming offset is already in force, and a position-based skip by the
# name index then jumps batches that were never archived. Against
# docu_trans_process this silently left 86,975 files behind and still exited 0.

load helpers/load

SRC="gdrive:Staging/cryo_chamber/docu"
DST="gdrive:Staging/cryo_chamber/docu_chunks"

setup() {
    migrator_load
    BUF="$TEST_TMP/buffer"
    mkdir -p "$BUF"
    TASK_KEY_FILE_BASE=""
}

teardown() {
    migrator_teardown
}

# Packer::init resolves the state paths; call it, then derive the base-offset
# companion path the same way the spec pins it.
init_task() {
    Packer::init "$SRC" "$BUF" "$1" "${2:-yes}" "$DST"
    BASE_FILE="$SCRIPT_DIR/state/.manifest_base__$(Core::task_key "$SRC" "$DST").state"
}

seed_chunks() {
    local n="$1" i
    PACKER_CHUNKS=()
    for ((i = 1; i <= n; i++)); do PACKER_CHUNKS+=("batch$i"); done
}

# --- naming offset reconciliation -----------------------------------------

@test "init reconciles the naming offset from parts already on the destination" {
    FAKE_RCLONE_LSF_OUT="$TEST_TMP/dest.txt"
    export FAKE_RCLONE_LSF_OUT
    migrator_seed_dest_parts "$FAKE_RCLONE_LSF_OUT" "docu" 34

    init_task 1

    [ "$PACKER_NEXT_CHUNK_IDX" -eq 34 ]
}

# --- the regression this suite exists for ---------------------------------

@test "resume skips only the batches THIS manifest completed, not the name index" {
    # The exact 2026-09-12 sequence, scaled down: a manifest frozen while a
    # naming offset of 34 was in force, two batches completed, index persisted
    # as 36. The true remaining work is 50 of 52 batches.
    init_task 1
    printf '36\n' > "$PACKER_STATE_FILE"
    PACKER_NEXT_CHUNK_IDX=36
    printf '34\n' > "$BASE_FILE"
    PACKER_MANIFEST_REUSED="yes"
    seed_chunks 52

    run Packer::resume_skip_count
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

@test "the raw name-index slice is gone from run_tar_chunk_pipeline" {
    # Structural guard: the defect was one expression. If it reappears, the
    # behavioural test above can still pass while the pipeline ignores it.
    run grep -nE 'PACKER_CHUNKS\[@\]:.*PACKER_NEXT_CHUNK_IDX' "$MIGRATOR_ROOT/smart_migrator.sh"
    [ "$status" -ne 0 ]
}

@test "a manifest frozen this run is never skipped, whatever the name index" {
    init_task 1
    PACKER_NEXT_CHUNK_IDX=34
    PACKER_MANIFEST_REUSED="no"
    seed_chunks 52

    run Packer::resume_skip_count
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

# --- guards: every one halts, none silently continues ---------------------

@test "a reused manifest with no recorded base halts instead of assuming zero" {
    # Assuming 0 here is precisely what produced the incident.
    init_task 1
    PACKER_NEXT_CHUNK_IDX=36
    PACKER_MANIFEST_REUSED="yes"
    rm -f "$BASE_FILE"
    seed_chunks 52

    run Packer::resume_skip_count
    [ "$status" -eq 1 ]
    capture_has "HALT RESUME_BASE_MISSING"
}

@test "a negative skip halts" {
    init_task 1
    PACKER_NEXT_CHUNK_IDX=30
    printf '34\n' > "$BASE_FILE"
    PACKER_MANIFEST_REUSED="yes"
    seed_chunks 52

    run Packer::resume_skip_count
    [ "$status" -eq 1 ]
    capture_has "HALT RESUME_INCONSISTENT"
}

@test "a skip past the end of the plan halts" {
    init_task 1
    PACKER_NEXT_CHUNK_IDX=99
    printf '34\n' > "$BASE_FILE"
    PACKER_MANIFEST_REUSED="yes"
    seed_chunks 52

    run Packer::resume_skip_count
    [ "$status" -eq 1 ]
    capture_has "HALT RESUME_INCONSISTENT"
}

@test "a skip equal to the plan length is normal completion, not a halt" {
    init_task 1
    PACKER_NEXT_CHUNK_IDX=86
    printf '34\n' > "$BASE_FILE"
    PACKER_MANIFEST_REUSED="yes"
    seed_chunks 52

    run Packer::resume_skip_count
    [ "$status" -eq 0 ]
    [ "$output" -eq 52 ]
}

# --- base offset persistence ----------------------------------------------

@test "the base offset is written on freeze and read back on resume" {
    init_task 1
    Packer::persist_manifest_base 52
    [ -f "$BASE_FILE" ]
    [ "$(cat "$BASE_FILE")" = "52" ]

    # Overwritten unconditionally: a manifest deleted by hand and rescanned
    # must never be read against a base left by an earlier freeze.
    Packer::persist_manifest_base 7
    [ "$(cat "$BASE_FILE")" = "7" ]
}

@test "freezing a manifest records the offset in force at that moment" {
    FAKE_RCLONE_LSF_OUT="$TEST_TMP/dest.txt"
    FAKE_RCLONE_RECURSIVE_OUT="$TEST_TMP/scan.txt"
    export FAKE_RCLONE_LSF_OUT FAKE_RCLONE_RECURSIVE_OUT
    migrator_seed_dest_parts "$FAKE_RCLONE_LSF_OUT" "docu" 34
    migrator_seed_manifest "$FAKE_RCLONE_RECURSIVE_OUT" 52 1

    init_task 1
    Packer::scan_payload

    [ "$PACKER_MANIFEST_REUSED" = "no" ]
    [ -f "$BASE_FILE" ]
    [ "$(cat "$BASE_FILE")" = "34" ]
}

# --- completion contract (spec 3.4) ---------------------------------------

@test "purge=yes with a drained source completes" {
    FAKE_RCLONE_RECURSIVE_OUT="$TEST_TMP/empty.txt"
    export FAKE_RCLONE_RECURSIVE_OUT
    : > "$FAKE_RCLONE_RECURSIVE_OUT"

    init_task 1 yes
    run Packer::assert_complete "$SRC" "yes" 52 52
    [ "$status" -eq 0 ]
}

@test "purge=yes with files still in the source fails loudly" {
    # The incident's signature: the pipeline returned 0 with 86,975 files left.
    FAKE_RCLONE_RECURSIVE_OUT="$TEST_TMP/left.txt"
    export FAKE_RCLONE_RECURSIVE_OUT
    printf 'a.mp4\nb.mp4\nc.mp4\n' > "$FAKE_RCLONE_RECURSIVE_OUT"

    init_task 1 yes
    run Packer::assert_complete "$SRC" "yes" 52 52
    [ "$status" -eq 1 ]
    capture_has "3"
}

@test "purge=no asserts the plan was consumed and never lists the source" {
    init_task 1 no
    # Packer::init itself lists the destination to reconcile the naming offset;
    # reset the recorder so this asserts only what assert_complete did.
    : > "$FAKE_RCLONE_CALLS"
    run Packer::assert_complete "$SRC" "no" 52 52
    [ "$status" -eq 0 ]
    run rclone_called
    [ "$status" -ne 0 ]
}

@test "purge=no with batches left unprocessed fails" {
    init_task 1 no
    run Packer::assert_complete "$SRC" "no" 18 52
    [ "$status" -eq 1 ]
}

@test "a dry run asserts nothing and lists nothing" {
    init_task 1 yes
    DRY_RUN_FLAG="--dry-run"
    : > "$FAKE_RCLONE_CALLS"
    run Packer::assert_complete "$SRC" "yes" 0 52
    [ "$status" -eq 0 ]
    run rclone_called
    [ "$status" -ne 0 ]
}
