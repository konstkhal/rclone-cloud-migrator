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
- Follows every transfer with `rclone check --one-way` to confirm every source file landed correctly at the destination, using backend-native checksums (MD5, SHA-1, or equivalent depending on the remote). One-way because the destination is not exclusive to this task — it can legitimately hold files from sibling folders or prior runs — so purge gates on "did source arrive intact," not "does destination contain nothing else."
- Purge is gated: the source is only deleted if the hash check exits cleanly.
- Destination is used as picked, with nothing appended: `rclone copy` merges the source folder's contents directly into the chosen destination directory (no wrapper folder named after the source is created).
- Optional directory-structure preservation (per-folder prompt, default off): `rclone copy` omits source directories that contain no file, so an empty source folder would be missing on the destination; when enabled, the copy runs with `--create-empty-src-dirs` and empty folders (including nested ones) are recreated on the destination.

### TAR-CHUNK Mode — Size-Bounded Local Archives with Incremental Purge
- Recursively scans the full source tree (`rclone lsf -R`), however deeply nested, so no subdirectory is invisible to the packer.
- Greedy bin-packs the file manifest into archives no larger than a configurable `chunk_bytes` limit (e.g. `50G`, `500M`, or a raw byte count).
- Per chunk: build a local tar from a FUSE-mounted view of the source → verify local archive integrity → push with `rclone copy` → verify the remote copy's size → queue the chunk's source files for async purge → flush the local buffer. A single background purger drains the queue concurrently with subsequent builds, so slow (rate-limited) source deletes never block the transfer pipeline; only the files inside a verified chunk are ever deleted.
- Fails safe: any error at any stage halts the entire pipeline immediately (`Diagnostics::halt_chunk_pipeline`), leaving the local buffer, remaining source data, and destination untouched for manual inspection — it never silently skips ahead.
- Crash-safe resume: chunk numbering is persisted per source+destination task, so an interrupted run picks back up at the correct next index instead of resetting to `part001` and risking an overwrite of already-completed chunks. If no state file exists yet, it self-heals by probing the destination for the highest existing chunk already there.
- Dry-run aware: chunks are still built and locally verified for a realistic preview, but remote push, verification, purge, and buffer flush are skipped.
- Optional directory-structure preservation (per-folder prompt, default off): because chunks pack a files-only manifest, a source directory with no file anywhere beneath it is in no chunk and would not reappear on extraction. When enabled, one terminal `<folder>.part_dirs.tar` carrying the full source directory tree (bare `tar --no-recursion` entries, never any files) is built, pushed, and verified like any chunk, so extracting it alongside the data parts recreates every folder — including the empty ones. Idempotent on resume, and its fixed name sorts after the numeric parts so a `*.part*.tar` restore applies it last.
- Useful for very large or deeply nested folders where a single unified TAR archive (see TAR mode above) would be impractical to build, push, or recover from if interrupted.

### Interactive Queue Builder
- Numbered menus for remote selection and destination directory browsing.
- Supports both auto-discovered top-level folders and manually typed nested paths.
- Each queue entry carries its own mode (`raw` / `tar` / `tar-chunk`) and purge flag (`yes` / `no`), plus chunk size and local buffer path (`tar-chunk`), and a directory-structure preservation flag (`raw` and `tar-chunk`).
- Queue is reviewable and resettable before execution begins.
- Profile choice, engine action, purge confirmation, directory-structure preservation, and folder drill-down prompts are all strictly white-list validated (`prompt_strict_choice`) — empty input, stray carriage returns, and out-of-set characters are rejected and re-prompted rather than silently defaulting.

### Post-Transfer Safe Purge
- Configurable per task at queue-build time.
- TAR mode: purge fires only after size validation confirms a non-zero remote archive.
- RAW mode: purge fires only after `rclone check` passes with zero errors.
- TAR-CHUNK mode: purge is incremental — only the source files inside a chunk are deleted, and only after that chunk's remote copy is verified.
- Source is never touched if any verification step fails.

