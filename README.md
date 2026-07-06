# rclone-cloud-migrator

An interactive, queue-based multi-cloud migration tool built on top of [rclone](https://rclone.org/). Designed for high-volume data movement between any two rclone-compatible storage backends with real-time streaming, cryptographic integrity validation, and optional post-transfer purge.

**Author & Maintainer:** Konstantin Haletckii

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│           Interactive Configuration Phase            │
│  Select source remote → select destination remote →  │
│  browse top-level dirs → build ordered task queue    │
└───────────────────────────┬──────────────────────────┘
                            │
          ┌──────────────────▼─────────────────┐
          │         Core::QueueManager         │
          │  [ src | dst | mode | purge |      │
          │    chunk_bytes | buffer_dir ] ...  │
          └──────────────────┬─────────────────┘
                             │
          ┌──────────────────▼────────────────────────────┐
          │                 Execution Core                │
          │                                               │
          │  TAR mode:       rclone mount (FUSE) →        │
          │                  tar cf - → rclone rcat       │
          │                  (streaming pipe)             │
          │                                               │
          │  RAW mode:       rclone copy → rclone check   │
          │                  (cryptographic hash          │
          │                   validation)                 │
          │                                               │
          │  TAR-CHUNK mode: recursive scan → bin-pack →  │
          │                  local tar → rclone copy →    │
          │                  remote verify → chunk purge  │
          │                  (Engine::ChunkPacker /       │
          │                   Engine::CloudTransfer)      │
          │                                               │
          │  Post-transfer:  optional rclone purge src    │
          └───────────────────────────────────────────────┘
```

The script is a single self-contained Bash file with no external dependencies beyond `rclone`, `tar`, and `fusermount`.

---

## Features

### Real-Time On-the-Fly Streaming TAR Mode
- Mounts the source path via `rclone mount` (FUSE) into a temporary directory.
- Pipes `tar cf -` directly into `rclone rcat` — no intermediate disk writes.
- Produces a single `.tar` archive at the destination without buffering the full archive locally.
- Post-stream size verification confirms the archive is non-zero before any purge action.

### RAW Copy Mode with Cryptographic Hash Verification
- Transfers data with `rclone copy` (multi-transfer, buffered, non-destructive — never deletes anything at the destination).
- Follows every transfer with `rclone check` to compare source and destination using backend-native checksums (MD5, SHA-1, or equivalent depending on the remote).
- Purge is gated: the source is only deleted if the hash check exits cleanly.

### TAR-CHUNK Mode — Size-Bounded Local Archives with Incremental Purge
- Recursively scans the full source tree (`rclone lsf -R`), however deeply nested, so no subdirectory is invisible to the packer.
- Greedy bin-packs the file manifest into archives no larger than a configurable `chunk_bytes` limit (e.g. `50G`, `500M`, or a raw byte count).
- Per chunk: build a local tar from a FUSE-mounted view of the source → verify local archive integrity → push with `rclone copy` → verify the remote copy's size → purge only the source files that made it into that chunk → flush the local buffer.
- Fails safe: any error at any stage halts the entire pipeline immediately (`Diagnostics::halt_chunk_pipeline`), leaving the local buffer, remaining source data, and destination untouched for manual inspection — it never silently skips ahead.
- Dry-run aware: chunks are still built and locally verified for a realistic preview, but remote push, verification, purge, and buffer flush are skipped.
- Useful for very large or deeply nested folders where a single unified TAR archive (see TAR mode above) would be impractical to build, push, or recover from if interrupted.

### Interactive Queue Builder
- Numbered menus for remote selection and destination directory browsing.
- Supports both auto-discovered top-level folders and manually typed nested paths.
- Each queue entry carries its own mode (`raw` / `tar` / `tar-chunk`) and purge flag (`yes` / `no`), plus chunk size and local buffer path for `tar-chunk` entries.
- Queue is reviewable and resettable before execution begins.

### Post-Transfer Safe Purge
- Configurable per task at queue-build time.
- TAR mode: purge fires only after size validation confirms a non-zero remote archive.
- RAW mode: purge fires only after `rclone check` passes with zero errors.
- TAR-CHUNK mode: purge is incremental — only the source files inside a chunk are deleted, and only after that chunk's remote copy is verified.
- Source is never touched if any verification step fails.

### Dry-Run Simulation Mode
- Runs the entire queue with rclone's `--dry-run` flag so no data is copied, archived, moved, or deleted on any remote.
- **Interactive prompt (default):** on every run without `-d`/`--dry-run`, the script asks `Would you like to perform a safe dry-run (simulation) first? [Y/n]` before touching any remote. Pressing Enter or `y` starts a simulation; `n` confirms LIVE mode.
- **Direct flag mode:** pass `-d` or `--dry-run` on the command line to skip the prompt and start directly in simulation mode.
- Verification and purge steps are skipped in dry-run — TAR mode logs that no archive was written, RAW mode logs that no data was changed, and the source is never purged.

---

## Requirements

| Dependency   | Purpose                                  |
|--------------|------------------------------------------|
| `rclone`     | All remote I/O, mounting, and checking   |
| `tar`        | Streaming archive creation (TAR mode)    |
| `fusermount` | FUSE mount teardown (TAR mode)           |

Install rclone: https://rclone.org/install/

---

## Configuration

All remotes are configured through rclone's standard configuration file. Run the interactive configurator before first use:

```bash
rclone config
```

Verify your remotes are visible:

```bash
rclone listremotes
```

The script reads `rclone listremotes` at startup and presents them as a numbered menu — no script-level configuration required.

---

## Usage

```bash
bash smart_migrator.sh
```

By default the script asks whether to run a safe dry-run simulation first. To skip that prompt and go straight into simulation mode, pass `-d` or `--dry-run`:

```bash
bash smart_migrator.sh --dry-run
```

In dry-run mode every `rclone` operation runs with `--dry-run`, so no data is copied, archived, or deleted on any remote — use it to preview the task queue's effects safely.

### Session walkthrough

1. **Select source remote** — choose from the numbered list of configured rclone remotes.
2. **Select destination remote** — same list, pick the target backend.
3. **Browse destination** — top-level directories on the destination are fetched and presented as a menu. Choose `0` for root or `m` to type a custom path.
4. **Build the queue** — for each source folder, select:
   - `1` → RAW mode (direct copy)
   - `2` → TAR mode (streaming archive)
   - `3` → TAR-CHUNK mode (size-limited local archives with incremental purge) — enter a max chunk size and a local exchange buffer directory when prompted
   - Whether to purge the source after verified transfer
5. **Add manual paths** — optionally add explicit nested source paths not shown in the top-level list.
6. **Review and execute** — inspect the full task queue, then launch or reconfigure.

### Example: migrate a Google Drive folder to Backblaze B2 as a TAR archive

```
Select GLOBAL SOURCE Remote Node (index): 0        # gdrive:
Select GLOBAL DESTINATION Remote Node (index): 1   # b2:

Detected Top-Level Directories on Source:
  0) Projects
  1) Photos
  2) Documents

