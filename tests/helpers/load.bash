# Loads smart_migrator.sh's top-level functions into the test shell using the
# same brace-matching extraction run_tar_chunk_task.sh uses, so the suite always
# exercises the CURRENT function bodies rather than a copy that can drift.
#
# smart_migrator.sh cannot be sourced directly: its top level is a linear
# sequence of interactive `read` prompts, and the TAR-CHUNK functions are
# defined only after them.

# shellcheck disable=SC2034,SC2329
# Every assignment and override below is consumed by function bodies that are
# eval'd into this shell at runtime from smart_migrator.sh, so static analysis
# cannot see the use. Suppressed here rather than per line; nothing else in this
# file is exempt.

MIGRATOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

migrator_load() {
    TEST_TMP="$(mktemp -d)"

    # SCRIPT_DIR is what the Packer/Purger functions resolve state/ and
    # pending_purge/ against; pointing it at a temp dir keeps every test's
    # state disposable and the repo's real state/ untouched.
    SCRIPT_DIR="$TEST_TMP"
    mkdir -p "$SCRIPT_DIR/state" "$SCRIPT_DIR/logs"

    TEST_LOG_CAPTURE="$TEST_TMP/captured.log"
    : > "$TEST_LOG_CAPTURE"
    FAKE_RCLONE_CALLS="$TEST_TMP/rclone_calls.txt"
    : > "$FAKE_RCLONE_CALLS"
    export FAKE_RCLONE_CALLS

    PATH="$MIGRATOR_ROOT/tests/helpers/bin:$PATH"

    # The top-level constants the TAR-CHUNK functions close over. Same list as
    # run_tar_chunk_task.sh: they are interleaved with interactive-only code in
    # smart_migrator.sh and so are not picked up by the function extraction.
    LOG_FILE="$TEST_TMP/logs/test.log"
    RCLONE_LOG_FILE="$TEST_TMP/logs/rclone.log"
    RCLONE_LOG_FLAGS=()
    RCLONE_OBS_FLAGS=()
    DROPBOX_PACER_FLAGS=""
    DROPBOX_PURGE_REMOTES=""
    PACER_FLAGS=""
    TAR_BUILD_ATTEMPTS=3
    TAR_BUILD_RETRY_WAIT_SECONDS=1
    TRANSFER_PUSHED_CHUNKS=0
    TRANSFER_PUSHED_BYTES=0
    DRY_RUN_FLAG=""
    CURRENT_MOUNT_DIR=""
    CURRENT_STAGE="TEST"
    CONTROLLED_HALT=0
    TRAP_SIGNAL=""

    eval "$(awk '
    /^[A-Za-z_][A-Za-z0-9_:.]*\(\)[[:space:]]*\{[[:space:]]*$/ {
        depth=0
        print
        depth++
        while (depth > 0) {
            if ((getline line) <= 0) break
            print line
            n=gsub(/\{/,"{",line); depth+=n
            n=gsub(/\}/,"}",line); depth-=n
        }
        print ""
        next
    }
    ' "$MIGRATOR_ROOT/smart_migrator.sh")"

    # Overrides, defined after the eval so they win. Logging goes to a capture
    # file instead of the terminal; the halt is stubbed because the real one
    # calls exit and would take the whole test process with it, and because a
    # stub lets a test assert WHICH guard fired.
    _log_persist() { :; }
    log_info() { printf 'INFO %s\n' "$1" >> "$TEST_LOG_CAPTURE"; }
    log_warn() { printf 'WARN %s\n' "$1" >> "$TEST_LOG_CAPTURE"; }
    log_err()  { printf 'ERROR %s\n' "$1" >> "$TEST_LOG_CAPTURE"; }

    HALT_STAGE=""
    HALT_DETAIL=""
    Diagnostics::halt_chunk_pipeline() {
        HALT_STAGE="$1"
        HALT_DETAIL="$2"
        CONTROLLED_HALT=1
        printf 'HALT %s :: %s\n' "$1" "$2" >> "$TEST_LOG_CAPTURE"
        return 1
    }
}

migrator_teardown() {
    [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}

# Writes a frozen manifest of <count> files, each <size> bytes, in the same
# TSV shape Packer::scan_payload freezes (size<TAB>relpath, LC_ALL=C sorted).
migrator_seed_manifest() {
    local target="$1" count="$2" size="$3" i
    : > "$target"
    for ((i = 1; i <= count; i++)); do
        printf '%s\t%s\n' "$size" "$(printf 'f%04d.bin' "$i")" >> "$target"
    done
}

migrator_seed_dest_parts() {
    local target="$1" folder="$2" count="$3" i
    : > "$target"
    for ((i = 1; i <= count; i++)); do
        printf '%s.part%03d.tar\n' "$folder" "$i" >> "$target"
    done
}

capture_has() { grep -qF "$1" "$TEST_LOG_CAPTURE"; }
rclone_called() { [ -s "$FAKE_RCLONE_CALLS" ]; }
