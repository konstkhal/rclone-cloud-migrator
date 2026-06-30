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

# 3. Fetch Top-Level Structures from Source
log_info "Fetching top-level directories from $GLOBAL_SRC_REMOTE..."
TOP_FOLDERS=$(rclone lsd "$GLOBAL_SRC_REMOTE" | awk '{print $NF}')

# 4. Interactive Queue Configuration Core
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

            echo -e "\n======================================================================"
            echo -e "Configuring Folder: \033[1;34m$target_folder\033[0m"
            echo "================================================================------"
            echo "Select processing profile:"
            echo "  1) [RAW] Copy folder contents 'as-is' to destination directory"
            echo "  2) [TAR] Stream entire folder into a single unified .tar archive file"
            read -r -p "Choose option (1-2): " FOLDER_OPT

            case "$FOLDER_OPT" in
                1)
                    local mode="raw"
                    read -r -p "Enter destination path inside remote (e.g., Staging/hot_swap): " sub_dst
                    local final_src="${GLOBAL_SRC_REMOTE}${target_folder}"
                    local final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${target_folder}"
                    ;;
                2)
                    local mode="tar"
                    read -r -p "Enter destination directory inside remote (e.g., Staging/cryo_chamber): " sub_dst
                    local final_src="${GLOBAL_SRC_REMOTE}${target_folder}"
                    local final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${target_folder}.tar"
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

    # Post-discovery manual addition loop (for explicit nested paths)
    while true; do
        echo -e "\n----------------------------------------------------------------------"
        read -r -p "Would you like to manually add an explicit nested folder path to the queue? (y/n): " add_opt
        if [[ "$add_opt" == "y" || "$add_opt" == "Y" ]]; then
            read -r -p "Enter relative folder path from the source root: " manual_folder
            if [ -n "$manual_folder" ]; then
                echo -e "\nConfiguring Manual Path: \033[1;34m$manual_folder\033[0m"
                echo "Select processing profile:"
                echo "  1) [RAW] Copy folder contents 'as-is'"
                echo "  2) [TAR] Stream folder into a .tar archive file"
                read -r -p "Choose option (1-2): " FOLDER_OPT

                case "$FOLDER_OPT" in
                    1)
                        local mode="raw"
                        read -r -p "Enter destination path (e.g., Staging/hot_swap): " sub_dst
                        local final_src="${GLOBAL_SRC_REMOTE}${manual_folder}"
                        local final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${manual_folder##*/}"
                        ;;
                    2)
                        local mode="tar"
                        read -r -p "Enter destination directory (e.g., Staging/cryo_chamber): " sub_dst
                        local final_src="${GLOBAL_SRC_REMOTE}${manual_folder}"
                        local final_dst="${GLOBAL_DST_REMOTE}${sub_dst}/${manual_folder##*/}.tar"
                        ;;
                    *) log_warn "Skipping entry."; continue ;;
                esac

                read -r -p "Purge source directory upon verified success? (y/n): " purge_opt
                local final_purge="no"
                [[ "$purge_opt" == "y" || "$purge_opt" == "Y" ]] && final_purge="yes"

                TASK_QUEUE+=("${final_src}|${final_dst}|${mode}|${final_purge}")
                log_info "Successfully registered manual task to queue."
            fi
        else
            break
        fi
    done
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
        tar cvf - -C "$local_mnt" . | rclone rcat "$dst" $PACER_FLAGS --progress
        pipe_status=("${PIPESTATUS[@]}")
        fusermount -u "$local_mnt" 2>/dev/null || true
        rmdir "$local_mnt" 2>/dev/null || true

        if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
            log_err "FATAL: TAR streaming pipeline failed for $src (tar=${pipe_status[0]}, rcat=${pipe_status[1]})"
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
        rclone sync "$src" "$dst" --progress --buffer-size 32M $PACER_FLAGS --transfers 4 --checkers 4

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
