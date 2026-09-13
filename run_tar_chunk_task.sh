#!/bin/bash
# Non-interactive entry point into smart_migrator.sh's TAR-CHUNK pipeline for
# one fixed task, meant to be driven by a systemd unit (or any unattended
# launcher) rather than a human at the interactive menu.
#
# smart_migrator.sh has no non-interactive mode of its own - its top-level
# code is a linear sequence of `read` prompts (remote selection, destination
# browsing, queue building) with the TAR-CHUNK functions (Packer::*,
# Transfer::*, Purger::*, Diagnostics::*, run_tar_chunk_pipeline) defined only
# after all of that. Sourcing the file directly would block on the first
# prompt. Rather than add a CLI flag to that interactive flow (a larger,
# riskier change to a script real user sessions still drive by hand), this
# extracts every top-level function definition from smart_migrator.sh via a
# brace-matching pass - insensitive to line-number drift, so it always
# reflects the CURRENT function bodies in that file, never a stale copy -
# and calls run_tar_chunk_pipeline directly with a fixed set of arguments.
#
# The handful of top-level constants those functions close over (retry
# counts, log paths, pacer flags, trap-support globals) are NOT extracted
# the same way - they're interleaved with the interactive-only code, so
# they're reproduced explicitly below. This list was built by grepping
# smart_migrator.sh for every top-level `NAME=` assignment outside a
# function body and manually excluding the ones only the interactive menu
# uses (queue arrays, remote-selection state, pagination). If a future
# smart_migrator.sh change adds a new top-level constant a TAR-CHUNK
# function depends on, it must be added here too - the first version of
# this script missed TAR_BUILD_ATTEMPTS/TAR_BUILD_RETRY_WAIT_SECONDS,
# which silently made Packer::build_local_tar's retry loop run zero
# iterations (empty-string bash arithmetic reads as 0) - caught by testing
# against a disposable folder before this ever ran unattended.
#
# Usage: run_tar_chunk_task.sh <remote-src> <remote-dst> <chunk-bytes> <buffer-dir> <purge:yes|no> [keep-dirs:yes|no]
#   e.g. run_tar_chunk_task.sh gdrive:Staging/cryo_chamber/docu_trans_process \
#          gdrive:Staging/cryo_chamber/docu_trans_process_chunks \
#          5368709120 /home/konstkhal/.smart_migrator_buffer/docu_trans_process yes no
#
# Exits with run_tar_chunk_pipeline's own exit code (0 = this call's chunks
# are all done or nothing was left to do; 1 = halted, resumable, safe to
# rerun - the frozen manifest and persisted chunk index mean a rerun redoes
# at most the one chunk that was in flight, never more).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FILE="${SCRIPT_DIR}/smart_migrator.sh"

SRC_REMOTE="${1:?usage: $0 <remote-src> <remote-dst> <chunk-bytes> <buffer-dir> <purge:yes|no> [keep-dirs:yes|no]}"
DST_REMOTE="${2:?}"
CHUNK_BYTES="${3:?}"
BUFFER_DIR="${4:?}"
PURGE="${5:?}"
KEEP_DIRS="${6:-no}"

# --- constants smart_migrator.sh's TAR-CHUNK functions depend on (see note above) ---
DROPBOX_PACER_FLAGS="--tpslimit 4 --low-level-retries 10"
DROPBOX_PURGE_REMOTES=""
TAR_BUILD_ATTEMPTS=3
TAR_BUILD_RETRY_WAIT_SECONDS=240
PACER_FLAGS="--drive-pacer-burst 1 --drive-pacer-min-sleep 100ms --tpslimit 10 --low-level-retries 15"
TRANSFER_PUSHED_CHUNKS=0
TRANSFER_PUSHED_BYTES=0

LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR" "$BUFFER_DIR"
LOG_FILE="${LOG_DIR}/smart_migrator_$(date '+%Y%m%d_%H%M%S')_$$.log"
RCLONE_LOG_FILE="${LOG_DIR}/smart_migrator_rclone_$(date '+%Y%m%d_%H%M%S')_$$.log"
RCLONE_LOG_FLAGS=(-v --log-file "$RCLONE_LOG_FILE")
RCLONE_OBS_FLAGS=(-v --log-file "$RCLONE_LOG_FILE" --stats 1m --stats-one-line)
DRY_RUN_FLAG=""

_log_persist() { printf '%s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true; }
log_info() { echo -e "[\033[0;32mINFO\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [INFO] $1"; }
log_warn() { echo -e "[\033[0;33mWARN\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [WARN] $1"; }
log_err()  { echo -e "[\033[0;31mERROR\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [ERROR] $1"; }

# Same lock file smart_migrator.sh's own interactive run takes, so this
# script and a manual interactive run can never race on the same state -
# whichever starts first wins, the other exits immediately.
LOCK_FILE="${SCRIPT_DIR}/state/.migrator.lock"
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_err "Another instance (this script or smart_migrator.sh's own interactive run) already holds $LOCK_FILE. Exiting."
    exit 1
fi

CURRENT_MOUNT_DIR=""
CURRENT_STAGE="STARTUP"
CONTROLLED_HALT=0
TRAP_SIGNAL=""

log_info "Extracting TAR-CHUNK functions from $SRC_FILE..."
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
' "$SRC_FILE")"

trap cleanup_on_exit EXIT
trap 'TRAP_SIGNAL=INT;  exit 130' INT
trap 'TRAP_SIGNAL=TERM; exit 143' TERM
trap 'TRAP_SIGNAL=HUP;  exit 129' HUP

log_info "Task: $SRC_REMOTE -> $DST_REMOTE (chunk_bytes=$CHUNK_BYTES purge=$PURGE keep_dirs=$KEEP_DIRS)"
log_info "Script log: $LOG_FILE"
log_info "rclone verbose log: $RCLONE_LOG_FILE"

run_tar_chunk_pipeline "$SRC_REMOTE" "$DST_REMOTE" "$CHUNK_BYTES" "$BUFFER_DIR" "$PURGE" "$KEEP_DIRS"
rc=$?
log_info "run_tar_chunk_pipeline exited $rc"
exit "$rc"
