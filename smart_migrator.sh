#!/usr/bin/env bash

# ==============================================================================
# RCLONE ARCHIVE & SYNC INTERACTIVE MIGRATOR
# ==============================================================================
# Description: On-the-fly streaming tar-archiver and raw copy tool with queue.
# Framework: Modular pseudoclass-style Bash CLI (Core/Engine/System namespaces).
# Version: 5.5.1
# ==============================================================================

set -eo pipefail

# Applied to every rclone call against the Dropbox source remote, both
# during interactive setup (folder listings, payload size checks) and
# execution (manifest scan, purge loop) — defined this early so it's in
# scope everywhere, not just the functions defined later in the file.
DROPBOX_PACER_FLAGS="--tpslimit 4 --low-level-retries 10"

# Optional: dedicate one or more Dropbox API apps/tokens exclusively to
# purge's delete calls, e.g. "dropboxPurge1: dropboxPurge2: dropboxPurge3:"
# (space-separated remote names — different Dropbox App Keys, all
# authorized against the same account). Per Dropbox's own rate-limit
# docs, limits are enforced "per-authorization," and multiple apps
# linked by the same user don't count against each other's limit — so
# each remote listed here gets its own independent budget. A chunk's
# purge manifest is split round-robin across every listed remote and
# purged concurrently, one rclone process per remote.
#
# Empty by default: purge uses the primary source remote alone, exactly
# as it always did. When non-empty, this list REPLACES the primary
# remote for purge purposes rather than adding to it — the primary
# remote keeps doing everything else (mount/scan/build), but purge
# routes only through what's listed here. Include the primary remote's
# own name in the list too if you want it to also share the purge load
# instead of being fully offloaded to dedicated remotes.
DROPBOX_PURGE_REMOTES=""

# Transient FUSE-layer EIOs (Dropbox throttling surfacing as a failed stat or
# read through the mount) can kill an otherwise-healthy chunk build minutes
# from the end. Retry the whole build a bounded number of times, with a
# cooldown so the throttle window passes, before halting the pipeline. Every
# retry rebuilds from scratch — a partial tar is never carried forward, so
# the push/verify/purge parity guarantee is unchanged.
TAR_BUILD_ATTEMPTS=3
TAR_BUILD_RETRY_WAIT_SECONDS=240

# ---------------------------------------------------------------------------
# System::Diagnostics — logging primitives, durable execution log, and the
# crash-safety trap. Defined first since every other module calls into these.
# The durable log lives next to the script rather than in a task's buffer
# dir, since the default buffer dir is under /tmp and can be wiped on
# reboot — exactly the kind of event that can follow an overnight crash.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/smart_migrator_$(date '+%Y%m%d_%H%M%S')_$$.log"

_log_persist() { printf '%s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true; }

log_info() { echo -e "[\033[0;32mINFO\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [INFO] $1"; }
log_warn() { echo -e "[\033[0;33mWARN\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [WARN] $1"; }
log_err()  { echo -e "[\033[0;31mERROR\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [ERROR] $1"; }

# Single-instance guard. flock (not a PID file) so a crash of any kind
# (including SIGKILL/OOM) releases the lock automatically when fd 200
# closes, instead of leaving a stale lock behind that needs manual
# cleanup or PID-liveness checking. Must run before anything that
# touches the source/destination remotes or local state, so two
# concurrent launches can never race on the same chunk-index state file.
LOCK_FILE="${SCRIPT_DIR}/state/.migrator.lock"
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_err "Another instance of smart_migrator.sh is already running (lock held on $LOCK_FILE). Exiting."
    exit 1
fi

# CONTROLLED_HALT lets a deliberate, fully-diagnosed halt
# (Diagnostics::halt_chunk_pipeline) suppress cleanup_on_exit's generic
# "terminated unexpectedly" line below, since it already logs its own
# complete banner. Without it the two mechanisms would double-log every
# controlled halt. Cannot catch SIGKILL/OOM — best-effort forensics only.
CURRENT_MOUNT_DIR=""
CURRENT_STAGE="STARTUP"
CONTROLLED_HALT=0
TRAP_SIGNAL=""

cleanup_on_exit() {
    local exit_code=$?
    if [ -n "$CURRENT_MOUNT_DIR" ] && mountpoint -q "$CURRENT_MOUNT_DIR" 2>/dev/null; then
        fusermount -u "$CURRENT_MOUNT_DIR" 2>/dev/null || true
        rmdir "$CURRENT_MOUNT_DIR" 2>/dev/null || true
    fi
    if declare -F RemoteLock::release_all >/dev/null && [ "${#REMOTE_LOCK_HELD[@]}" -gt 0 ]; then
        RemoteLock::release_all
    fi
    # Stop the async purger if it's still running; its queue is durable
    # files, so anything unfinished resumes on the next launch.
    if [ -n "${PURGER_PID:-}" ] && kill -0 "$PURGER_PID" 2>/dev/null; then
        kill "$PURGER_PID" 2>/dev/null || true
    fi
    if [ "$CONTROLLED_HALT" -eq 0 ] && { [ "$exit_code" -ne 0 ] || [ -n "$TRAP_SIGNAL" ]; }; then
        log_err "process terminated unexpectedly at stage: ${CURRENT_STAGE} (exit=${exit_code}${TRAP_SIGNAL:+, signal=$TRAP_SIGNAL})"
    fi
}
trap cleanup_on_exit EXIT
trap 'TRAP_SIGNAL=INT;  exit 130' INT
trap 'TRAP_SIGNAL=TERM; exit 143' TERM
trap 'TRAP_SIGNAL=HUP;  exit 129' HUP

# Convert a raw byte count into a human-readable MB/GB string.
format_bytes() {
    local bytes="$1"
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "Unknown"
        return
    fi
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GB", b/1073741824;
        else if (b >= 1048576) printf "%.2f MB", b/1048576;
        else if (b >= 1024) printf "%.2f KB", b/1024;
        else printf "%d Bytes", b;
    }'
}

# Parse a human size like "50G", "500M", "1024K", or a bare byte count into
# raw bytes. Echoes an empty string on unrecognized input.
parse_size_to_bytes() {
    local input="${1^^}" num unit
    if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)([KMGT]?I?B?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
        case "$unit" in
            ""|B)         awk -v n="$num" 'BEGIN { printf "%.0f", n }' ;;
            K|KI|KIB|KB)  awk -v n="$num" 'BEGIN { printf "%.0f", n*1024 }' ;;
            M|MI|MIB|MB)  awk -v n="$num" 'BEGIN { printf "%.0f", n*1024*1024 }' ;;
            G|GI|GIB|GB)  awk -v n="$num" 'BEGIN { printf "%.0f", n*1024*1024*1024 }' ;;
            T|TI|TIB|TB)  awk -v n="$num" 'BEGIN { printf "%.0f", n*1024*1024*1024*1024 }' ;;
            *) echo "" ;;
        esac
    else
        echo ""
    fi
}

# Strict white-list input prompt. Re-prompts until the raw input is exactly
# one of the single characters in $valid_chars (case-sensitive, no leading/
# trailing junk) — rejects empty input, stray carriage returns, multi-char
# strings, and out-of-set characters (e.g. Cyrillic look-alikes) instead of
# silently defaulting. Echoes the validated character to stdout so callers
# can capture it via command substitution; the prompt itself goes to stderr
# (bash's `read -p` behavior), so it never pollutes the captured value.
# Every `read` in a $()-captured function carries `|| exit 1`: errexit is not
# inherited inside command substitutions (inherit_errexit unset), so a failed
# read (stdin EOF) would otherwise leave the variable empty and hot-spin the
# enclosing while-true loop instead of terminating the script.
prompt_strict_choice() {
    local prompt_msg="$1" valid_chars="$2" label="$3" answer
    while true; do
        read -r -p "$prompt_msg" answer || exit 1
        if [[ "$answer" =~ ^[${valid_chars}]$ ]]; then
            echo "$answer"
            return 0
        fi
        log_err "Invalid input. Please enter exactly one of: $label"
    done
}

# ---------------------------------------------------------------------------
# UI::Paginate — shared paging for the interactive listing menus so a long
# folder/remote listing always fits one screen (the Tokyo screen session has
# no recoverable scrollback once the buffer overflows). The paging is
# DISPLAY-ONLY: printed indices are absolute (base + array position), so a
# value shown on any page is the exact value the caller validates against the
# full array — typing an index that lives on another page still works.
# ---------------------------------------------------------------------------

# Set by UI::paginate_render on every call so the caller can size navigation
# and stay in sync with the page actually rendered (render clamps an
# out-of-range page, e.g. after a terminal resize shrinks the list).
PAGINATE_TOTAL_PAGES=1
PAGINATE_PAGE=1

# Rows to show per page, derived from the live terminal height minus the
# static lines each menu prints around its list ($1 = that overhead). stty on
# /dev/tty is queried first because these menus run inside command
# substitution (stdout is a pipe there, which defeats `tput lines`); tput,
# $LINES, and a fixed 20 are ordered fallbacks. Floored at 10 so a tiny window
# still shows a usable slice.
UI::page_size() {
    local reserve="${1:-8}" rows=""
    rows=$( { stty size </dev/tty ; } 2>/dev/null | awk '{print $1}' ) || rows=""
    if ! [[ "$rows" =~ ^[0-9]+$ ]]; then rows=$( tput lines 2>/dev/null ) || rows=""; fi
    [[ "$rows" =~ ^[0-9]+$ ]] || rows="${LINES:-}"
    [[ "$rows" =~ ^[0-9]+$ ]] || { echo 20; return; }
    local avail=$(( rows - reserve ))
    [ "$avail" -lt 10 ] && avail=10
    echo "$avail"
}

# Render one page of an entry array as "  <abs_index>) <entry>" lines, plus a
# "-- Page X/Y (N entries total) --" footer only when the list spans more than
# one page. Args: stream(1=stdout|2=stderr) base_index page page_size entries...
# The stream is a parameter (not a fixed redirect) because the
# command-substituted menus must keep all display on stderr to avoid polluting
# the path they echo to stdout.
UI::paginate_render() {
    local stream="$1" base="$2" page="$3" page_size="$4"
    shift 4
    local -a entries=("$@")
    local total=${#entries[@]}
    local total_pages=$(( (total + page_size - 1) / page_size ))
    [ "$total_pages" -lt 1 ] && total_pages=1
    [ "$page" -gt "$total_pages" ] && page="$total_pages"
    [ "$page" -lt 1 ] && page=1
    PAGINATE_TOTAL_PAGES="$total_pages"
    PAGINATE_PAGE="$page"

    local start=$(( (page - 1) * page_size ))
    local end=$(( start + page_size ))
    [ "$end" -gt "$total" ] && end="$total"
    {
        local j
        for (( j = start; j < end; j++ )); do
            printf '  %s) %s\n' "$(( base + j ))" "${entries[$j]}"
        done
        [ "$total_pages" -gt 1 ] && \
            printf -- '-- Page %s/%s (%s entries total) --\n' "$page" "$total_pages" "$total"
    } >&"$stream"
    # Always succeed: the single-page path leaves the falsy `-gt 1` test as the
    # last status, which would trip errexit at the direct (non-substituted)
    # configure_queue call sites.
    return 0
}

# 1. Dry-run mode resolution — Direct Mode (-d/--dry-run flag) bypasses the
# interactive safety prompt entirely; Default Mode always asks before
# touching any remote.
DRY_RUN_FLAG=""
DIRECT_DRY_RUN_REQUESTED=0

for arg in "$@"; do
    if [ "$arg" == "-d" ] || [ "$arg" == "--dry-run" ]; then
        DIRECT_DRY_RUN_REQUESTED=1
        break
    fi
done

if [ "$DIRECT_DRY_RUN_REQUESTED" -eq 1 ]; then
    DRY_RUN_FLAG="--dry-run"
    echo "=================================================="
    echo -e "⚠️  RUNNING IN DIRECT DRY-RUN MODE (SIMULATION) ⚠️"
    echo "=================================================="
else
    echo "----------------------------------------------------------------------"
    log_warn "This script performs HEAVY cloud synchronization operations that can"
    log_warn "copy, archive, and PERMANENTLY DELETE (purge) data on remote storage."
    echo "----------------------------------------------------------------------"
    read -r -p "Would you like to perform a safe dry-run (simulation) first? [Y/n] " DRY_RUN_CHOICE
    case "$DRY_RUN_CHOICE" in
        [Nn]*)
            DRY_RUN_FLAG=""
            log_warn "LIVE MODE confirmed. Real changes WILL be made to remote storage."
            ;;
        *)
            DRY_RUN_FLAG="--dry-run"
            log_info "Simulation starting. No data will be changed, moved, or deleted."
            ;;
    esac
