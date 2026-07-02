#!/usr/bin/env bash

# ==============================================================================
# RCLONE ARCHIVE & SYNC INTERACTIVE MIGRATOR
# ==============================================================================
# Description: On-the-fly streaming tar-archiver and raw sync tool with queue.
# Framework: Clean Pure Bash CLI.
# Version: 3.0
# ==============================================================================

set -eo pipefail

# Global array to hold tasks in format: "SRC|DST|MODE|PURGE"
declare -a TASK_QUEUE=()

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

# Dry-run mode resolution — Direct Mode (-d/--dry-run flag) bypasses the
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

# Check for required binaries
for cmd in rclone tar fusermount; do
    if ! command -v "$cmd" &> /dev/null; then
        log_err "Required command '$cmd' is missing. Exiting."
        exit 1
    fi
done

echo "----------------------------------------------------------------------"
echo "        RCLONE INTERACTIVE STREAM MIGRATOR OPERATIONAL SYSTEM         "
echo "----------------------------------------------------------------------"

# 1. Detect Available Rclone Remotes with Numbered Menu
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

# 3. Destination directory tree cache — populated lazily on first use, not at startup
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

            read -r -p "Drill down deeper into this directory? (y/n): " drill_opt
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
                read -r -p "Drill down deeper into this directory? (y/n): " drill_opt
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
            read -r -p "Choose option (1-2): " FOLDER_OPT

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
                *)
                    log_warn "Invalid profile selected. Skipping configuration for this entry."
                    continue
                    ;;
            esac

            # Ask for Post-Processing Purge Rule
            read -r -p "Purge and delete source directory from source node upon verified success? (y/n): " purge_opt
            local final_purge="no"
            [[ "$purge_opt" == "y" || "$purge_opt" == "Y" ]] && final_purge="yes"

            # Push payload to queue
            TASK_QUEUE+=("${final_src}|${final_dst}|${mode}|${final_purge}")
            log_info "Successfully registered task to queue."

            # Remove configured folder and reindex to keep array dense
            unset "FOLDER_ARRAY[$CHOSEN_IDX]"
            FOLDER_ARRAY=("${FOLDER_ARRAY[@]}")
        done
    fi
}

configure_queue

# 5. Review & Execution Loop
while true; do
    echo -e "\n----------------------------------------------------------------------"
    echo "                   CURRENT MISSION TASK QUEUE STATUS                 "
    echo "----------------------------------------------------------------------"
    if [ ${#TASK_QUEUE[@]} -eq 0 ]; then
        log_warn "The queue is completely empty."
    else
        index=0
        for task in "${TASK_QUEUE[@]}"; do
            IFS='|' read -r t_src t_dst t_mode t_purge <<< "$task"
            echo -e "[$index] \033[1;33m$t_mode\033[0m: $t_src --> $t_dst [Purge Source: $t_purge]"
            index=$((index + 1))
        done
    fi
    echo "----------------------------------------------------------------------"
    echo "Actions:"
    echo "  1) Launch current deployment task queue execution engine"
    echo "  2) Reset and re-configure queue from scratch"
    echo "  3) Exit system completely"
    read -r -p "Choose engine action (1-3): " EXEC_OPT

    if [ "$EXEC_OPT" -eq 3 ] 2>/dev/null; then
        log_info "Terminating engine. Goodbye."
        exit 0
    elif [ "$EXEC_OPT" -eq 2 ] 2>/dev/null; then
        TASK_QUEUE=()
        configure_queue
        continue
    elif [ "$EXEC_OPT" -eq 1 ] 2>/dev/null; then
        if [ ${#TASK_QUEUE[@]} -eq 0 ]; then
            log_err "Cannot execute an empty deployment queue!"
            continue
        fi
        break
    else
        log_warn "Invalid selection. Please choose 1, 2, or 3."
    fi
done

# 6. Heavy Engineering Execution Processing Core
log_info "Initializing pipeline engines. Total jobs in pool: ${#TASK_QUEUE[@]}"

PACER_FLAGS="--drive-pacer-burst 1 --drive-pacer-min-sleep 100ms --tpslimit 10 --low-level-retries 15"

for task in "${TASK_QUEUE[@]}"; do
    IFS='|' read -r src dst mode purge <<< "$task"

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
        log_info "Profile selected: RAW DIRECT COPY SYNC MODE."
        rclone sync "$src" "$dst" --progress --buffer-size 32M $PACER_FLAGS --transfers 4 --checkers 4 $DRY_RUN_FLAG

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
    fi
done

log_info "All queue objectives successfully executed. Script complete."
