# rclone-cloud-migrator

An interactive, queue-based multi-cloud migration tool built on top of [rclone](https://rclone.org/). Designed for high-volume data movement between any two rclone-compatible storage backends with real-time streaming, cryptographic integrity validation, and optional post-transfer purge.

**Author & Maintainer:** Konstantin Haletckii

---

## Architecture

```
┌────────────────────────────────────────────────────────┐
│             Interactive Configuration Phase             │
│  Select source remote → select destination remote →    │
│  browse top-level dirs → build ordered task queue      │
└───────────────────────┬────────────────────────────────┘
                        │
          ┌─────────────▼─────────────┐
          │      Task Queue Engine     │
          │  [ src | dst | mode | purge ]  ...  │
          └─────────────┬─────────────┘
                        │
          ┌─────────────▼─────────────────────────────────┐
          │              Execution Core                     │
          │                                                 │
          │  TAR mode:  rclone mount (FUSE) → tar cf - │  │
          │             rclone rcat  (streaming pipe)   │  │
          │                                                 │
          │  RAW mode:  rclone sync → rclone check      │  │
          │             (cryptographic hash validation)  │  │
          │                                                 │
          │  Post-transfer: optional rclone purge src   │  │
          └─────────────────────────────────────────────────┘
```

The script is a single self-contained Bash file with no external dependencies beyond `rclone`, `tar`, and `fusermount`.

---

## Features

### Real-Time On-the-Fly Streaming TAR Mode
- Mounts the source path via `rclone mount` (FUSE) into a temporary directory.
- Pipes `tar cf -` directly into `rclone rcat` — no intermediate disk writes.
- Produces a single `.tar` archive at the destination without buffering the full archive locally.
- Post-stream size verification confirms the archive is non-zero before any purge action.

### RAW Sync Mode with Cryptographic Hash Verification
- Transfers data with `rclone sync` (multi-transfer, buffered).
- Follows every transfer with `rclone check` to compare source and destination using backend-native checksums (MD5, SHA-1, or equivalent depending on the remote).
- Purge is gated: the source is only deleted if the hash check exits cleanly.

### Interactive Queue Builder
- Numbered menus for remote selection and destination directory browsing.
- Supports both auto-discovered top-level folders and manually typed nested paths.
- Each queue entry carries its own mode (`raw` / `tar`) and purge flag (`yes` / `no`).
- Queue is reviewable and resettable before execution begins.

### Post-Transfer Safe Purge
- Configurable per task at queue-build time.
- TAR mode: purge fires only after size validation confirms a non-zero remote archive.
- RAW mode: purge fires only after `rclone check` passes with zero errors.
- Source is never touched if any verification step fails.

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

### Session walkthrough

1. **Select source remote** — choose from the numbered list of configured rclone remotes.
2. **Select destination remote** — same list, pick the target backend.
3. **Browse destination** — top-level directories on the destination are fetched and presented as a menu. Choose `0` for root or `m` to type a custom path.
4. **Build the queue** — for each source folder, select:
   - `1` → RAW mode (direct sync)
   - `2` → TAR mode (streaming archive)
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
Choose option (1-2): 2                             # TAR mode
Select destination directory: 0                    # b2: root
Purge source upon verified success? (y/n): n

Select a folder index to configure: q              # done
Choose engine action (1-3): 1                      # execute
```

### Example: two-remote raw sync with post-transfer purge

```bash
# After selecting remotes and folders interactively:
# Mode: RAW, Purge: yes
# → rclone sync src: dst: && rclone check src: dst: && rclone purge src:
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

## License

This project is released into the public domain under [The Unlicense](LICENSE).