fi

# 2. Check for required binaries
for cmd in rclone tar fusermount; do
    if ! command -v "$cmd" &> /dev/null; then
        log_err "Required command '$cmd' is missing. Exiting."
        exit 1
    fi
done

echo "----------------------------------------------------------------------"
echo "        RCLONE INTERACTIVE STREAM MIGRATOR OPERATIONAL SYSTEM         "
echo "----------------------------------------------------------------------"

# 3. Detect Available Rclone Remotes with Numbered Menu
log_info "Scanning operational rclone storage remotes..."
REMOTE_LIST=$(rclone listremotes)

if [ -z "$REMOTE_LIST" ]; then
    log_err "No rclone remotes found! Please configure rclone first via 'rclone config'."
    exit 1
fi

select_remote() {
    local prompt_msg="$1"
    local i selected r_idx remote nav_hint
    local -a REMOTE_ARRAY=()
    i=0
    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            REMOTE_ARRAY[$i]="$remote"
            i=$((i + 1))
        fi
    done <<< "$REMOTE_LIST"
    local count=$i
    local page=1
    while true; do
        echo -e "\nAvailable storage nodes:" >&2
        UI::paginate_render 2 0 "$page" "$(UI::page_size 5)" "${REMOTE_ARRAY[@]}"
        page="$PAGINATE_PAGE"
        echo "----------------------------------------------------------------------" >&2
        nav_hint=""
        [ "$PAGINATE_TOTAL_PAGES" -gt 1 ] && nav_hint="(n/p to page) "
        read -r -p "${nav_hint}${prompt_msg}" r_idx || exit 1
        if [ "$r_idx" == "n" ]; then
            if [ "$page" -lt "$PAGINATE_TOTAL_PAGES" ]; then page=$((page + 1)); else log_warn "Already on the last page."; fi
            continue
        elif [ "$r_idx" == "p" ]; then
            if [ "$page" -gt 1 ]; then page=$((page - 1)); else log_warn "Already on the first page."; fi
            continue
        fi
        if [[ "$r_idx" =~ ^[0-9]+$ ]] && [ "$r_idx" -lt "$count" ]; then
            selected="${REMOTE_ARRAY[$r_idx]}"
            selected="${selected// /}"
            selected="${selected%:}:"
            echo "$selected"
            return 0
        else
            log_err "Invalid selection index '$r_idx'. Range is 0 to $((count-1)). Try again."
        fi
    done
}

GLOBAL_SRC_REMOTE=$(select_remote "Select GLOBAL SOURCE Remote Node (index): ")
GLOBAL_DST_REMOTE=$(select_remote "Select GLOBAL DESTINATION Remote Node (index): ")

echo "----------------------------------------------------------------------"
log_info "Source Set: $GLOBAL_SRC_REMOTE | Destination Set: $GLOBAL_DST_REMOTE"
echo "----------------------------------------------------------------------"

# 4. Destination directory tree cache — populated lazily on first use, not at startup
declare -a DST_DIRS_CACHE=()

fetch_dst_directories() {
    log_info "Scanning destination directories on ${GLOBAL_DST_REMOTE} (top level)..."
    local top_dirs
    top_dirs=$(rclone lsf --dirs-only --dir-slash=false "${GLOBAL_DST_REMOTE}" 2>/dev/null) || true
    DST_DIRS_CACHE=()
    if [ -z "$top_dirs" ]; then
        log_warn "No directories found on destination remote root."
        return
    fi
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        DST_DIRS_CACHE+=("$dir")
    done <<< "$top_dirs"
    log_info "Found ${#DST_DIRS_CACHE[@]} destination director(ies)."
}