### Durable Execution Log & Crash-Safety Trap
- Every run writes a timestamped log (`logs/`, next to the script) in addition to the usual stderr output, so a crash's full history survives even if the terminal/screen session that launched it dies without its own logging enabled.
- TAR-CHUNK mode records a phase marker per chunk (`BUILT` / `VERIFIED_LOCAL` / `PUSHED` / `VERIFIED_REMOTE` / `PURGE_QUEUED` / `FLUSHED`, plus an asynchronous `PURGED` logged by the background purger when that chunk's deletes complete), so the log alone shows exactly which stage a crash landed in.
- A trap on `EXIT`/`INT`/`TERM`/`HUP` unmounts any live FUSE mount and logs the last known stage on any catchable termination. Best-effort only — it cannot catch `SIGKILL` or an OOM-kill.

### Concurrency Safety
- Local guard: an exclusive `flock` on `state/.migrator.lock`, acquired before anything else runs. A second launch on the same host exits immediately instead of racing the first. Tied to the process's file descriptor, so it releases automatically on any exit, including a crash — no stale-lock cleanup needed.
- Cross-machine guard: before each queued task, a lock object is written to `.rclone-cloud-migrator-locks/<task_key>.lock` at the root of both the source and destination remotes — the only thing that can catch a second instance launched from a *different* machine against the same remote, which the local `flock` can't see. Not a true atomic distributed lock (check-then-write isn't atomic on most rclone backends); a remote that can't be listed/written to for locking is skipped with a warning rather than failing the run. Staleness is manual-only — a lock left behind by a crash needs to be deleted by hand rather than auto-expiring.

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
   - (RAW and TAR-CHUNK) whether to preserve the source directory structure so empty folders survive — RAW adds `--create-empty-src-dirs`, TAR-CHUNK adds a `<folder>.part_dirs.tar`; TAR mode always preserves the full tree, so it is not asked
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
# → rclone copy src: dst: && rclone check src: dst: --one-way && rclone purge src:
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

A separate, more conservative pacing profile applies to every call against a Dropbox source remote — the TAR-CHUNK manifest scan, the purge loop, and the interactive setup's folder listings and payload size check — since Dropbox's API rate limits are noticeably tighter than Google Drive's in practice:

```
--tpslimit 4
--low-level-retries 10
```

Adjust `DROPBOX_PACER_FLAGS` in the script if needed.