Select a folder index to configure: 0              # Projects
Choose option (1-3): 2                             # TAR mode
Select destination directory: 0                    # b2: root
Purge source upon verified success? (y/n): n

Select a folder index to configure: q              # done
Choose engine action (1-3): 1                      # execute
```

### Example: two-remote raw copy with post-transfer purge

```bash
# After selecting remotes and folders interactively:
# Mode: RAW, Purge: yes
# → rclone copy src: dst: && rclone check src: dst: && rclone purge src:
```

### Example: chunked archive migration for a large nested folder

```
Select a folder index to configure: 0              # Archive (500 GB, deeply nested)
Choose option (1-3): 3                              # TAR-CHUNK mode
Enter max chunk size per local archive batch: 50G
Enter local exchange buffer directory: /mnt/scratch/migration_buffer
Select destination directory: 0                     # dst: root
Purge source upon verified success? (y/n): y

Select a folder index to configure: q               # done
Choose engine action (1-3): 1                       # execute
# → recursively scans Archive/, bin-packs into ~10 chunks of <=50G each,
#   builds/pushes/verifies/purges one chunk at a time
```

---

## Rate Limiting

The execution core applies conservative API pacing flags by default to avoid hitting remote API quotas (tuned for Google Drive but applicable broadly):

```
--drive-pacer-burst 1
--drive-pacer-min-sleep 100ms
--tpslimit 10
--low-level-retries 15
```

Adjust `PACER_FLAGS` in the script if your remotes support higher throughput or have different rate limits.

---

## Changelog

Version history and a description of what changed in each release lives in [CHANGELOG.md](CHANGELOG.md).

**Current version: 4.0** — adds TAR-CHUNK mode (recursive scan, size-bounded local archives, incremental per-chunk purge), refactors the queue/execution engine into `Core::QueueManager` / `Engine::ChunkPacker` / `Engine::CloudTransfer` / `System::Diagnostics` namespaces, and switches RAW mode from `rclone sync` to `rclone copy` so overlapping destination paths are never destructively deleted.

---

## License

This project is released into the public domain under [The Unlicense](LICENSE).