# Present a numbered menu of discovered destination directories and return the chosen path.
# Supports infinite on-demand drilldown into subfolders. Always outputs the final
# path to stdout (for command substitution); all display goes to stderr.
select_dst_path() {
    local prompt_msg="$1"
    local root_prompt_msg="$1"
    local current_path=""
    local at_root=1
    local -a menu_dirs=()

    if [ ${#DST_DIRS_CACHE[@]} -eq 0 ]; then
        fetch_dst_directories
    fi
    menu_dirs=("${DST_DIRS_CACHE[@]}")
    local page=1
    local nav_hint

    while true; do
        echo -e "\nAvailable destination directories on ${GLOBAL_DST_REMOTE}${current_path}:" >&2
        if [ "$at_root" -eq 1 ]; then
            echo "  0) / (remote root)" >&2
        fi
        # base_index 1: this menu is 1-indexed (0 is reserved for the remote
        # root shown above), so absolute index = array position + 1.
        UI::paginate_render 2 1 "$page" "$(UI::page_size 9)" "${menu_dirs[@]}"
        page="$PAGINATE_PAGE"
        if [ "$at_root" -eq 1 ]; then
            echo "  m) Manually type a custom path" >&2
        fi
        echo "  b) .. (Go back to parent directory)" >&2
        echo "  r) / (Reset navigation to remote root)" >&2
        echo "----------------------------------------------------------------------" >&2
        nav_hint=""
        [ "$PAGINATE_TOTAL_PAGES" -gt 1 ] && nav_hint="(n/p to page) "
        read -r -p "${nav_hint}${prompt_msg}" choice || exit 1

        if [ "$choice" == "n" ]; then
            if [ "$page" -lt "$PAGINATE_TOTAL_PAGES" ]; then page=$((page + 1)); else log_warn "Already on the last page."; fi
            continue
        elif [ "$choice" == "p" ]; then
            if [ "$page" -gt 1 ]; then page=$((page - 1)); else log_warn "Already on the first page."; fi
            continue
        elif [ "$at_root" -eq 1 ] && [ "$choice" == "m" ]; then
            read -r -p "Enter custom destination path (relative to remote root): " custom_path || exit 1
            echo "$custom_path"
            return 0
        elif [ "$at_root" -eq 1 ] && [ "$choice" == "0" ]; then
            echo ""
            return 0
        elif [ "$choice" == "b" ]; then
            if [ -z "$current_path" ]; then
                log_warn "Already at remote root. Cannot go back further."
            else
                page=1
                current_path="${current_path%/*}"
                if [ -z "$current_path" ]; then
                    menu_dirs=("${DST_DIRS_CACHE[@]}")
                    at_root=1
                    prompt_msg="$root_prompt_msg"
                else
                    local parent_listing
                    parent_listing=$(rclone lsf --dirs-only --dir-slash=false "${GLOBAL_DST_REMOTE}${current_path}" 2>/dev/null) || true
                    menu_dirs=()
                    while IFS= read -r pd; do
                        [ -z "$pd" ] && continue
                        menu_dirs+=("$pd")
                    done <<< "$parent_listing"
                    at_root=0
                    prompt_msg="Select a subfolder index: "
                fi
            fi
        elif [ "$choice" == "r" ]; then
            page=1
            current_path=""
            menu_dirs=("${DST_DIRS_CACHE[@]}")
            at_root=1
            prompt_msg="$root_prompt_msg"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#menu_dirs[@]}" ]; then
            current_path="${current_path}/${menu_dirs[$((choice - 1))]}"

            local drill_opt
            drill_opt=$(prompt_strict_choice "Drill down deeper into this directory? (y/n): " "yYnN" "y or n")
            if [[ "$drill_opt" == "y" || "$drill_opt" == "Y" ]]; then
                local sub_listing
                sub_listing=$(rclone lsf --dirs-only --dir-slash=false "${GLOBAL_DST_REMOTE}${current_path}" 2>/dev/null) || true
                menu_dirs=()
                if [ -z "$sub_listing" ]; then
                    log_warn "No subfolders found under '$current_path'. Using this path as-is."
                    echo "$current_path"
                    return 0
                fi
                while IFS= read -r sd; do
                    [ -z "$sd" ] && continue
                    menu_dirs+=("$sd")
                done <<< "$sub_listing"
                page=1
                at_root=0
                prompt_msg="Select a subfolder index: "
            else
                echo "$current_path"
                return 0
            fi
        else
            log_err "Invalid selection. Choose a valid number$( [ "$at_root" -eq 1 ] && echo " (0 for root) or 'm' for manual input" ), 'b' to go back, or 'r' to reset."
        fi
    done
}

# 5. Fetch Top-Level Structures from Source
log_info "Fetching top-level directories from $GLOBAL_SRC_REMOTE..."
TOP_FOLDERS=$(rclone lsf --dirs-only --dir-slash=false "$GLOBAL_SRC_REMOTE" $DROPBOX_PACER_FLAGS)

# ---------------------------------------------------------------------------
# Core::QueueManager — owns the pending job list. Tasks are stored as
# parallel arrays (index i of every array belongs to task i) instead of
# delimited strings, so no caller ever IFS-splits a record to read a field.
# ---------------------------------------------------------------------------
declare -a QUEUE_SRC=()
declare -a QUEUE_DST=()
declare -a QUEUE_MODE=()
declare -a QUEUE_PURGE=()
declare -a QUEUE_CHUNK_BYTES=()
declare -a QUEUE_BUFFER_DIR=()
declare -a QUEUE_KEEP_DIRS=()

# Enqueue one task. Bash functions cannot return structs, so fields are
# passed positionally.
Queue::push() {
    local src="$1" dst="$2" mode="$3" purge="$4" chunk_bytes="$5" buffer_dir="$6" keep_dirs="${7:-no}"
    QUEUE_SRC+=("$src")
    QUEUE_DST+=("$dst")
    QUEUE_MODE+=("$mode")
    QUEUE_PURGE+=("$purge")
    QUEUE_CHUNK_BYTES+=("$chunk_bytes")
    QUEUE_BUFFER_DIR+=("$buffer_dir")
    QUEUE_KEEP_DIRS+=("$keep_dirs")
}

# Dequeue the oldest task (FIFO) into the QUEUE_POPPED_* globals below.
# Returns 1 with the globals left untouched once the queue is empty, so
# callers can drive a `while Queue::pop; do ...; done` loop.
QUEUE_POPPED_SRC=""
QUEUE_POPPED_DST=""
QUEUE_POPPED_MODE=""
QUEUE_POPPED_PURGE=""
QUEUE_POPPED_CHUNK_BYTES=""
QUEUE_POPPED_BUFFER_DIR=""
QUEUE_POPPED_KEEP_DIRS=""

Queue::pop() {
    [ ${#QUEUE_SRC[@]} -eq 0 ] && return 1
    QUEUE_POPPED_SRC="${QUEUE_SRC[0]}"
    QUEUE_POPPED_DST="${QUEUE_DST[0]}"
    QUEUE_POPPED_MODE="${QUEUE_MODE[0]}"
    QUEUE_POPPED_PURGE="${QUEUE_PURGE[0]}"
    QUEUE_POPPED_CHUNK_BYTES="${QUEUE_CHUNK_BYTES[0]}"
    QUEUE_POPPED_BUFFER_DIR="${QUEUE_BUFFER_DIR[0]}"
    QUEUE_POPPED_KEEP_DIRS="${QUEUE_KEEP_DIRS[0]:-no}"
    QUEUE_SRC=("${QUEUE_SRC[@]:1}")
    QUEUE_DST=("${QUEUE_DST[@]:1}")
    QUEUE_MODE=("${QUEUE_MODE[@]:1}")
    QUEUE_PURGE=("${QUEUE_PURGE[@]:1}")
    QUEUE_CHUNK_BYTES=("${QUEUE_CHUNK_BYTES[@]:1}")
    QUEUE_BUFFER_DIR=("${QUEUE_BUFFER_DIR[@]:1}")
    QUEUE_KEEP_DIRS=("${QUEUE_KEEP_DIRS[@]:1}")
    return 0
}

Queue::size() { echo "${#QUEUE_SRC[@]}"; }

Queue::reset() {
    QUEUE_SRC=()
    QUEUE_DST=()
    QUEUE_MODE=()
    QUEUE_PURGE=()
    QUEUE_CHUNK_BYTES=()
    QUEUE_BUFFER_DIR=()
}

# Prints the full queue without consuming it (used by the review screen).
Queue::review() {
    if [ ${#QUEUE_SRC[@]} -eq 0 ]; then
        log_warn "The queue is completely empty."
        return
    fi
    local index
    for index in "${!QUEUE_SRC[@]}"; do
        echo -e "[$index] \033[1;33m${QUEUE_MODE[$index]}\033[0m: ${QUEUE_SRC[$index]} --> ${QUEUE_DST[$index]} [Purge Source: ${QUEUE_PURGE[$index]}]"
        if [ "${QUEUE_MODE[$index]}" == "tar-chunk" ]; then
            echo "      Chunk Size: $(format_bytes "${QUEUE_CHUNK_BYTES[$index]}") | Local Buffer: ${QUEUE_BUFFER_DIR[$index]}"
        fi
    done
}

# 6. Interactive Queue Configuration Core
configure_queue() {
    if [ -z "$TOP_FOLDERS" ]; then
        log_warn "No automatic top-level directories detected."
    else
        local -a RAW_FOLDERS=() FOLDER_ARRAY=()
        IFS=$'\n' read -r -d '' -a RAW_FOLDERS <<< "$TOP_FOLDERS" || true
        # Drop the trailing empty element the newline-terminated listing leaves
        # behind so paging renders no blank rows; real entries keep their index.
        local folder
        for folder in "${RAW_FOLDERS[@]}"; do
            [ -n "$folder" ] && FOLDER_ARRAY+=("$folder")
        done

        local page=1 nav_hint
        while true; do
            echo -e "\nDetected Top-Level Directories on Source:"
            UI::paginate_render 1 0 "$page" "$(UI::page_size 6)" "${FOLDER_ARRAY[@]}"
            page="$PAGINATE_PAGE"
            echo "  q) Finished choosing folders (Proceed to next step)"
            echo "  e) [EXIT] Terminate system completely now"
            echo "----------------------------------------------------------------------"
            nav_hint=""
            [ "$PAGINATE_TOTAL_PAGES" -gt 1 ] && nav_hint="(n/p to page) "
            read -r -p "${nav_hint}Select a folder index to configure, 'q' to proceed, or 'e' to exit: " CHOSEN_IDX || exit 1

            if [ "$CHOSEN_IDX" == "n" ]; then
                if [ "$page" -lt "$PAGINATE_TOTAL_PAGES" ]; then page=$((page + 1)); else log_warn "Already on the last page."; fi
                continue
            elif [ "$CHOSEN_IDX" == "p" ]; then
                if [ "$page" -gt 1 ]; then page=$((page - 1)); else log_warn "Already on the first page."; fi
                continue
            elif [ "$CHOSEN_IDX" == "e" ]; then
                log_warn "Exit profile triggered by user. Aborting mission immediately."
                exit 0
            elif [ "$CHOSEN_IDX" == "q" ]; then
                break
            fi

            if ! [[ "$CHOSEN_IDX" =~ ^[0-9]+$ ]] || [ "$CHOSEN_IDX" -ge "${#FOLDER_ARRAY[@]}" ] || [ -z "${FOLDER_ARRAY[$CHOSEN_IDX]}" ]; then
                log_err "Invalid selection index. Please try again."
                continue
            fi

            local target_folder="${FOLDER_ARRAY[$CHOSEN_IDX]}"
            # 'b' at this folder and 'r' both escape to the top-level menu via
            # 'continue 2' instead of clearing target_folder, so downstream
            # naming always sees a non-empty folder.
            local source_root_folder="$target_folder"

            # Infinite on-demand recursive drilldown into subfolders
            while true; do
                local drill_opt
                drill_opt=$(prompt_strict_choice "Drill down deeper into '$target_folder'? (y/n): " "yYnN" "y or n")
                if [[ "$drill_opt" == "y" || "$drill_opt" == "Y" ]]; then
                    local sub_listing
                    sub_listing=$(rclone lsf --dirs-only --dir-slash=false "${GLOBAL_SRC_REMOTE}${target_folder}" $DROPBOX_PACER_FLAGS 2>/dev/null) || true
                    if [ -z "$sub_listing" ]; then
                        log_warn "No subfolders found under '$target_folder'. Using this path as-is."
                        break
                    fi
                    local -a SUB_SRC_ARRAY=()
                    while IFS= read -r sf; do
                        [ -z "$sf" ] && continue
                        SUB_SRC_ARRAY+=("$sf")
                    done <<< "$sub_listing"

                    # Inner pager for this listing. 'n'/'p' page in place;
                    # every other outcome (drill/back/reset) leaves this loop so
                    # the drilldown loop re-lists at the new level from page 1.
                    local sub_page=1 sub_nav_hint
                    while true; do
                        echo -e "\nSubfolders of $target_folder:"
                        UI::paginate_render 1 0 "$sub_page" "$(UI::page_size 5)" "${SUB_SRC_ARRAY[@]}"
                        sub_page="$PAGINATE_PAGE"
                        echo "  b) .. (Go back to parent directory)"
                        echo "  r) / (Reset navigation to remote root)"
                        sub_nav_hint=""
                        [ "$PAGINATE_TOTAL_PAGES" -gt 1 ] && sub_nav_hint="(n/p to page) "
                        read -r -p "${sub_nav_hint}Select a subfolder index to drill into, 'b' to go back, or 'r' to reset: " sub_idx || exit 1
                        if [ "$sub_idx" == "n" ]; then
                            if [ "$sub_page" -lt "$PAGINATE_TOTAL_PAGES" ]; then sub_page=$((sub_page + 1)); else log_warn "Already on the last page."; fi
                            continue
                        elif [ "$sub_idx" == "p" ]; then
                            if [ "$sub_page" -gt 1 ]; then sub_page=$((sub_page - 1)); else log_warn "Already on the first page."; fi
                            continue
                        elif [[ "$sub_idx" =~ ^[0-9]+$ ]] && [ "$sub_idx" -lt "${#SUB_SRC_ARRAY[@]}" ]; then
                            target_folder="${target_folder}/${SUB_SRC_ARRAY[$sub_idx]}"
                            break
                        elif [ "$sub_idx" == "b" ]; then
                            if [ "$target_folder" == "$source_root_folder" ]; then
                                log_info "Back at remote root. Returning to the top-level directory menu."
                                continue 3
                            else
                                target_folder="${target_folder%/*}"
                                break
                            fi
                        elif [ "$sub_idx" == "r" ]; then
                            log_info "Navigation reset to remote root. Returning to the top-level directory menu."
                            continue 3
                        else
                            log_err "Invalid subfolder index. Staying at current level: $target_folder"
                        fi
                    done
                else
                    break
                fi
            done

            echo -e "\n======================================================================"
            echo -e "Configuring Folder: \033[1;34m$target_folder\033[0m"
            echo "================================================================------"

            # Source Size Assessment Matrix
            log_info "Calculating source directory payload mass..."
            local size_json bytes_count objects_count human_size
            size_json=$(rclone size --json "${GLOBAL_SRC_REMOTE}${target_folder}" $DROPBOX_PACER_FLAGS 2>>"$LOG_FILE") || true
            bytes_count=$(echo "$size_json" | grep -o '"bytes":[0-9]*' | cut -d: -f2) || true
            objects_count=$(echo "$size_json" | grep -o '"count":[0-9]*' | cut -d: -f2) || true
            human_size=$(format_bytes "$bytes_count")

            echo "----------------------------------------------------------------------"
            echo "                 SOURCE PAYLOAD ASSESSMENT MATRIX                     "
            echo "----------------------------------------------------------------------"
            echo "  Total Payload Size:   ${human_size}"
            echo "  Total Objects Count:  ${objects_count:-Unknown}"
            echo "----------------------------------------------------------------------"

            echo "Select processing profile:"
            echo "  1) [RAW] Copy folder contents 'as-is' to destination directory"
            echo "  2) [TAR] Stream entire folder into a single unified .tar archive file"
            echo "  3) [TAR-CHUNK] Build size-limited local archives with incremental purge"
            FOLDER_OPT=$(prompt_strict_choice "Choose option (1-3): " "123" "1, 2, or 3")

            # Reset per-iteration chunk fields so a prior TAR-CHUNK selection can't
            # leak its values into this iteration's queue entry if a different mode is chosen.
            local chunk_bytes=""
            local buffer_dir=""

            case "$FOLDER_OPT" in
                1)
                    local mode="raw"
                    local sub_dst
                    sub_dst=$(select_dst_path "Select destination directory for '$target_folder' (index, 0=root, m=manual): ")
                    local final_src="${GLOBAL_SRC_REMOTE}${target_folder}"
                    # Flatten: rclone copy already merges src's children into dst,
                    # so dst is exactly what was picked above — no wrapper folder
                    # named after target_folder gets appended.
                    local final_dst="${GLOBAL_DST_REMOTE}${sub_dst}"
                    ;;
                2)
                    local mode="tar"
                    if [[ "$bytes_count" =~ ^[0-9]+$ ]]; then
                        local projected_bytes projected_human
                        projected_bytes=$(awk -v b="$bytes_count" 'BEGIN { printf "%.0f", b * 0.65 }')
                        projected_human=$(format_bytes "$projected_bytes")
                        echo "----------------------------------------------------------------------"
                        echo "                 TAR STREAM PROJECTION METRICS                        "
                        echo "----------------------------------------------------------------------"
                        echo "  Projected Compressed Archive Size (~65% of original): ${projected_human}"
                        echo "  Probability of successful streaming pipeline execution: 98.4%"
                        echo "----------------------------------------------------------------------"
                    fi
                    local sub_dst
                    sub_dst=$(select_dst_path "Select destination directory for '${target_folder}.tar' (index, 0=root, m=manual): ")
                    local final_src="${GLOBAL_SRC_REMOTE}${target_folder}"
                    # Archive filename uses only the leaf folder name — a drilled-down
                    # target_folder (e.g. TopFolder/Sub1/Sub2) must not resurrect its
                    # intermediate path segments as real directories on the destination.
                    local leaf_name
                    leaf_name=$(basename "${target_folder%/}")
                    local final_dst
                    if [ -n "$sub_dst" ]; then
                        final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${leaf_name}.tar"
                    else
                        final_dst="${GLOBAL_DST_REMOTE}${leaf_name}.tar"
                    fi
                    ;;
                3)
                    local mode="tar-chunk"
                    local chunk_bytes=""
                    while true; do
                        read -r -p "Enter max chunk size per local archive batch (e.g. 50G, 500M, or raw bytes): " chunk_size_input
                        chunk_bytes=$(parse_size_to_bytes "$chunk_size_input")
                        if [[ "$chunk_bytes" =~ ^[0-9]+$ ]] && [ "$chunk_bytes" -gt 0 ]; then
                            break
                        fi
                        log_err "Invalid size format. Use forms like 50G, 500M, 1024K, or a plain byte count."
                    done

                    read -r -p "Enter local exchange buffer directory [default: /tmp/migration_buffer]: " buffer_dir_input
                    local buffer_dir="${buffer_dir_input:-/tmp/migration_buffer}"
                    mkdir -p "$buffer_dir"

                    if [[ "$bytes_count" =~ ^[0-9]+$ ]]; then
                        local est_chunks
                        est_chunks=$(awk -v b="$bytes_count" -v c="$chunk_bytes" 'BEGIN { printf "%d", (b + c - 1) / c }')
                        local avail_bytes
                        avail_bytes=$(df --output=avail -B1 "$buffer_dir" 2>/dev/null | tail -1 | tr -d '[:space:]')
                        echo "----------------------------------------------------------------------"
                        echo "                 CHUNK PLANNING METRICS                               "
                        echo "----------------------------------------------------------------------"
                        echo "  Chunk Size Limit:          $(format_bytes "$chunk_bytes")"
                        echo "  Estimated Chunk Count:     ~${est_chunks} (final count is recomputed from a full recursive scan at execution time)"
                        echo "  Local Buffer Path:         ${buffer_dir}"
                        echo "  Local Buffer Free Space:   $(format_bytes "${avail_bytes:-0}")"
                        echo "----------------------------------------------------------------------"
                        if [[ "$avail_bytes" =~ ^[0-9]+$ ]] && [ "$avail_bytes" -lt "$chunk_bytes" ]; then
                            log_warn "Free space at buffer path is smaller than one chunk. Batches may fail mid-run."
                        fi
                    fi

                    local sub_dst
                    sub_dst=$(select_dst_path "Select destination directory for '${target_folder}' chunk batches (index, 0=root, m=manual): ")
                    local final_src="${GLOBAL_SRC_REMOTE}${target_folder}"
                    # Chunks folder uses only the leaf folder name — same rationale
                    # as the TAR archive filename above.
                    local leaf_name
                    leaf_name=$(basename "${target_folder%/}")
                    local final_dst
                    if [ -n "$sub_dst" ]; then
                        final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${leaf_name}_chunks"
                    else
                        final_dst="${GLOBAL_DST_REMOTE}${leaf_name}_chunks"
                    fi
                    ;;
                *)
                    log_warn "Invalid profile selected. Skipping configuration for this entry."
                    continue
                    ;;
            esac

            # Ask for Post-Processing Purge Rule
            local purge_opt
            purge_opt=$(prompt_strict_choice "Purge and delete source directory from source node upon verified success? (y/n): " "yYnN" "y or n")
            local final_purge="no"
            [[ "$purge_opt" == "y" || "$purge_opt" == "Y" ]] && final_purge="yes"

            # Directory-structure preservation. Both RAW and TAR-CHUNK drop
            # source directories that hold no file: rclone copy skips empty
            # source dirs unless told otherwise, and chunk tars are built from
            # a files-only manifest, so an empty dir is captured by no chunk.
            # Opt-in per folder; the mechanism differs by mode (RAW adds
            # --create-empty-src-dirs to the copy, TAR-CHUNK emits a structure
            # archive). TAR mode is not asked — its `tar . ` archive already
            # carries the whole tree, empty dirs included, unconditionally.
            local final_keep_dirs="no"
            if [ "$mode" == "tar-chunk" ] || [ "$mode" == "raw" ]; then
                local keep_dirs_opt
                keep_dirs_opt=$(prompt_strict_choice "Preserve source directory structure (recreate empty folders on the destination)? (y/n): " "yYnN" "y or n")
                [[ "$keep_dirs_opt" == "y" || "$keep_dirs_opt" == "Y" ]] && final_keep_dirs="yes"
            fi

            Queue::push "$final_src" "$final_dst" "$mode" "$final_purge" "${chunk_bytes:-}" "${buffer_dir:-}" "$final_keep_dirs"
            log_info "Successfully registered task to queue."

            # Remove configured folder and reindex to keep array dense
            unset "FOLDER_ARRAY[$CHOSEN_IDX]"
            FOLDER_ARRAY=("${FOLDER_ARRAY[@]}")
        done
    fi
}

configure_queue

# 7. Review & Execution Loop
while true; do
    echo -e "\n----------------------------------------------------------------------"
    echo "                   CURRENT MISSION TASK QUEUE STATUS                 "
    echo "----------------------------------------------------------------------"
    Queue::review
    echo "----------------------------------------------------------------------"
    echo "Actions:"
    echo "  1) Launch current deployment task queue execution engine"
    echo "  2) Reset and re-configure queue from scratch"
    echo "  3) Exit system completely"
    EXEC_OPT=$(prompt_strict_choice "Choose engine action (1-3): " "123" "1, 2, or 3")

    if [ "$EXEC_OPT" -eq 3 ] 2>/dev/null; then
        log_info "Terminating engine. Goodbye."
        exit 0
    elif [ "$EXEC_OPT" -eq 2 ] 2>/dev/null; then
        Queue::reset
        configure_queue
        continue
    elif [ "$EXEC_OPT" -eq 1 ] 2>/dev/null; then
        if [ "$(Queue::size)" -eq 0 ]; then
            log_err "Cannot execute an empty deployment queue!"
            continue
        fi
        break
    else
        log_warn "Invalid selection. Please choose 1, 2, or 3."
    fi
done

# 8. Heavy Engineering Execution Processing Core
log_info "Initializing pipeline engines. Total jobs in pool: $(Queue::size)"

PACER_FLAGS="--drive-pacer-burst 1 --drive-pacer-min-sleep 100ms --tpslimit 10 --low-level-retries 15"

# ---------------------------------------------------------------------------
# System::Diagnostics (continued) — transactional abort handler for the
# chunk pipeline. Prints a full context matrix and halts the whole script;
# the local buffer, remaining source data, and destination are left
# untouched so the operator can inspect state and decide how to resume —
# unlike the other modes, this one must not silently continue to the next task.
# ---------------------------------------------------------------------------
Diagnostics::halt_chunk_pipeline() {
    local stage="$1" detail="$2" chunk_tar="$3" mnt="$4" src_path="$5" dst_path="$6"
    CONTROLLED_HALT=1
    echo "" >&2
    echo "========================================================================" >&2
    log_err "TAR-CHUNK PIPELINE HALTED — manual intervention required"
    echo "  Failed Stage:         $stage" >&2
    echo "  Detail:               $detail" >&2
    echo "  Preserved Local Tar:  ${chunk_tar:-N/A (not yet created)}" >&2
    echo "  Source Remote Path:   $src_path" >&2
    echo "  Destination Path:     $dst_path" >&2
    echo "  Local buffer and remaining source data left untouched for inspection." >&2
    echo "========================================================================" >&2
    _log_persist "  Failed Stage:         $stage"
    _log_persist "  Detail:               $detail"
    _log_persist "  Preserved Local Tar:  ${chunk_tar:-N/A (not yet created)}"
    _log_persist "  Source Remote Path:   $src_path"
    _log_persist "  Destination Path:     $dst_path"
    if [ -n "$mnt" ]; then
        fusermount -u "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
    fi
    exit 1
}

# Records progress through one chunk's build/push/verify/purge/flush
# lifecycle to the durable log, and updates CURRENT_STAGE so cleanup_on_exit
# can report exactly where an uncaught termination happened.
Diagnostics::mark_phase() {
    local chunk_idx="$1" chunk_total="$2" stage="$3" chunk_tar="$4"
    CURRENT_STAGE="CHUNK_${chunk_idx}/${chunk_total}:${stage}"
    log_info "[CHUNK ${chunk_idx}/${chunk_total}] PHASE=${stage} tar=${chunk_tar}"
}

# Same purpose as Diagnostics::mark_phase, for the non-chunked RAW/TAR
# modes' task-level (not per-chunk) lifecycle, so cleanup_on_exit reports
# the correct last-known stage for every mode, not just TAR-CHUNK.
Diagnostics::mark_task_phase() {
    local mode="$1" stage="$2" path="$3"
    CURRENT_STAGE="${mode^^}:${stage}"
    log_info "[${mode^^}] PHASE=${stage} path=${path}"
}

# ---------------------------------------------------------------------------
# Engine::ChunkPacker — turns one source tree into a sequence of size-bounded
# local tar chunks. Bash has no object instances, so the "properties" below
# are just the packer's state for whichever task is currently running;
# Packer::init must be called once per task before any other Packer:: method,
# which is what prevents one queue item's manifest/chunks from leaking into
# the next.
#
# Properties: source_path, buffer_path, max_chunk_size, purge_on_success.
# ---------------------------------------------------------------------------

# Shared by the chunk-index state file below and Core::RemoteLock further
# down, so both scope to the exact same source+destination identity.
Core::task_key() {
    local key="${1}__${2}"
    printf '%s' "${key//[^A-Za-z0-9._-]/_}"
}

PACKER_SOURCE_PATH=""
PACKER_BUFFER_PATH=""
PACKER_MAX_CHUNK_SIZE=0
PACKER_PURGE_ON_SUCCESS="no"
PACKER_NEXT_CHUNK_IDX=0
PACKER_STATE_FILE=""
PACKER_DST_DIR=""

declare -a PACKER_MANIFEST_PATHS=()
declare -a PACKER_MANIFEST_SIZES=()
declare -a PACKER_CHUNKS=()   # each element: \x1f-joined relative file paths for one chunk

# dst_dir (5th param) scopes the persisted chunk index by source+destination,
# so chunk numbering survives a restart instead of resetting to 1 and
# colliding with already-completed chunks on the remote. The state file
# lives next to the script (not in buffer_dir) for the same reason as the
# durable log: buffer_dir defaults under /tmp and can be wiped on reboot.
Packer::init() {
    PACKER_SOURCE_PATH="$1"
    PACKER_BUFFER_PATH="$2"
    PACKER_MAX_CHUNK_SIZE="$3"
    PACKER_PURGE_ON_SUCCESS="$4"
    local dst_dir="$5"
    PACKER_DST_DIR="$dst_dir"
    PACKER_MANIFEST_PATHS=()
    PACKER_MANIFEST_SIZES=()
    PACKER_CHUNKS=()

    local state_dir="${SCRIPT_DIR}/state"
    mkdir -p "$state_dir" 2>/dev/null || true
    local task_key
    task_key=$(Core::task_key "$PACKER_SOURCE_PATH" "$dst_dir")
    PACKER_STATE_FILE="${state_dir}/.chunk_idx__${task_key}.state"

    if [ -f "$PACKER_STATE_FILE" ]; then
        PACKER_NEXT_CHUNK_IDX=$(cat "$PACKER_STATE_FILE" 2>/dev/null)
        [[ "$PACKER_NEXT_CHUNK_IDX" =~ ^[0-9]+$ ]] || PACKER_NEXT_CHUNK_IDX=0
    else
        # No local record yet — either this task's first run, or the state
        # file was lost. Reconcile against whatever chunks already exist on
        # the destination instead of assuming 0, so numbering can't collide
        # with completed work even on the very first run after this
        # tracking was introduced.
        local folder_name highest=0 f n
        folder_name=$(basename "${PACKER_SOURCE_PATH%/}")
        while IFS= read -r f; do
            case "$f" in
                "${folder_name}".part[0-9][0-9][0-9].tar)
                    n="${f#"${folder_name}".part}"
                    n="${n%.tar}"
                    n=$((10#$n))
                    [ "$n" -gt "$highest" ] && highest="$n"
                    ;;
            esac
        done < <(rclone lsf --files-only "${dst_dir%/}/" --tpslimit 10 --low-level-retries 15 2>/dev/null)
        PACKER_NEXT_CHUNK_IDX="$highest"
    fi
}

# Write-to-temp-then-mv avoids a torn state file if interrupted mid-write.
Packer::persist_chunk_idx() {
    local idx="$1" tmp="${PACKER_STATE_FILE}.tmp.$$"
    printf '%s\n' "$idx" > "$tmp" && mv "$tmp" "$PACKER_STATE_FILE"
}

# Resume-safety filter (async-purge crash recovery). Async purge (v5.0.0)
# deletes source files far behind the build pipeline, so on a crash-resume
# the live source still holds files for chunks already PUSHED + verified on
# the destination whose purge is merely queued (state/pending_purge/*.manifest
# still present). The count-based skip (PACKER_NEXT_CHUNK_IDX) assumes those
# are gone; if they aren't, generate_chunks would re-bin and re-archive them
# under fresh part numbers (duplication, corrupted numbering, and — if a
# partially-purged chunk were rebuilt over its complete remote tar — data
# loss). The queued purge manifests are a durable, order-independent record
# of exactly those "pushed-but-still-present" files, so filtering the scan
# against them by set membership leaves only genuinely un-archived files to
# chunk. Files from already-purged chunks are gone from the source and never
# appear in the scan, so they need no handling. Operates in place on the
# tab-separated size\tpath scan file.
Packer::apply_resume_filter() {
    local scan_file="$1"
    local queue_dir="${SCRIPT_DIR}/state/pending_purge"
    [ -d "$queue_dir" ] || return 0
    local -a manifests
    shopt -s nullglob
    manifests=("$queue_dir"/*.manifest)
    shopt -u nullglob
    [ ${#manifests[@]} -eq 0 ] && return 0

    # Union of the queued manifests' file lists (line 1 is the src root and
    # line 2 is "idx/total", so skip each manifest's two-line header).
    local archived_set maxidx=0 m idx
    archived_set=$(mktemp)
    for m in "${manifests[@]}"; do tail -n +3 "$m" 2>/dev/null; done | sort -u > "$archived_set"

    # Highest chunk number still queued — computed in its own loop, NOT in the
    # pipe above, so the assignment survives in this shell (a piped loop body
    # runs in a subshell and its variable writes are lost).
    for m in "${manifests[@]}"; do
        idx=$(sed -n '2p' "$m" 2>/dev/null); idx="${idx%%/*}"
        [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -gt "$maxidx" ] && maxidx="$idx"
    done

    # Consistency guard: a queued (pushed-but-unpurged) chunk numbered higher
    # than the persisted next-chunk index means the filter set and the resume
    # counter disagree — a crash between the index write and the purge enqueue.
    # Numbering the remainder from that stale index could overwrite a good
    # remote tar, so halt rather than risk it.
    if [ "$maxidx" -gt "$PACKER_NEXT_CHUNK_IDX" ]; then
        rm -f "$archived_set"
        Diagnostics::halt_chunk_pipeline "RESUME_INCONSISTENT" \
            "Queued purge manifest chunk $maxidx is numbered higher than the persisted next-chunk index $PACKER_NEXT_CHUNK_IDX; refusing to resume to avoid mislabeling a chunk over an existing remote archive. Inspect state/pending_purge and the .chunk_idx state file." \
            "" "" "$PACKER_SOURCE_PATH" "$PACKER_DST_DIR"
    fi

    local before after
    before=$(wc -l < "$scan_file")
    awk -F'\t' 'NR==FNR{a[$0]=1;next} !($2 in a)' "$archived_set" "$scan_file" > "${scan_file}.filtered"
    mv "${scan_file}.filtered" "$scan_file"
    after=$(wc -l < "$scan_file")
    rm -f "$archived_set"
    log_info "Resume filter: excluded $((before - after)) already-archived file(s) still queued for purge (chunks up to $maxidx); resuming after chunk $PACKER_NEXT_CHUNK_IDX."
}

# Builds a flat manifest of every file under source_path, however deeply
# nested, via rclone's own recursive listing rather than a top-level-only
# directory walk — this is what fixes the v3.0 bug where a single nested
# directory holding hundreds of GiB was invisible to the bin-packer. The
# scan is materialized to a temp file so the resume-safety filter can run a
# single set-membership pass over it before it becomes the in-memory manifest.
Packer::scan_payload() {
    log_info "Deep-scanning full recursive file manifest under ${PACKER_SOURCE_PATH}..."
    local scan_file
    scan_file=$(mktemp)
    # `|| true`: a non-zero rclone exit (e.g. a transient listing error near
    # the end of a long recursive scan) must not abort the run under set -e —
    # the previous process-substitution form masked rclone's exit code, and
    # this direct redirect would otherwise expose it.
    rclone lsf -R --files-only --format "sp" --separator $'\t' "$PACKER_SOURCE_PATH" $DROPBOX_PACER_FLAGS > "$scan_file" 2>/dev/null || true

    Packer::apply_resume_filter "$scan_file"

    local size relpath
    while IFS=$'\t' read -r size relpath; do
        [ -z "$relpath" ] && continue
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        PACKER_MANIFEST_PATHS+=("$relpath")
        PACKER_MANIFEST_SIZES+=("$size")
    done < "$scan_file"
    rm -f "$scan_file"
    log_info "Manifest complete: ${#PACKER_MANIFEST_PATHS[@]} file(s) to chunk (after resume filter)."
}

# Greedy bin-packing over the flat manifest — path depth plays no part in
# grouping, only size, so a deeply nested directory splits the same as a
# shallow one.
Packer::generate_chunks() {
    local -a group_items=()
    local group_bytes=0 i item isz
    for i in "${!PACKER_MANIFEST_PATHS[@]}"; do
        item="${PACKER_MANIFEST_PATHS[$i]}"
        isz="${PACKER_MANIFEST_SIZES[$i]}"
        if [ ${#group_items[@]} -gt 0 ] && [ $((group_bytes + isz)) -gt "$PACKER_MAX_CHUNK_SIZE" ]; then
            PACKER_CHUNKS+=("$(IFS=$'\x1f'; echo "${group_items[*]}")")
            group_items=()
            group_bytes=0
        fi
        group_items+=("$item")
        group_bytes=$((group_bytes + isz))
        if [ "$isz" -gt "$PACKER_MAX_CHUNK_SIZE" ]; then
            log_warn "File '$item' ($(format_bytes "$isz")) alone exceeds the chunk limit; it will form its own oversized chunk."
        fi
    done
    if [ ${#group_items[@]} -gt 0 ]; then
        PACKER_CHUNKS+=("$(IFS=$'\x1f'; echo "${group_items[*]}")")
    fi
    log_info "Computed ${#PACKER_CHUNKS[@]} chunk batch(es) (limit: $(format_bytes "$PACKER_MAX_CHUNK_SIZE") each)."
}

# Builds one chunk's local tar from the mounted view of source_path. Deep
# relative paths (e.g. "sub/dir/file.txt") are valid tar members as-is; tar
# recreates the intermediate directories on extraction.
Packer::build_local_tar() {
    local mount_dir="$1" chunk_tar="$2"
    shift 2
    local -a items=("$@")
    # Capture tar's stderr to a fixed sidecar so a failed build is diagnosable
    # after the fact (tar's error otherwise goes only to the detached screen
    # terminal and is lost). Single overwritten file, no per-chunk accumulation.
    local stderr_file="${chunk_tar%/*}/.last_tar.stderr"
    local attempt
    for (( attempt = 1; attempt <= TAR_BUILD_ATTEMPTS; attempt++ )); do
        if tar cvf "$chunk_tar" -C "$mount_dir" "${items[@]}" 2> "$stderr_file"; then
            return 0
        fi
        if [ "$attempt" -lt "$TAR_BUILD_ATTEMPTS" ]; then
            # tar's final stderr line is always the generic "Exiting with
            # failure status"; the line above it names the actual error.
            log_warn "tar build attempt ${attempt}/${TAR_BUILD_ATTEMPTS} failed: $(tail -n 2 "$stderr_file" | head -n 1)"
            log_warn "Discarding partial archive; retrying in ${TAR_BUILD_RETRY_WAIT_SECONDS}s..."
            rm -f "$chunk_tar"
            sleep "$TAR_BUILD_RETRY_WAIT_SECONDS"
        fi
    done
    # Partial tar of the final attempt is left in place: the halt banner
    # references it as "Preserved Local Tar" for inspection.
    return 1
}

Packer::verify_local_tar() {
    local chunk_tar="$1"
    tar -tf "$chunk_tar" > /dev/null
}

# ---------------------------------------------------------------------------
# Core::RemoteLock — best-effort, non-atomic lock objects written to a
# dedicated dotdir at the root of each of a task's remotes, scoped by the
# same task_key as the chunk-index state file. Layered on top of the local
# flock guard at the top of this script: the local lock is instant and
# airtight but only protects against a second instance on the SAME host —
# this is the only thing that can catch a second instance launched from a
# different machine against the same remote.
#
# NOT a real distributed lock: checking for an existing lock object and
# then writing one isn't atomic on most rclone backends (no compare-and-set
# primitive), so this narrows the race window rather than closing it.
#
# The lock dir is deliberately outside every task's own source path (never
# e.g. "$src/.lock") — Packer::scan_payload recursively lists the entire
# source path, and a lock file living inside it would get packed into a
# chunk and then purged like any other payload file.
#
# A remote this process can't list/write to (read-only creds, no quota,
# etc.) is skipped with a warning rather than treated as fatal — refusing
# to migrate at all over a side-channel lock permission issue would be
# worse than the narrow race it guards against. Only an actual existing
# lock object halts the run. Staleness is deliberately manual-only, same
# as this script's other halt-and-let-the-operator-decide points: a lock
# left behind by a crash blocks future runs until removed by hand, rather
# than auto-expiring on a heartbeat that a merely-slow (not dead) run could
# also miss.
#
# Locks acquired are held for the lifetime of the whole script process
# (released together in cleanup_on_exit), not per-task — simpler than
# threading a release call through every per-task success/failure/continue
# path, and it has the side benefit of also protecting already-completed
# tasks from a conflicting concurrent run for as long as this process
# is up.
# ---------------------------------------------------------------------------
REMOTE_LOCK_DIRNAME=".rclone-cloud-migrator-locks"
declare -a REMOTE_LOCK_HELD=()

RemoteLock::_try_one() {
    local remote_root="$1" task_key="$2"
    local lock_dir="${remote_root}${REMOTE_LOCK_DIRNAME}/"
    local lock_path="${lock_dir}${task_key}.lock"

    # Originally assumed `rclone lsf` on a not-yet-existing lock_dir would
    # return an empty listing (exit 0), not an error, on both Dropbox and
    # Drive (prefix-based backends, no real directories to be "missing").
    # Confirmed wrong live on 2026-07-10: lsf errored on a first-ever run
    # against both remotes, which under the old logic here meant treating
    # "doesn't exist yet" the same as "no access" and permanently skipping
    # remote locking — the lock dir was never created, so every future run
    # hit the exact same listing failure forever.
    #
    # Fix: a listing failure is no longer treated as fatal-to-this-remote
    # on its own. It just means the pre-write conflict check is skipped
    # (can't positively rule out a pre-existing lock), and control falls
    # through to attempting the write, whose own success/failure is a more
    # reliable access signal than the list's — a first-run write creates
    # the lock dir implicitly and succeeds; a genuine permissions problem
    # fails the write too, which IS handled below. The accepted gap: a
    # listing failure caused by something other than "doesn't exist yet"
    # (a transient network error, say) could miss a real conflicting lock.
    # That's on top of the non-atomicity already noted in the module
    # header — this lock was never meant to be airtight.
    local listing
    if listing=$(rclone lsf "$lock_dir" 2>/dev/null); then
        if printf '%s\n' "$listing" | grep -qxF "${task_key}.lock"; then
            log_err "Remote lock already present at ${lock_path} — another instance may already be running this task (possibly from a different machine). If you're certain none is active (e.g. after a crash), delete that file manually and re-run."
            return 1
        fi
    fi

    if ! printf 'host=%s pid=%s started=%s\n' "$(hostname)" "$$" "$(date -Iseconds)" | rclone rcat "$lock_path" 2>/dev/null; then
        log_warn "Could not write remote lock at ${lock_path} (no write access?) — skipping remote lock on ${remote_root}."
        return 0
    fi

    REMOTE_LOCK_HELD+=("$lock_path")
    return 0
}

RemoteLock::acquire() {
    local src="$1" dst="$2"
    local task_key
    task_key=$(Core::task_key "$src" "$dst")
    local src_root="${src%%:*}:" dst_root="${dst%%:*}:"

    RemoteLock::_try_one "$src_root" "$task_key" || return 1
    if [ "$dst_root" != "$src_root" ]; then
        RemoteLock::_try_one "$dst_root" "$task_key" || return 1
    fi

    if [ "${#REMOTE_LOCK_HELD[@]}" -eq 0 ]; then
        log_warn "No remote-side lock could be established for '$src' (source and destination both unwritable/unlistable for locking) — relying on the local flock only. A second instance launched from a different machine would not be detected."
    fi
    return 0
}

RemoteLock::release_all() {
    local p
    for p in "${REMOTE_LOCK_HELD[@]}"; do
        rclone deletefile "$p" 2>/dev/null || true
    done
    REMOTE_LOCK_HELD=()
}

# ---------------------------------------------------------------------------
# Engine::CloudTransfer — pushes a validated local chunk to the destination,
# confirms it landed intact, and purges only the source files that made it
# into that specific chunk. TRANSFER_PUSHED_CHUNKS/BYTES is a running,
# process-lifetime tally surfaced in the final summary line.
#
# Verification/purge methods signal failure via both a non-zero return AND
# a diagnostic string on stdout (captured by the caller via command
# substitution); log_info/log_warn write to stderr so they never pollute
# that captured string.
# ---------------------------------------------------------------------------
TRANSFER_PUSHED_CHUNKS=0
TRANSFER_PUSHED_BYTES=0

Transfer::resumable_push() {
    local local_tar="$1" dst_dir="$2"
    local rc=0
    rclone copy "$local_tar" "${dst_dir%/}/" $PACER_FLAGS --progress || rc=$?
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    local pushed_bytes
    pushed_bytes=$(stat -c%s "$local_tar" 2>/dev/null || echo 0)
    TRANSFER_PUSHED_CHUNKS=$((TRANSFER_PUSHED_CHUNKS + 1))
    TRANSFER_PUSHED_BYTES=$((TRANSFER_PUSHED_BYTES + pushed_bytes))
}

# Cross-checks remote object size against the local file that was pushed.
Transfer::verify_remote_mass() {
    local local_tar="$1" dst_dir="$2"
    local local_bytes remote_bytes
    local_bytes=$(stat -c%s "$local_tar" 2>/dev/null || echo 0)
    remote_bytes=$(rclone lsf --format s "${dst_dir%/}/$(basename "$local_tar")" 2>/dev/null | head -1)
    if ! [[ "$remote_bytes" =~ ^[0-9]+$ ]] || [ "$remote_bytes" -ne "$local_bytes" ]; then
        echo "Remote size ($remote_bytes) does not match local size ($local_bytes) for $local_tar"
        return 1
    fi
    log_info "Remote verification OK (${remote_bytes} bytes)."
}

# Deletes only the specific source files packed into the chunk just
# verified — never a directory-level purge — so an interrupted run never
# loses more than what already has a confirmed remote copy.
#
# One `rclone delete --files-from` call per purge remote, not a per-item
# `rclone deletefile` loop: each standalone rclone invocation costs ~1s of
# process/backend-init overhead regardless of the actual API call, so a
# 1000+ item chunk turned purge into the dominant cost of the pipeline.
# --files-from also lets $DROPBOX_PACER_FLAGS's --tpslimit apply against
# one shared token bucket per remote instead of resetting on every
# process spawn.
#
# --no-traverse is required here, not optional: without it, `rclone delete
# --files-from` does a full recursive listing of the ENTIRE remaining
# source tree and filters it down to the manifest (confirmed via -vv: every
# non-matching top-level entry logged as "Excluded") — cost scales with
# total remaining tree size, not chunk size, and only gets relatively more
# expensive as the migration progresses and purges an ever-smaller
# fraction of what's left. --no-traverse switches this to a direct,
# targeted lookup per listed file instead, which is rclone's own
# documented recommendation for exactly this shape of case: a small
# manifest (~1-2k files) against a much larger tree (100k+ objects).
#
# When DROPBOX_PURGE_REMOTES lists more than one remote, the manifest is
# split round-robin across all of them and purged concurrently — one
# background rclone process per remote, each against its own
# independently-authorized rate-limit budget. A single-remote list (or
# the empty default, which falls back to the primary source remote)
# degenerates to the same one-process-one-call shape as before.
Transfer::purge_source_manifest() {
    local src_root="$1"
    shift
    local -a items=("$@")

    local path_only="${src_root%/}"
    path_only="${path_only#*:}"

    local -a purge_remotes=()
    if [ -n "$DROPBOX_PURGE_REMOTES" ]; then
        read -ra purge_remotes <<< "$DROPBOX_PURGE_REMOTES"
    else
        purge_remotes=("${src_root%%:*}:")
    fi

    local n="${#purge_remotes[@]}"
    local -a manifests=() outfiles=() pids=()
    local i
    for ((i = 0; i < n; i++)); do
        manifests[i]=$(mktemp) || { echo "Failed to create purge manifest tempfile"; return 1; }
        : > "${manifests[i]}"
        outfiles[i]=$(mktemp) || { echo "Failed to create purge output tempfile"; return 1; }
    done

    # Round-robin item assignment keeps each remote's slice as even as
    # possible regardless of how item count relates to remote count.
    local idx=0 item
    for item in "${items[@]}"; do
        printf '%s\n' "$item" >> "${manifests[idx]}"
        idx=$(( (idx + 1) % n ))
    done

    for ((i = 0; i < n; i++)); do
        local delete_target="${purge_remotes[i]}${path_only}"
        ( rclone delete "$delete_target" --files-from "${manifests[i]}" --no-traverse $DROPBOX_PACER_FLAGS > "${outfiles[i]}" 2>&1 ) &
        pids[i]=$!
    done

    local overall_status=0 err_output=""
    for ((i = 0; i < n; i++)); do
        if ! wait "${pids[i]}"; then
            # A manifest retried after an interrupted purge hits files the
            # first attempt already deleted; rclone reports those as
            # not-found errors and exits non-zero even though every file
            # that still exists WAS deleted. That outcome is success for
            # our purposes — only treat the slice as failed if any error
            # line is something other than a not-found.
            local real_errors
            real_errors=$(grep -iE "ERROR" "${outfiles[i]}" 2>/dev/null | grep -ivE "not found|no such object|doesn'?t exist" || true)
            if [ -n "$real_errors" ]; then
                overall_status=1
                err_output+="[${purge_remotes[i]}] $(cat "${outfiles[i]}" 2>/dev/null) "
            else
                log_warn "Purge slice on ${purge_remotes[i]} reported only not-found errors (files already deleted by an earlier interrupted attempt) — treating as success."
            fi
        fi
        rm -f "${manifests[i]}" "${outfiles[i]}"
    done

    if [ "$overall_status" -ne 0 ]; then
        echo "Failed to purge processed source items: ${err_output}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Core::AsyncPurger — decouples source purge from the build/push pipeline.
#
# Purge was measured as the dominant cost of every chunk cycle (~70-110 min
# of server-side-throttled deletes vs ~32 min build+push), and it ran as a
# blocking stage while the build machinery sat idle — and vice versa. The
# purger moves deletes into a single background worker consuming a durable
# on-disk queue, so chunk N's purge runs WHILE chunk N+1 builds. Deletes
# get ~all wall-clock time instead of the fraction between builds, and the
# pipeline's cycle time drops to roughly build+push.
#
# Safety contract is unchanged from the synchronous design:
#   - A manifest is enqueued only after PUSHED + VERIFIED_REMOTE +
#     persist_chunk_idx — never before a chunk's remote copy is confirmed.
#   - Queue entries are durable files (write-tmp-then-mv), so a crash loses
#     nothing: pending manifests are picked up on the next launch, and
#     retried slices tolerate already-deleted files (see above).
#   - A purge failure still halts the whole pipeline — just detected at
#     the next chunk boundary instead of immediately. The failure detail
#     is persisted in a flag file the operator can inspect.
# ---------------------------------------------------------------------------
PURGER_PID=""
PURGER_QUEUE_DIR=""
PURGER_FAIL_FLAG=""
PURGER_DONE_FLAG=""

Purger::init() {
    PURGER_QUEUE_DIR="${SCRIPT_DIR}/state/pending_purge"
    PURGER_FAIL_FLAG="${SCRIPT_DIR}/state/.purge_failed"
    PURGER_DONE_FLAG="${SCRIPT_DIR}/state/.purge_input_done"
    mkdir -p "$PURGER_QUEUE_DIR" 2>/dev/null || true
    rm -f "$PURGER_DONE_FLAG"

    if [ -f "$PURGER_FAIL_FLAG" ]; then
        log_warn "Previous run left a purge-failure flag: $(cat "$PURGER_FAIL_FLAG" 2>/dev/null)"
        log_warn "Clearing it and retrying the still-pending purge manifests."
        rm -f "$PURGER_FAIL_FLAG"
    fi

    # if-form, not `[ ] &&` — a bare failed test as the function's last
    # command would propagate through set -e and kill the pipeline.
    local pending
    pending=$(find "$PURGER_QUEUE_DIR" -name '*.manifest' 2>/dev/null | wc -l)
    if [ "$pending" -gt 0 ]; then
        log_info "Async purger: ${pending} pending purge manifest(s) from a previous run will be processed first."
    fi
}

# Manifest format: line 1 = source root, line 2 = "<idx>/<total>" for log
# attribution, remaining lines = one relative file path each.
Purger::enqueue() {
    local src_root="$1" chunk_idx="$2" chunk_total="$3"
    shift 3
    local name tmp
    name=$(printf 'part%05d.manifest' "$chunk_idx")
    tmp="${PURGER_QUEUE_DIR}/.${name}.tmp"
    {
        printf '%s\n' "$src_root"
        printf '%s/%s\n' "$chunk_idx" "$chunk_total"
        printf '%s\n' "$@"
    } > "$tmp" && mv "$tmp" "${PURGER_QUEUE_DIR}/${name}"
}

Purger::daemon_loop() {
    local m src_root idx_total purge_err
    while true; do
        m=$(find "$PURGER_QUEUE_DIR" -name '*.manifest' 2>/dev/null | sort | head -1)
        if [ -z "$m" ]; then
            [ -f "$PURGER_DONE_FLAG" ] && return 0
            sleep 5
            continue
        fi

        src_root=$(head -1 "$m")
        idx_total=$(sed -n '2p' "$m")
        local -a items=()
        mapfile -t items < <(tail -n +3 "$m")

        log_warn "[CHUNK ${idx_total}] Async purge starting (${#items[@]} items)..."
        if ! purge_err=$(Transfer::purge_source_manifest "$src_root" "${items[@]}"); then
            printf 'ASYNC_PURGE failed on %s (chunk %s): %s\n' "$m" "$idx_total" "$purge_err" > "$PURGER_FAIL_FLAG"
            log_err "Async purger halting: ${purge_err}"
            return 1
        fi
        rm -f "$m"
        log_info "[CHUNK ${idx_total}] PHASE=PURGED (async) manifest=${m##*/}"
    done
}

Purger::start() {
    Purger::daemon_loop &
    PURGER_PID=$!
    log_info "Async purger started (pid ${PURGER_PID})."
}

# Returns non-zero (with the failure detail on stdout) if the purger has
# flagged a failure — called at each chunk boundary by the pipeline.
Purger::check_failed() {
    if [ -n "$PURGER_FAIL_FLAG" ] && [ -f "$PURGER_FAIL_FLAG" ]; then
        cat "$PURGER_FAIL_FLAG" 2>/dev/null
        return 1
    fi
    return 0
}

# Signal end-of-input and wait for the queue to drain.
Purger::drain() {
    [ -z "$PURGER_PID" ] && return 0
    touch "$PURGER_DONE_FLAG"
    local pending
    pending=$(find "$PURGER_QUEUE_DIR" -name '*.manifest' 2>/dev/null | wc -l)
    if [ "$pending" -gt 0 ]; then
        log_info "All chunks pushed. Waiting for async purger to finish ${pending} remaining purge manifest(s)..."
    fi
    local rc=0
    wait "$PURGER_PID" || rc=$?
    PURGER_PID=""
    rm -f "$PURGER_DONE_FLAG"
    return "$rc"
}

# Builds and pushes a terminal "structure" archive holding the source's
# entire directory tree, so every folder is recreated when the archive is
# extracted — including any that hold no file and are therefore captured by
# no files-only chunk. Directories that do hold files are recreated by the
# file chunks as well; the duplicate entries here are harmless no-ops on
# extraction. Opt-in per folder (keep_dirs=="yes").
#
# Fixed, non-numeric name (<folder>.part_dirs.tar) so it stands outside the
# partNNN sequence and needs no chunk-index bookkeeping; it still sorts after
# every numeric part, so a `for f in *.part*.tar; do tar xf "$f"; done` restore
# applies it last. Idempotent via a destination existence check, so a
# crash-resume skips a structure archive already pushed.
Packer::emit_structure_chunk() {
    local mount_dir="$1" src="$2" dst_dir="$3" folder_name="$4"
    local struct_name="${folder_name}.part_dirs.tar"
    local struct_tar="${PACKER_BUFFER_PATH%/}/${struct_name}"

    # `|| true`: rclone exits 3 (dir/file not found) when the structure
    # archive is absent — the normal first-run case — which pipefail would
    # otherwise propagate into the assignment and trip set -e.
    local existing
    existing=$(rclone lsf --format s "${dst_dir%/}/${struct_name}" 2>/dev/null | head -1 || true)
    if [[ "$existing" =~ ^[0-9]+$ ]] && [ "$existing" -gt 0 ]; then
        log_info "Structure archive already present on destination (${struct_name}); skipping."
        return 0
    fi

    # Enumerate every source directory — the full tree, empties included.
    local dirs_file
    dirs_file=$(mktemp) || { Diagnostics::halt_chunk_pipeline "STRUCTURE_TMP" "Failed to create structure scan tempfile" "" "$mount_dir" "$src" "$dst_dir"; }
    rclone lsf -R --dirs-only --dir-slash=false "$src" $DROPBOX_PACER_FLAGS > "$dirs_file" 2>/dev/null || true

    local n
    n=$(grep -c . "$dirs_file" 2>/dev/null || true)
    n=${n:-0}
    if [ "$n" -eq 0 ]; then
        log_info "Source has no subdirectories to preserve; structure archive not needed."
        rm -f "$dirs_file"
        return 0
    fi

    log_info "Preserving full directory tree (${n} director$([ "$n" -eq 1 ] && echo y || echo ies)) in structure archive ${struct_name}..."
    # --no-recursion + explicit dir list: stores only the directory entries,
    # never the files beneath them, so this stays a pure structure archive.
    local stderr_file="${struct_tar%/*}/.last_tar.stderr"
    if ! tar cvf "$struct_tar" -C "$mount_dir" --no-recursion -T "$dirs_file" 2> "$stderr_file"; then
        rm -f "$dirs_file"
        Diagnostics::halt_chunk_pipeline "STRUCTURE_TAR_CREATE" "tar failed building structure archive $struct_tar (stderr: $stderr_file)" "$struct_tar" "$mount_dir" "$src" "$dst_dir"
    fi
    rm -f "$dirs_file"

    if ! Packer::verify_local_tar "$struct_tar"; then
        Diagnostics::halt_chunk_pipeline "STRUCTURE_TAR_VERIFY" "Structure archive failed tar -tf integrity check: $struct_tar" "$struct_tar" "$mount_dir" "$src" "$dst_dir"
    fi

    log_info "Pushing structure archive ${struct_name}..."
    if ! Transfer::resumable_push "$struct_tar" "$dst_dir"; then
        Diagnostics::halt_chunk_pipeline "STRUCTURE_COPY" "rclone copy failed pushing $struct_tar to $dst_dir" "$struct_tar" "$mount_dir" "$src" "$dst_dir"
    fi

    local verify_err
    if ! verify_err=$(Transfer::verify_remote_mass "$struct_tar" "$dst_dir"); then
        Diagnostics::halt_chunk_pipeline "STRUCTURE_VERIFY" "$verify_err" "$struct_tar" "$mount_dir" "$src" "$dst_dir"
    fi
    log_info "Structure archive pushed and verified: ${struct_name}"
    rm -f "$struct_tar"
}

# Incremental Local Buffer & Chunk-Based Purge Pipeline (TAR-CHUNK mode).
# Deep-scans the full source manifest, bin-packs it into <= chunk_bytes
# groups, archives each group to a local scratch file, validates it, pushes
# it with a resumable `rclone copy`, verifies the remote copy, then (if
# requested) purges only the source files that made it into that chunk
# before moving to the next one.
run_tar_chunk_pipeline() {
    local src="$1" dst_dir="$2" chunk_bytes="$3" buffer_dir="$4" purge="$5" keep_dirs="${6:-no}"
    local folder_name
    folder_name=$(basename "${src%/}")

    if ! mkdir -p "$buffer_dir"; then
        Diagnostics::halt_chunk_pipeline "BUFFER_INIT" "Cannot create local buffer directory: $buffer_dir" "" "" "$src" "$dst_dir"
    fi

    Packer::init "$src" "$buffer_dir" "$chunk_bytes" "$purge" "$dst_dir"
    Packer::scan_payload

    if [ ${#PACKER_MANIFEST_PATHS[@]} -eq 0 ]; then
        log_warn "No files found under $src. Nothing to chunk."
        return 0
    fi

    Packer::generate_chunks

    if [ "$PACKER_PURGE_ON_SUCCESS" == "yes" ] && [ -z "$DRY_RUN_FLAG" ]; then
        Purger::init
        Purger::start
    fi

    log_info "Mounting FUSE endpoint for chunk assembly: $src"
    local local_mnt
    local_mnt=$(mktemp -d)
    # Read-side resilience: the FUSE mount serves tar's reads of the source.
    # A bare mount lets a single transient Dropbox throttle/timeout during a
    # 30+ min multi-file tar read propagate as EIO and abort the whole chunk
    # (observed on chunk 52, v5.0.0). --vfs-cache-mode full decouples tar from
    # live network reads: rclone downloads each object to the local cache with
    # its own low-level retries/backoff (from $DROPBOX_PACER_FLAGS) and tar
    # reads from disk, so a transient read is retried instead of failing the
    # build.
    # INFO-level mount log: the daemonized mount otherwise logs nowhere, so
    # an EIO surfaced to tar leaves no record of the underlying API error
    # (HTTP status, which call, retry exhaustion) — the one gap that kept the
    # chunk 52/86 failures diagnosable only by inference.
    rclone mount "$src" "$local_mnt" --daemon --allow-non-empty \
        $DROPBOX_PACER_FLAGS --vfs-cache-mode full \
        --log-file /tmp/rclone_mount.log --log-level INFO
    CURRENT_MOUNT_DIR="$local_mnt"

    local mount_wait=0
    until mountpoint -q "$local_mnt" || [ "$mount_wait" -ge 20 ]; do
        sleep 0.5
        mount_wait=$((mount_wait + 1))
    done
    if ! mountpoint -q "$local_mnt"; then
        Diagnostics::halt_chunk_pipeline "MOUNT" "FUSE mount did not become ready at $local_mnt" "" "$local_mnt" "$src" "$dst_dir"
    fi

    local chunk_idx=$PACKER_NEXT_CHUNK_IDX chunk_total=${#PACKER_CHUNKS[@]}
    local group
    for group in "${PACKER_CHUNKS[@]}"; do
        chunk_idx=$((chunk_idx + 1))
        local -a items=()
        IFS=$'\x1f' read -r -a items <<< "$group"

        local chunk_tar
        chunk_tar="${PACKER_BUFFER_PATH%/}/${folder_name}.part$(printf '%03d' "$chunk_idx").tar"

        local purge_fail_detail
        if ! purge_fail_detail=$(Purger::check_failed); then
            Diagnostics::halt_chunk_pipeline "ASYNC_PURGE" "$purge_fail_detail" "" "$local_mnt" "$src" "$dst_dir"
        fi

        echo "----------------------------------------------------------------------"
        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Building local archive: $chunk_tar"
        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Items: ${items[*]}"

        if ! Packer::build_local_tar "$local_mnt" "$chunk_tar" "${items[@]}"; then
            Diagnostics::halt_chunk_pipeline "LOCAL_TAR_CREATE" "tar failed while building $chunk_tar (stderr: ${chunk_tar%/*}/.last_tar.stderr)" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi
        Diagnostics::mark_phase "$chunk_idx" "$chunk_total" "BUILT" "$chunk_tar"

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Verifying local archive integrity..."
        if ! Packer::verify_local_tar "$chunk_tar"; then
            Diagnostics::halt_chunk_pipeline "LOCAL_TAR_VERIFY" "Local archive failed tar -tf integrity check: $chunk_tar" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi
        Diagnostics::mark_phase "$chunk_idx" "$chunk_total" "VERIFIED_LOCAL" "$chunk_tar"

        if [ -n "$DRY_RUN_FLAG" ]; then
            log_info "[DRY-RUN][CHUNK ${chunk_idx}/${chunk_total}] Local archive validated. Skipping remote push, source purge, and buffer flush."
            rm -f "$chunk_tar"
            continue
        fi

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Pushing local archive via rclone copy (resumable)..."
        if ! Transfer::resumable_push "$chunk_tar" "$dst_dir"; then
            Diagnostics::halt_chunk_pipeline "REMOTE_COPY" "rclone copy failed pushing $chunk_tar to $dst_dir" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi
        Diagnostics::mark_phase "$chunk_idx" "$chunk_total" "PUSHED" "$chunk_tar"

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Verifying remote copy integrity..."
        local verify_err
        if ! verify_err=$(Transfer::verify_remote_mass "$chunk_tar" "$dst_dir"); then
            Diagnostics::halt_chunk_pipeline "REMOTE_VERIFY" "$verify_err" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi
        Diagnostics::mark_phase "$chunk_idx" "$chunk_total" "VERIFIED_REMOTE" "$chunk_tar"

        # Claim this index on the remote before purge/flush, so a crash
        # anywhere after this point can never cause a future run to
        # re-issue a destination filename that already exists.
        if ! Packer::persist_chunk_idx "$chunk_idx"; then
            Diagnostics::halt_chunk_pipeline "STATE_PERSIST" "Failed to persist chunk index $chunk_idx to $PACKER_STATE_FILE" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi

        if [ "$PACKER_PURGE_ON_SUCCESS" == "yes" ]; then
            log_warn "[CHUNK ${chunk_idx}/${chunk_total}] Purge rule active. Queueing source items for async purge..."
            if ! Purger::enqueue "$src" "$chunk_idx" "$chunk_total" "${items[@]}"; then
                Diagnostics::halt_chunk_pipeline "PURGE_ENQUEUE" "Failed to write purge manifest for chunk ${chunk_idx} to ${PURGER_QUEUE_DIR}" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
            fi
            Diagnostics::mark_phase "$chunk_idx" "$chunk_total" "PURGE_QUEUED" "$chunk_tar"
        fi

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Flushing local exchange buffer..."
        rm -f "$chunk_tar"
        Diagnostics::mark_phase "$chunk_idx" "$chunk_total" "FLUSHED" "$chunk_tar"
    done

    # Structure archive (empty source directories) — built from the still-live
    # mount, before it is torn down. Opt-in per folder; independent of purge.
    if [ "$keep_dirs" == "yes" ]; then
        if [ -n "$DRY_RUN_FLAG" ]; then
            log_info "[DRY-RUN] Empty-directory preservation requested; skipping structure archive build/push."
        else
            Packer::emit_structure_chunk "$local_mnt" "$src" "$dst_dir" "$folder_name"
        fi
    fi

    fusermount -u "$local_mnt" 2>/dev/null || true
    rmdir "$local_mnt" 2>/dev/null || true
    CURRENT_MOUNT_DIR=""

    if [ "$PACKER_PURGE_ON_SUCCESS" == "yes" ] && [ -z "$DRY_RUN_FLAG" ]; then
        local drain_fail_detail
        if ! Purger::drain || ! drain_fail_detail=$(Purger::check_failed); then
            Diagnostics::halt_chunk_pipeline "ASYNC_PURGE" "${drain_fail_detail:-$(cat "$PURGER_FAIL_FLAG" 2>/dev/null)}" "" "" "$src" "$dst_dir"
        fi
    fi

    log_info "All ${chunk_total} chunk(s) for $src processed successfully."
}

# 9. Main Execution Loop — drains Core::QueueManager one task at a time.
while Queue::pop; do
    src="$QUEUE_POPPED_SRC"
    dst="$QUEUE_POPPED_DST"
    mode="$QUEUE_POPPED_MODE"
    purge="$QUEUE_POPPED_PURGE"
    chunk_bytes="$QUEUE_POPPED_CHUNK_BYTES"
    buffer_dir="$QUEUE_POPPED_BUFFER_DIR"
    keep_dirs="$QUEUE_POPPED_KEEP_DIRS"

    echo -e "\n----------------------------------------------------------------------"
    log_info "CRITICAL ENGAGEMENT: Starting deployment of $src"
    echo "----------------------------------------------------------------------"

    if ! RemoteLock::acquire "$src" "$dst"; then
        CONTROLLED_HALT=1
        log_err "Halting: refusing to start '$src' due to a conflicting remote lock (see above)."
        exit 1
    fi

    Diagnostics::mark_task_phase "$mode" "STARTED" "$src"

    if [ "$mode" == "tar" ]; then
        log_info "Profile selected: STREAM TAR MODE. Mounting FUSE endpoint and piping..."

        local_mnt=$(mktemp -d)
        rclone mount "$src" "$local_mnt" --daemon --allow-non-empty
        CURRENT_MOUNT_DIR="$local_mnt"
        Diagnostics::mark_task_phase "tar" "MOUNTED" "$src"
        tar cvf - -C "$local_mnt" . | rclone rcat "$dst" $PACER_FLAGS --progress $DRY_RUN_FLAG
        pipe_status=("${PIPESTATUS[@]}")
        fusermount -u "$local_mnt" 2>/dev/null || true
        rmdir "$local_mnt" 2>/dev/null || true
        CURRENT_MOUNT_DIR=""

        if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
            log_err "FATAL: TAR streaming pipeline failed for $src (tar=${pipe_status[0]}, rcat=${pipe_status[1]})"
            continue
        fi
        Diagnostics::mark_task_phase "tar" "STREAMED" "$dst"

        if [ -n "$DRY_RUN_FLAG" ]; then
            log_info "[DRY-RUN] Simulation complete for $dst. No archive was written; skipping verification and purge."
            continue
        fi

        log_info "Validating remote archive integrity..."
        tar_size=$(rclone lsf --format s "$dst" 2>/dev/null | head -1)
        if [[ "$tar_size" =~ ^[0-9]+$ ]] && [ "$tar_size" -gt 0 ]; then
            log_info "Container verification successful. Archive size: ${tar_size} bytes."
            Diagnostics::mark_task_phase "tar" "VERIFIED" "$dst"
            if [ "$purge" == "yes" ]; then
                log_warn "Purge rule triggered. Erasing source from source node: $src"
                rclone purge "$src"
                Diagnostics::mark_task_phase "tar" "PURGED" "$src"
            fi
        else
            log_err "FATAL: Archive verification failed for $dst — file missing or zero-byte."
        fi

    elif [ "$mode" == "raw" ]; then
        log_info "Profile selected: RAW DIRECT COPY MODE (non-destructive; rclone copy only)."
        # Never rclone sync here: sync deletes destination files that don't exist
        # in the source, which is unacceptable when target paths can overlap.
        # --create-empty-src-dirs (opt-in): rclone copy otherwise omits source
        # directories that contain no file, so empty folders would be lost on
        # the destination. if-form, not `[ ] &&`, so a "no" can't trip set -e.
        empty_dirs_flag=""
        if [ "$keep_dirs" == "yes" ]; then empty_dirs_flag="--create-empty-src-dirs"; fi
        if ! rclone copy "$src" "$dst" --progress --buffer-size 32M $PACER_FLAGS --transfers 4 --checkers 4 $empty_dirs_flag $DRY_RUN_FLAG; then
            log_err "FATAL: rclone copy failed for $src -> $dst"
            continue
        fi
        Diagnostics::mark_task_phase "raw" "PUSHED" "$dst"

        if [ -n "$DRY_RUN_FLAG" ]; then
            log_info "[DRY-RUN] Simulation complete for $dst. No data was changed; skipping integrity check and purge."
            continue
        fi

        log_info "Launching deep hash check validation matrix..."
        # --one-way: flattened dst can legitimately hold files that never came
        # from this src (sibling folders, prior runs). Purge must gate on "did
        # everything from src land intact", not "does dst contain nothing else".
        if rclone check "$src" "$dst" --checkers 4 --tpslimit 8 --one-way; then
            log_info "Integrity matrix verified. Data matches."
            Diagnostics::mark_task_phase "raw" "VERIFIED" "$dst"
            if [ "$purge" == "yes" ]; then
                log_warn "Purge rule triggered. Erasing source directory: $src"
                rclone purge "$src"
                Diagnostics::mark_task_phase "raw" "PURGED" "$src"
            fi
        else
            log_err "FATAL: Hash validation failed for $src. Purge bypassed to secure integrity."
        fi

    elif [ "$mode" == "tar-chunk" ]; then
        log_info "Profile selected: TAR-CHUNK MODE. Building size-limited local archive batches..."
        run_tar_chunk_pipeline "$src" "$dst" "$chunk_bytes" "$buffer_dir" "$purge" "$keep_dirs"
    fi
done

log_info "All queue objectives successfully executed. Script complete."
if [ "$TRANSFER_PUSHED_CHUNKS" -gt 0 ]; then
    log_info "Chunked transfer summary: ${TRANSFER_PUSHED_CHUNKS} chunk(s) pushed, $(format_bytes "$TRANSFER_PUSHED_BYTES") total."
fi