If purge duration becomes the dominant cost and looks like it's hitting Dropbox's real server-side throttling (not just `DROPBOX_PACER_FLAGS`'s own pacing), set `DROPBOX_PURGE_REMOTES` to one or more space-separated rclone remote names (separate Dropbox App Keys, all authorized against the same account) to give purge its own independent rate-limit budget(s), separate from the mount/scan/build traffic under the primary source remote. With more than one remote listed, each chunk's purge manifest is split round-robin across all of them and purged concurrently. Unset by default.

---

## Changelog

Version history and a description of what changed in each release lives in [CHANGELOG.md](CHANGELOG.md).

**Current version: 5.5.1** - RAW mode no longer nests the source's own path under the destination: `rclone copy` now targets exactly the directory picked in the destination prompt, so a folder's contents land there directly instead of underneath a recreated copy of its full source path. TAR and TAR-CHUNK's archive filename / chunks-folder name switched from the full drilled-down path to just the leaf folder name, for the same reason. The RAW purge gate's `rclone check` now runs `--one-way`, since a flattened destination can legitimately hold files that never came from the current source (siblings, prior runs) - purge now correctly gates on "did everything from source land intact," not "does the destination contain nothing else."

**v5.4.1** - wizard prompts hardened against stdin EOF: `read` calls inside command-substituted selector functions now abort the script instead of hot-spinning in their retry loops (bash does not inherit `errexit` into `$(...)` subshells). Interactive use was never affected; the spin only occurred when the script was driven by a pipe. Previous release (5.4.0): directory-structure preservation extended to RAW mode via the same per-folder prompt (`rclone copy --create-empty-src-dirs`), completing the set - TAR always preserves the tree, RAW and TAR-CHUNK on opt-in.

**v5.3.0** - optional, per-folder directory-structure preservation for TAR-CHUNK: when enabled, a terminal `<folder>.part_dirs.tar` carrying the full source directory tree (bare directory entries, no files) is built, pushed, and verified alongside the data chunks, so extracting the archive recreates every folder — including any that were empty at the source and would otherwise be lost, since chunks pack a files-only manifest. Default off; RAW/TAR modes and existing queues unchanged.

**v5.2.0** - chunk builds now tolerate transient FUSE-layer read/stat errors with a bounded rebuild-retry (cooldown between attempts, partial archives never carried forward, same build-clean-or-halt contract), and the previously-silent daemonized read mount logs to a file so a build failure's underlying API error is attributable. Builds on 5.0.1's mount cache hardening and 5.1.0's purge-lag-safe resume filter (see CHANGELOG).

**v5.1.0** - makes crash-resume safe against the async purger lagging the build pipeline: the resume scan is filtered by set membership against the still-queued purge manifests, so chunks already pushed and verified but not yet purged are never re-archived under fresh part numbers. Proven against a live 287,606-file scan before release.

**v5.0.1** - hardens the TAR-CHUNK read mount (`--vfs-cache-mode full` + pacer flags) after a transient Dropbox read error killed a 34-minute chunk build through the bare FUSE mount, and captures tar's stderr to a sidecar referenced in the halt banner.

**v5.0.0** — decouples source purge from the transfer pipeline (`Core::AsyncPurger`): verified chunks' item lists are queued as durable manifests and deleted by a background purger concurrently with subsequent builds, instead of purge running as a blocking serial stage. Live measurement had shown purge (~70-110 min of server-throttled Dropbox deletes per chunk) dominating every cycle while build/push machinery idled. Crash-safe queue, same purge-only-after-verify guarantee, purge failures still halt the pipeline via a persisted flag.

**v4.5.0** — generalizes v4.4.0's single dedicated purge remote into `DROPBOX_PURGE_REMOTES`, a list of one or more. When more than one is configured, a chunk's purge manifest is split round-robin across all of them and purged concurrently, one process per remote, each against its own independently-authorized rate-limit budget — instead of a single dedicated remote absorbing all of purge's request volume alone. A single-remote list (or the empty default) behaves exactly as v4.4.0 did.

**v4.4.0** — adds an optional dedicated Dropbox remote setting to route purge's delete calls through a second, separately-authorized Dropbox app instead of the primary source remote. Live investigation found real purge durations (71-87 min for ~1700-2000 items) worse than every approach tried, with evidence pointing to cumulative server-side Dropbox throttling across the whole pipeline rather than anything about how the delete calls themselves are structured — per Dropbox's docs, a second app gets its own independent rate-limit budget. Unset by default; no behavior change unless configured.

**v4.3.3** — fixes `Core::RemoteLock`'s first-run assumption: `rclone lsf` on the not-yet-existing lock directory was assumed to return an empty listing on Dropbox/Drive, but actually errors (`directory not found`) on both — confirmed live, meaning the lock directory was never created and remote locking silently never activated on any first run. A listing failure no longer blocks that remote outright; it falls through to attempting the write instead, whose own result now decides whether that remote's lock is skipped.

**v4.3.2** — fixes a real regression in v4.2.4's batched purge: it was missing `--no-traverse`, so `rclone delete --files-from` did a full recursive listing of the *entire* remaining source tree on every chunk instead of a targeted per-file lookup — confirmed live to be slower (62m9s) than the per-file loop it replaced (~45-55 min). Adding `--no-traverse` (rclone's own documented recommendation for a small manifest against a much larger tree) eliminates the full-tree scan.

**v4.3.1** — documentation-only: adds a `TODO` entry for an alternative `Core::RemoteLock` design (a single synced system-wide lock-state file instead of independent per-remote lock objects); no script behavior changes.

**v4.3.0** — adds a cross-machine lock layered on top of v4.2.5's local one: before each queued task, the script writes a lock object to `.rclone-cloud-migrator-locks/<task_key>.lock` at the root of both the source and destination remotes, catching a second instance launched from a *different* machine (which the local `flock` can't see). Not a true atomic distributed lock, and a remote that can't be listed/written to for locking is skipped with a warning rather than failing the run; only an actually-existing lock object halts. Staleness is manual-only — a lock left behind by a crash needs to be deleted by hand.

**v4.2.5** — adds a single-instance guard: the script now acquires an exclusive `flock` on `state/.migrator.lock` before doing anything else, and exits immediately if another instance already holds it, preventing two concurrent runs from racing on the same chunk-index state file or source manifest. Uses `flock` rather than a PID file so the lock releases automatically on any exit, including a crash.

**v4.2.4** — fixes TAR-CHUNK mode's purge step: it used to delete each source file with its own standalone `rclone deletefile` process call in a loop (plus a hardcoded 0.25s sleep per item), which made purge the dominant cost of every chunk cycle on large manifests even though the actual deletes were fast. Now one `rclone delete --files-from` call purges the whole chunk's manifest per cycle.

