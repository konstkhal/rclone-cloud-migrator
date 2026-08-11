#!/bin/bash
# Archives loose (non-chunked) top-level folders under cryo_chamber into
# TAR-CHUNK archives on gdrive:, matching the smart_migrator.sh TAR-CHUNK
# naming/verification conventions. ~/GoogleDrive is an on-demand rclone
# mount (--vfs-cache-mode full, 75G cache), NOT a full local mirror — for
# folders bigger than the cache (docu_trans_process, 259G) reading through
# it competes with the chunk uploads over the same rclone connection/cache
# and can stall for hours. SRC_ROOT (the mount) is used only for the cheap
# metadata scan; each chunk's actual file bytes are pulled directly from
# SRC_REMOTE via `rclone copy` into a throwaway staging dir before tar runs,
# bypassing the shared mount/cache entirely for the expensive part.
set -eo pipefail

SRC_ROOT="${HOME}/GoogleDrive/Staging/cryo_chamber"
SRC_REMOTE="gdrive:Staging/cryo_chamber"
DST_ROOT="gdrive:Staging/cryo_chamber"
BUFFER_DIR="${HOME}/.cryo_archive_buffer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/state"
LOG_DIR="${SCRIPT_DIR}/logs"
CHUNK_BYTES=$((5 * 1024 * 1024 * 1024))
PACER_FLAGS="--drive-pacer-burst 1 --drive-pacer-min-sleep 100ms --tpslimit 10 --low-level-retries 15"

mkdir -p "$BUFFER_DIR" "$STATE_DIR" "$LOG_DIR"

LOG_FILE="${LOG_DIR}/archive_cryo_$(date '+%Y%m%d_%H%M%S')_$$.log"
_log_persist() { echo "$1" >> "$LOG_FILE"; }
log_info() { echo -e "[\033[0;32mINFO\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [INFO] $1"; }
log_warn() { echo -e "[\033[0;33mWARN\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [WARN] $1"; }
log_err()  { echo -e "[\033[0;31mERROR\033[0m] $1" >&2; _log_persist "$(date '+%F %T') [ERROR] $1"; }

task_key() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }

archive_folder() {
    local folder="$1"
    local src_dir="${SRC_ROOT}/${folder}"
    local dst_dir="${DST_ROOT}/${folder}_chunks"
    local key state_file next_idx
    key=$(task_key "$folder")
    state_file="${STATE_DIR}/.archive_chunk_idx__${key}.state"
    next_idx=0
    if [ -f "$state_file" ]; then
        next_idx=$(cat "$state_file" 2>/dev/null || echo 0)
        [[ "$next_idx" =~ ^[0-9]+$ ]] || next_idx=0
    fi

    if [ "$next_idx" == "DONE" ]; then
        log_info "[$folder] already fully archived+purged in a prior run; skipping."
        return 0
    fi

    log_info "=== Archiving '$folder' -> $dst_dir (resume from chunk $next_idx) ==="

    if [ ! -d "$src_dir" ]; then
        log_warn "[$folder] source directory no longer exists (already purged?); marking done."
        printf 'DONE\n' > "$state_file"
        return 0
    fi

    local scan_file
    scan_file=$(mktemp)
    find "$src_dir" -type f -printf '%s\t%P\n' > "$scan_file"
    local total_files
    total_files=$(wc -l < "$scan_file")
    if [ "$total_files" -eq 0 ]; then
        log_warn "[$folder] no files found (empty dir); purging empty shell and marking done."
        rm -f "$scan_file"
        rclone purge "${DST_ROOT}/${folder}" 2>/dev/null || true
        printf 'DONE\n' > "$state_file"
        return 0
    fi

    local -a chunks=() group=()
    local group_bytes=0 size relpath
    while IFS=$'\t' read -r size relpath; do
        [ -z "$relpath" ] && continue
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        if [ ${#group[@]} -gt 0 ] && [ $((group_bytes + size)) -gt "$CHUNK_BYTES" ]; then
            chunks+=("$(IFS=$'\x1f'; echo "${group[*]}")")
            group=(); group_bytes=0
        fi
        group+=("$relpath")
        group_bytes=$((group_bytes + size))
    done < "$scan_file"
    [ ${#group[@]} -gt 0 ] && chunks+=("$(IFS=$'\x1f'; echo "${group[*]}")")
    rm -f "$scan_file"

    local chunk_total=${#chunks[@]}
    log_info "[$folder] $total_files file(s) -> $chunk_total chunk(s)."

    local idx i
    local -a items
    for (( i = next_idx; i < chunk_total; i++ )); do
        idx=$((i + 1))
        IFS=$'\x1f' read -r -a items <<< "${chunks[$i]}"
        local chunk_tar="${BUFFER_DIR}/${folder}.part$(printf '%03d' "$idx").tar"

        local stage_dir manifest_file
        stage_dir="${BUFFER_DIR}/.stage_${key}_${idx}"
        manifest_file="${stage_dir}.filelist"
        rm -rf "$stage_dir"
        mkdir -p "$stage_dir"
        printf '%s\n' "${items[@]}" > "$manifest_file"

        log_info "[$folder][CHUNK $idx/$chunk_total] Downloading (${#items[@]} files) directly from $SRC_REMOTE/$folder (bypassing the shared VFS-cache mount)..."
        if ! timeout 3600 rclone copy --files-from-raw "$manifest_file" "${SRC_REMOTE}/${folder}" "$stage_dir" $PACER_FLAGS; then
            log_err "[$folder][CHUNK $idx/$chunk_total] rclone download failed or timed out after 3600s. Halting this folder (resumable)."
            rm -rf "$stage_dir" "$manifest_file"
            return 1
        fi

        log_info "[$folder][CHUNK $idx/$chunk_total] Building (${#items[@]} files)..."
        if ! timeout 1800 tar cf "$chunk_tar" -C "$stage_dir" "${items[@]}"; then
            log_err "[$folder][CHUNK $idx/$chunk_total] tar build failed or timed out after 1800s. Halting this folder (resumable)."
            rm -f "$chunk_tar"
            rm -rf "$stage_dir" "$manifest_file"
            return 1
        fi
        rm -rf "$stage_dir" "$manifest_file"
        if ! tar -tf "$chunk_tar" > /dev/null; then
            log_err "[$folder][CHUNK $idx/$chunk_total] local tar verify failed. Halting."
            return 1
        fi

        log_info "[$folder][CHUNK $idx/$chunk_total] Pushing to $dst_dir..."
        # timeout guards a stuck-but-server-side-succeeded push (observed: an
        # ESTABLISHED-but-idle connection hung 8h with the file already landed
        # remotely) — don't trust the exit code alone. Always fall through to
        # the remote-size check below and treat a matching size as success
        # regardless of whether the copy command itself reported failure,
        # so a timeout-kill on an already-finished upload can't cause a
        # duplicate re-push on the next resume.
        timeout 3600 rclone copy "$chunk_tar" "${dst_dir}/" $PACER_FLAGS || true

        local local_bytes remote_bytes
        local_bytes=$(stat -c%s "$chunk_tar")
        remote_bytes=$(rclone lsf --format s "${dst_dir}/$(basename "$chunk_tar")" 2>/dev/null | head -1)
        if ! [[ "$remote_bytes" =~ ^[0-9]+$ ]] || [ "$remote_bytes" -ne "$local_bytes" ]; then
            log_err "[$folder][CHUNK $idx/$chunk_total] push failed or timed out, and remote size doesn't match (local=$local_bytes remote=$remote_bytes). Halting."
            return 1
        fi
        log_info "[$folder][CHUNK $idx/$chunk_total] Verified OK (${remote_bytes} bytes)."

        printf '%s\n' "$idx" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
        rm -f "$chunk_tar"
    done

    log_info "[$folder] All $chunk_total chunk(s) pushed+verified. Purging loose original from gdrive: (trash-safe)..."
    if ! rclone purge "${DST_ROOT}/${folder}"; then
        log_err "[$folder] purge failed — chunks are safe, original left intact for manual review."
        return 1
    fi
    printf 'DONE\n' > "$state_file"
    log_info "[$folder] DONE."
}

log_info "Discovering loose (non-_chunks) folders under $SRC_ROOT..."
# Alphabetical order, with known-large outliers explicitly pinned last —
# a per-folder size pre-scan over Drive Desktop's virtual FS is too slow
# to be worth it just to establish an ordering (see the du-vs-rclone-size
# discrepancy already found on REF Передача документов_chunks).
declare -a LARGE_LAST=("docu_trans_process")
mapfile -t ALL_FOLDERS < <(cd "$SRC_ROOT" && find . -maxdepth 1 -mindepth 1 -type d ! -iname "*_chunks" -printf '%P\n' | sort)

declare -a FOLDERS=()
for f in "${ALL_FOLDERS[@]}"; do
    skip=0
    for large in "${LARGE_LAST[@]}"; do
        [ "$f" == "$large" ] && skip=1 && break
    done
    [ "$skip" -eq 0 ] && FOLDERS+=("$f")
done
for large in "${LARGE_LAST[@]}"; do
    for f in "${ALL_FOLDERS[@]}"; do
        [ "$f" == "$large" ] && FOLDERS+=("$large") && break
    done
done

log_info "Queued ${#FOLDERS[@]} folder(s) (alphabetical, large outliers last)."

fail=0
for f in "${FOLDERS[@]}"; do
    if ! archive_folder "$f"; then
        log_err "Stopped at folder '$f'. Fix the issue and rerun this script — already-verified chunks and completed folders are skipped automatically."
        fail=1
        break
    fi
done

if [ "$fail" -eq 0 ]; then
    log_info "All queued folders archived successfully."
fi
exit "$fail"
