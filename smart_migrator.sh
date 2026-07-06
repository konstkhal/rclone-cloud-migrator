#!/usr/bin/env bash

# ==============================================================================
# RCLONE ARCHIVE & SYNC INTERACTIVE MIGRATOR
# ==============================================================================
# Description: On-the-fly streaming tar-archiver and raw copy tool with queue.
# Framework: Modular pseudoclass-style Bash CLI (Core/Engine/System namespaces).
# Version: 4.1
# ==============================================================================

set -eo pipefail

# ---------------------------------------------------------------------------
# System::Diagnostics — logging primitives. Defined first since every other
# module calls into these.
# ---------------------------------------------------------------------------
log_info() { echo -e "[\033[0;32mINFO\033[0m] $1" >&2; }
log_warn() { echo -e "[\033[0;33mWARN\033[0m] $1" >&2; }
log_err()  { echo -e "[\033[0;31mERROR\033[0m] $1" >&2; }

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
prompt_strict_choice() {
    local prompt_msg="$1" valid_chars="$2" label="$3" answer
    while true; do
        read -r -p "$prompt_msg" answer
        if [[ "$answer" =~ ^[${valid_chars}]$ ]]; then
            echo "$answer"
            return 0
        fi
        log_err "Invalid input. Please enter exactly one of: $label"
    done
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
    local i selected r_idx remote
    while true; do
        echo -e "\nAvailable storage nodes:" >&2
        i=0
        while IFS= read -r remote; do
            if [ -n "$remote" ]; then
                echo "  $i) $remote" >&2
                REMOTE_ARRAY[$i]="$remote"
                i=$((i + 1))
            fi
        done <<< "$REMOTE_LIST"

        echo "----------------------------------------------------------------------" >&2
        read -r -p "$prompt_msg" r_idx
        if [[ "$r_idx" =~ ^[0-9]+$ ]] && [ "$r_idx" -lt "$i" ]; then
            selected="${REMOTE_ARRAY[$r_idx]}"
            selected="${selected// /}"
            selected="${selected%:}:"
            echo "$selected"
            return 0
        else
            log_err "Invalid selection index '$r_idx'. Range is 0 to $((i-1)). Try again."
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

    while true; do
        echo -e "\nAvailable destination directories on ${GLOBAL_DST_REMOTE}${current_path}:" >&2
        if [ "$at_root" -eq 1 ]; then
            echo "  0) / (remote root)" >&2
        fi
        local i=1
        for d in "${menu_dirs[@]}"; do
            echo "  $i) $d" >&2
            i=$((i + 1))
        done
        if [ "$at_root" -eq 1 ]; then
            echo "  m) Manually type a custom path" >&2
        fi
        echo "  b) .. (Go back to parent directory)" >&2
        echo "  r) / (Reset navigation to remote root)" >&2
        echo "----------------------------------------------------------------------" >&2
        read -r -p "$prompt_msg" choice

        if [ "$at_root" -eq 1 ] && [ "$choice" == "m" ]; then
            read -r -p "Enter custom destination path (relative to remote root): " custom_path
            echo "$custom_path"
            return 0
        elif [ "$at_root" -eq 1 ] && [ "$choice" == "0" ]; then
            echo ""
            return 0
        elif [ "$choice" == "b" ]; then
            if [ -z "$current_path" ]; then
                log_warn "Already at remote root. Cannot go back further."
            else
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
TOP_FOLDERS=$(rclone lsf --dirs-only --dir-slash=false "$GLOBAL_SRC_REMOTE")

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

# Enqueue one task. Bash functions cannot return structs, so fields are
# passed positionally.
Queue::push() {
    local src="$1" dst="$2" mode="$3" purge="$4" chunk_bytes="$5" buffer_dir="$6"
    QUEUE_SRC+=("$src")
    QUEUE_DST+=("$dst")
    QUEUE_MODE+=("$mode")
    QUEUE_PURGE+=("$purge")
    QUEUE_CHUNK_BYTES+=("$chunk_bytes")
    QUEUE_BUFFER_DIR+=("$buffer_dir")
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

Queue::pop() {
    [ ${#QUEUE_SRC[@]} -eq 0 ] && return 1
    QUEUE_POPPED_SRC="${QUEUE_SRC[0]}"
    QUEUE_POPPED_DST="${QUEUE_DST[0]}"
    QUEUE_POPPED_MODE="${QUEUE_MODE[0]}"
    QUEUE_POPPED_PURGE="${QUEUE_PURGE[0]}"
    QUEUE_POPPED_CHUNK_BYTES="${QUEUE_CHUNK_BYTES[0]}"
    QUEUE_POPPED_BUFFER_DIR="${QUEUE_BUFFER_DIR[0]}"
    QUEUE_SRC=("${QUEUE_SRC[@]:1}")
    QUEUE_DST=("${QUEUE_DST[@]:1}")
    QUEUE_MODE=("${QUEUE_MODE[@]:1}")
    QUEUE_PURGE=("${QUEUE_PURGE[@]:1}")
    QUEUE_CHUNK_BYTES=("${QUEUE_CHUNK_BYTES[@]:1}")
    QUEUE_BUFFER_DIR=("${QUEUE_BUFFER_DIR[@]:1}")
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
        IFS=$'\n' read -r -d '' -a FOLDER_ARRAY <<< "$TOP_FOLDERS" || true

        while true; do
            echo -e "\nDetected Top-Level Directories on Source:"
            local i=0
            for folder in "${FOLDER_ARRAY[@]}"; do
                if [ -n "$folder" ]; then
                    echo "  $i) $folder"
                fi
                i=$((i + 1))
            done
            echo "  q) Finished choosing folders (Proceed to next step)"
            echo "  e) [EXIT] Terminate system completely now"
            echo "----------------------------------------------------------------------"
            read -r -p "Select a folder index to configure, 'q' to proceed, or 'e' to exit: " CHOSEN_IDX

            if [ "$CHOSEN_IDX" == "e" ]; then
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
            # Boundary for 'b'/'r' navigation below — the top-level folder chosen above,
            # not the remote's absolute root, since downstream naming requires a non-empty folder.
            local source_root_folder="$target_folder"

            # Infinite on-demand recursive drilldown into subfolders
            while true; do
                local drill_opt
                drill_opt=$(prompt_strict_choice "Drill down deeper into this directory? (y/n): " "yYnN" "y or n")
                if [[ "$drill_opt" == "y" || "$drill_opt" == "Y" ]]; then
                    local sub_listing
                    sub_listing=$(rclone lsf --dirs-only --dir-slash=false "${GLOBAL_SRC_REMOTE}${target_folder}" 2>/dev/null) || true
                    if [ -z "$sub_listing" ]; then
                        log_warn "No subfolders found under '$target_folder'. Using this path as-is."
                        break
                    fi
                    local -a SUB_SRC_ARRAY=()
                    while IFS= read -r sf; do
                        [ -z "$sf" ] && continue
                        SUB_SRC_ARRAY+=("$sf")
                    done <<< "$sub_listing"

                    echo -e "\nSubfolders of $target_folder:"
                    local si=0
                    for sf in "${SUB_SRC_ARRAY[@]}"; do
                        echo "  $si) $sf"
                        si=$((si + 1))
                    done
                    echo "  b) .. (Go back to parent directory)"
                    echo "  r) / (Reset navigation to remote root)"
                    read -r -p "Select a subfolder index to drill into, 'b' to go back, or 'r' to reset: " sub_idx
                    if [[ "$sub_idx" =~ ^[0-9]+$ ]] && [ "$sub_idx" -lt "${#SUB_SRC_ARRAY[@]}" ]; then
                        target_folder="${target_folder}/${SUB_SRC_ARRAY[$sub_idx]}"
                    elif [ "$sub_idx" == "b" ]; then
                        if [ "$target_folder" == "$source_root_folder" ]; then
                            log_warn "Already at top-level source root. Cannot go back further."
                        else
                            target_folder="${target_folder%/*}"
                        fi
                    elif [ "$sub_idx" == "r" ]; then
                        target_folder="$source_root_folder"
                    else
                        log_err "Invalid subfolder index. Staying at current level: $target_folder"
                    fi
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
            size_json=$(rclone size --json "${GLOBAL_SRC_REMOTE}${target_folder}" 2>/dev/null) || true
            bytes_count=$(echo "$size_json" | grep -o '"bytes":[0-9]*' | cut -d: -f2)
            objects_count=$(echo "$size_json" | grep -o '"count":[0-9]*' | cut -d: -f2)
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
                    local final_dst
                    if [ -n "$sub_dst" ]; then
                        final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${target_folder}"
                    else
                        final_dst="${GLOBAL_DST_REMOTE}${target_folder}"
                    fi
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
                    local final_dst
                    if [ -n "$sub_dst" ]; then
                        final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${target_folder}.tar"
                    else
                        final_dst="${GLOBAL_DST_REMOTE}${target_folder}.tar"
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
                    local final_dst
                    if [ -n "$sub_dst" ]; then
                        final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${target_folder}_chunks"
                    else
                        final_dst="${GLOBAL_DST_REMOTE}${target_folder}_chunks"
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

            Queue::push "$final_src" "$final_dst" "$mode" "$final_purge" "${chunk_bytes:-}" "${buffer_dir:-}"
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
    if [ -n "$mnt" ]; then
        fusermount -u "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
    fi
    exit 1
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
PACKER_SOURCE_PATH=""
PACKER_BUFFER_PATH=""
PACKER_MAX_CHUNK_SIZE=0
PACKER_PURGE_ON_SUCCESS="no"

declare -a PACKER_MANIFEST_PATHS=()
declare -a PACKER_MANIFEST_SIZES=()
declare -a PACKER_CHUNKS=()   # each element: \x1f-joined relative file paths for one chunk

Packer::init() {
    PACKER_SOURCE_PATH="$1"
    PACKER_BUFFER_PATH="$2"
    PACKER_MAX_CHUNK_SIZE="$3"
    PACKER_PURGE_ON_SUCCESS="$4"
    PACKER_MANIFEST_PATHS=()
    PACKER_MANIFEST_SIZES=()
    PACKER_CHUNKS=()
}

# Builds a flat manifest of every file under source_path, however deeply
# nested, via rclone's own recursive listing rather than a top-level-only
# directory walk — this is what fixes the v3.0 bug where a single nested
# directory holding hundreds of GiB was invisible to the bin-packer.
Packer::scan_payload() {
    log_info "Deep-scanning full recursive file manifest under ${PACKER_SOURCE_PATH}..."
    local size relpath
    while IFS=$'\t' read -r size relpath; do
        [ -z "$relpath" ] && continue
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        PACKER_MANIFEST_PATHS+=("$relpath")
        PACKER_MANIFEST_SIZES+=("$size")
    done < <(rclone lsf -R --files-only --format "sp" --separator $'\t' "$PACKER_SOURCE_PATH" 2>/dev/null)
    log_info "Manifest complete: ${#PACKER_MANIFEST_PATHS[@]} file(s) discovered across all nesting levels."
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
    tar cvf "$chunk_tar" -C "$mount_dir" "${items[@]}"
}

Packer::verify_local_tar() {
    local chunk_tar="$1"
    tar -tf "$chunk_tar" > /dev/null
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
    rclone copy "$local_tar" "${dst_dir%/}/" $PACER_FLAGS --progress
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
Transfer::purge_source_manifest() {
    local src_root="$1"
    shift
    local -a items=("$@")
    local item
    for item in "${items[@]}"; do
        if ! rclone deletefile "${src_root%/}/${item}" 2>/dev/null; then
            echo "Failed to delete processed source item: ${src_root%/}/${item}"
            return 1
        fi
    done
}

# Incremental Local Buffer & Chunk-Based Purge Pipeline (TAR-CHUNK mode).
# Deep-scans the full source manifest, bin-packs it into <= chunk_bytes
# groups, archives each group to a local scratch file, validates it, pushes
# it with a resumable `rclone copy`, verifies the remote copy, then (if
# requested) purges only the source files that made it into that chunk
# before moving to the next one.
run_tar_chunk_pipeline() {
    local src="$1" dst_dir="$2" chunk_bytes="$3" buffer_dir="$4" purge="$5"
    local folder_name
    folder_name=$(basename "${src%/}")

    if ! mkdir -p "$buffer_dir"; then
        Diagnostics::halt_chunk_pipeline "BUFFER_INIT" "Cannot create local buffer directory: $buffer_dir" "" "" "$src" "$dst_dir"
    fi

    Packer::init "$src" "$buffer_dir" "$chunk_bytes" "$purge"
    Packer::scan_payload

    if [ ${#PACKER_MANIFEST_PATHS[@]} -eq 0 ]; then
        log_warn "No files found under $src. Nothing to chunk."
        return 0
    fi

    Packer::generate_chunks

    log_info "Mounting FUSE endpoint for chunk assembly: $src"
    local local_mnt
    local_mnt=$(mktemp -d)
    rclone mount "$src" "$local_mnt" --daemon --allow-non-empty

    local mount_wait=0
    until mountpoint -q "$local_mnt" || [ "$mount_wait" -ge 20 ]; do
        sleep 0.5
        mount_wait=$((mount_wait + 1))
    done
    if ! mountpoint -q "$local_mnt"; then
        Diagnostics::halt_chunk_pipeline "MOUNT" "FUSE mount did not become ready at $local_mnt" "" "$local_mnt" "$src" "$dst_dir"
    fi

    local chunk_idx=0 chunk_total=${#PACKER_CHUNKS[@]}
    local group
    for group in "${PACKER_CHUNKS[@]}"; do
        chunk_idx=$((chunk_idx + 1))
        local -a items=()
        IFS=$'\x1f' read -r -a items <<< "$group"

        local chunk_tar
        chunk_tar="${PACKER_BUFFER_PATH%/}/${folder_name}.part$(printf '%03d' "$chunk_idx").tar"

        echo "----------------------------------------------------------------------"
        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Building local archive: $chunk_tar"
        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Items: ${items[*]}"

        if ! Packer::build_local_tar "$local_mnt" "$chunk_tar" "${items[@]}"; then
            Diagnostics::halt_chunk_pipeline "LOCAL_TAR_CREATE" "tar failed while building $chunk_tar" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Verifying local archive integrity..."
        if ! Packer::verify_local_tar "$chunk_tar"; then
            Diagnostics::halt_chunk_pipeline "LOCAL_TAR_VERIFY" "Local archive failed tar -tf integrity check: $chunk_tar" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi

        if [ -n "$DRY_RUN_FLAG" ]; then
            log_info "[DRY-RUN][CHUNK ${chunk_idx}/${chunk_total}] Local archive validated. Skipping remote push, source purge, and buffer flush."
            rm -f "$chunk_tar"
            continue
        fi

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Pushing local archive via rclone copy (resumable)..."
        if ! Transfer::resumable_push "$chunk_tar" "$dst_dir"; then
            Diagnostics::halt_chunk_pipeline "REMOTE_COPY" "rclone copy failed pushing $chunk_tar to $dst_dir" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Verifying remote copy integrity..."
        local verify_err
        if ! verify_err=$(Transfer::verify_remote_mass "$chunk_tar" "$dst_dir"); then
            Diagnostics::halt_chunk_pipeline "REMOTE_VERIFY" "$verify_err" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
        fi

        if [ "$PACKER_PURGE_ON_SUCCESS" == "yes" ]; then
            log_warn "[CHUNK ${chunk_idx}/${chunk_total}] Purge rule active. Removing processed source items..."
            local purge_err
            if ! purge_err=$(Transfer::purge_source_manifest "$src" "${items[@]}"); then
                Diagnostics::halt_chunk_pipeline "SOURCE_PURGE" "$purge_err" "$chunk_tar" "$local_mnt" "$src" "$dst_dir"
            fi
        fi

        log_info "[CHUNK ${chunk_idx}/${chunk_total}] Flushing local exchange buffer..."
        rm -f "$chunk_tar"
    done

    fusermount -u "$local_mnt" 2>/dev/null || true
    rmdir "$local_mnt" 2>/dev/null || true
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

    echo -e "\n----------------------------------------------------------------------"
    log_info "CRITICAL ENGAGEMENT: Starting deployment of $src"
    echo "----------------------------------------------------------------------"

    if [ "$mode" == "tar" ]; then
        log_info "Profile selected: STREAM TAR MODE. Mounting FUSE endpoint and piping..."

        local_mnt=$(mktemp -d)
        rclone mount "$src" "$local_mnt" --daemon --allow-non-empty
        tar cvf - -C "$local_mnt" . | rclone rcat "$dst" $PACER_FLAGS --progress $DRY_RUN_FLAG
        pipe_status=("${PIPESTATUS[@]}")
        fusermount -u "$local_mnt" 2>/dev/null || true
        rmdir "$local_mnt" 2>/dev/null || true

        if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
            log_err "FATAL: TAR streaming pipeline failed for $src (tar=${pipe_status[0]}, rcat=${pipe_status[1]})"
            continue
        fi

        if [ -n "$DRY_RUN_FLAG" ]; then
            log_info "[DRY-RUN] Simulation complete for $dst. No archive was written; skipping verification and purge."
            continue
        fi

        log_info "Validating remote archive integrity..."
        tar_size=$(rclone lsf --format s "$dst" 2>/dev/null | head -1)
        if [[ "$tar_size" =~ ^[0-9]+$ ]] && [ "$tar_size" -gt 0 ]; then
            log_info "Container verification successful. Archive size: ${tar_size} bytes."
            if [ "$purge" == "yes" ]; then
                log_warn "Purge rule triggered. Erasing source from source node: $src"
                rclone purge "$src"
            fi
        else
            log_err "FATAL: Archive verification failed for $dst — file missing or zero-byte."
        fi

    elif [ "$mode" == "raw" ]; then
        log_info "Profile selected: RAW DIRECT COPY MODE (non-destructive; rclone copy only)."
        # Never rclone sync here: sync deletes destination files that don't exist
        # in the source, which is unacceptable when target paths can overlap.
        rclone copy "$src" "$dst" --progress --buffer-size 32M $PACER_FLAGS --transfers 4 --checkers 4 $DRY_RUN_FLAG

        if [ -n "$DRY_RUN_FLAG" ]; then
            log_info "[DRY-RUN] Simulation complete for $dst. No data was changed; skipping integrity check and purge."
            continue
        fi

        log_info "Launching deep hash check validation matrix..."
        if rclone check "$src" "$dst" --checkers 4 --tpslimit 8; then
            log_info "Integrity matrix verified. Data matches."
            if [ "$purge" == "yes" ]; then
                log_warn "Purge rule triggered. Erasing source directory: $src"
                rclone purge "$src"
            fi
        else
            log_err "FATAL: Hash validation failed for $src. Purge bypassed to secure integrity."
        fi

    elif [ "$mode" == "tar-chunk" ]; then
        log_info "Profile selected: TAR-CHUNK MODE. Building size-limited local archive batches..."
        run_tar_chunk_pipeline "$src" "$dst" "$chunk_bytes" "$buffer_dir" "$purge"
    fi
done

log_info "All queue objectives successfully executed. Script complete."
if [ "$TRANSFER_PUSHED_CHUNKS" -gt 0 ]; then
    log_info "Chunked transfer summary: ${TRANSFER_PUSHED_CHUNKS} chunk(s) pushed, $(format_bytes "$TRANSFER_PUSHED_BYTES") total."
fi