**v4.2.3** — fixes a crash in the Source Size Assessment Matrix (`rclone size --json` during interactive setup): a failed size check previously fell through to an unguarded parsing step that could trigger an uncaught `set -e` abort instead of falling back to "Unknown", and that call's `rclone` stderr is now captured into the durable log instead of discarded, so a future failure there is diagnosable.

**v4.2.2** — documentation-only release, adds the `TODO` section below tracking planned future work; no script behavior changes.

**v4.2.1** — extends the crash-safety trap's stage tracking to RAW and TAR modes (previously only TAR-CHUNK updated it, so a crash during a RAW/TAR task could misreport a stale stage), and fixes RAW mode's `rclone copy` call having no failure guard at all — a failed copy now logs cleanly and moves to the next queue item instead of triggering a bare `set -e` abort.

**v4.2** — adds a durable execution log and per-chunk phase markers, a crash-safety trap (`EXIT`/`INT`/`TERM`/`HUP`) that unmounts any live FUSE mount and records the last known stage on unexpected termination, a persisted/self-healing chunk index so TAR-CHUNK mode resumes numbering correctly after a restart instead of risking an overwrite of already-completed chunks, and Dropbox-side API pacing across both the execution and interactive-setup phases.

**v4.1.1** — fixes `Transfer::resumable_push()` silently discarding `rclone copy`'s exit status; a failed chunk push now halts the TAR-CHUNK pipeline immediately instead of relying solely on the downstream remote size check.

**v4.1** — enforces strict white-list input validation on the profile choice, engine action, purge confirmation, and folder drill-down prompts, so stray characters (empty input, carriage returns, Cyrillic look-alikes, etc.) are rejected and re-prompted instead of silently defaulting.

**v4.0** — adds TAR-CHUNK mode (recursive scan, size-bounded local archives, incremental per-chunk purge), refactors the queue/execution engine into `Core::QueueManager` / `Engine::ChunkPacker` / `Engine::CloudTransfer` / `System::Diagnostics` namespaces, and switches RAW mode from `rclone sync` to `rclone copy` so overlapping destination paths are never destructively deleted.

---

## TODO

- **Test coverage** for the pure-logic functions that don't touch the network — `Packer::generate_chunks`' bin-packing, `format_bytes`, `prompt_strict_choice`'s validation, the chunk-index state-file parsing — via a lightweight framework like `bats-core`. Full end-to-end coverage of the live `rclone`/FUSE flows isn't the goal here; that would need either extensive mocking or real remotes in CI. Note: `bats-core` would be a new dependency, not yet approved.
- Apply `PACER_FLAGS`-style pacing to the remaining unpaced destination-remote (Google Drive) listing calls in interactive setup (`select_dst_path`'s directory browsing) — lower priority than the Dropbox-side fixes since Drive hasn't shown any actual throttling.
- TAR-CHUNK mode's persisted chunk index (v4.2) only fixes destination-filename collisions on resume; it doesn't make manifest bin-packing itself resume-aware, so the exact chunk *grouping* after an interrupted run may differ from what an uninterrupted run would have produced.
- Alternative design for `Core::RemoteLock` (v4.3.0): instead of each remote holding its own independent, unrelated lock object, maintain one canonical system-wide lock state as a single raw text file describing all active locks, written to and kept synced across every accessible source — a unified view rather than N independent markers. Would need a reconciliation strategy for when copies diverge (a crash mid-sync, or a remote unreachable during a sync pass), which the current per-remote-independent design sidesteps entirely by not requiring the remotes to agree with each other at all — each one's lock object is checked and trusted in isolation. Worth exploring if multi-machine usage becomes common enough that a unified view (e.g. "what's running, where, right now") is actually needed, rather than just "is *this* remote currently locked."
- Generalize `DROPBOX_PURGE_REMOTES` (v4.5.0) beyond just purge: rather than a single special-cased operation getting a dedicated remote list, let a *role* (list / read / sync / purge / copy / etc.) be assigned per configured remote synonym, so any operation type — not only deletes — could be distributed across multiple independently-authorized apps if it turns out to be the one hitting Dropbox's real throttling hardest for a given dataset's shape.

---

## License

This project is released into the public domain under [The Unlicense](LICENSE).
