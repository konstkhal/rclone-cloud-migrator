# Changelog

All notable changes to `rclone-cloud-migrator` are documented in this file.

## [4.5.0] - 2026-07-10

### Changed
- `DROPBOX_PURGE_REMOTE` (v4.4.0, a single optional dedicated remote for purge) generalized to `DROPBOX_PURGE_REMOTES` — a space-separated list of one or more dedicated Dropbox remotes. When more than one is listed, a chunk's purge manifest is split round-robin across all of them and purged concurrently, one background `rclone delete` process per remote, each against its own independently-authorized rate-limit budget (per Dropbox's per-authorization rate-limit model). A single-remote list, or the empty default (falls back to the primary source remote), behaves identically to the previous one-process-one-call shape. Verified in isolation against a fake rclone stand-in: correct fallback when unset, correct single-remote routing, and an even, no-duplicate, no-loss round-robin split across 3 remotes with an uneven (7-item) manifest.

### TODO
- Added a README `TODO` entry: generalize dedicated-remote assignment beyond just purge — let a role (list / read / sync / purge / copy / etc.) be assigned per configured remote synonym, so any operation type could be distributed across multiple independently-authorized apps, not only deletes.

## [4.4.0] - 2026-07-10

### Added
- `DROPBOX_PURGE_REMOTE` — optional dedicated Dropbox remote (a second App Key authorized against the same account) for purge's delete calls specifically. Live investigation on Tokyo found real purge durations (71-87 min for ~1700-2000 items) far exceeding both the old per-file loop and every batching attempt, with strong evidence (a single long-idle connection, unread data sitting in the receive buffer, minimal CPU across the whole elapsed time) pointing to real server-side Dropbox throttling triggered by *cumulative* API usage across the whole pipeline (mount reads + scan + purge), not anything specific to how the delete calls are issued. Per Dropbox's own docs, rate limits are enforced per-authorization and separate apps linked by the same user don't share a budget — so giving purge its own app keeps its request volume from competing with mount/scan/build traffic under the primary remote. Empty/unset by default; purge behaves exactly as before unless explicitly configured.

## [4.3.3] - 2026-07-10

### Fixed
- `Core::RemoteLock`'s first-run assumption was wrong: `rclone lsf` on the not-yet-existing `.rclone-cloud-migrator-locks/` directory was assumed to return an empty listing on both Dropbox and Drive (prefix-based backends, no real "missing directory" concept) — confirmed live that it actually errors (`directory not found`) on both. Under the old logic this meant "doesn't exist yet" was indistinguishable from "no access," so the lock directory was never created and remote locking silently never activated on any first run. A listing failure is no longer treated as fatal to that remote on its own — it just skips the pre-write conflict check and falls through to attempting the write, whose own success/failure is what now determines whether that remote's lock is skipped. Also surfaced, incidentally: the source Dropbox account appears to be near its storage quota (`path/insufficient_space` on a few-byte write) — the only write-to-Dropbox operation anywhere in this script is this lock file, so it's new exposure from v4.3.0 specifically, not a risk to the existing read/delete pipeline; source-side remote locking will simply stay unavailable (falls back to the local flock) until Dropbox has free space again.

## [4.3.2] - 2026-07-10

### Fixed
- `Transfer::purge_source_manifest()`'s v4.2.4 batched `rclone delete --files-from` call was missing `--no-traverse`, which made it *slower* than the per-file loop it replaced: confirmed live on a real chunk purge (62m9s, vs. ~45-55 min under the old code) and diagnosed via `-vv --dry-run`, `--files-from` without `--no-traverse` does a full recursive listing of the entire remaining source tree and filters it down to the manifest — cost scales with total remaining tree size (345K+ objects), not chunk size (~1-2k files), and gets relatively worse as the migration progresses and purges an ever-smaller fraction of what's left. `--no-traverse` switches this to a direct, targeted per-file lookup instead — confirmed via the same `-vv --dry-run` trace to eliminate the full-tree scan entirely. This is rclone's own documented recommendation for a small manifest against a much larger tree, which is exactly this script's TAR-CHUNK purge shape.

## [4.3.1] - 2026-07-10

### Added
- `TODO` entry documenting an alternative `Core::RemoteLock` design: one canonical, synced system-wide lock-state file instead of independent per-remote lock objects. Documentation-only release; no script behavior changes.

## [4.3.0] - 2026-07-09/10

### Added
- `Core::RemoteLock` — a second, cross-machine lock layered on top of v4.2.5's local `flock`: before starting each queued task, the script writes a lock object to `.rclone-cloud-migrator-locks/<task_key>.lock` at the root of both the source and destination remotes (outside the migrated path itself, so it's never picked up by `Packer::scan_payload`'s recursive listing). The local `flock` only protects against a second instance on the same host; this catches a second instance launched from a *different* machine against the same remote — the gap the local lock can't cover. Not a true distributed lock (check-then-write isn't atomic on most rclone backends), so it narrows the race rather than closing it. A remote that can't be listed/written to for locking purposes (read-only creds, quota, etc.) is skipped with a warning rather than treated as fatal; only an actually-existing lock object halts the run. Staleness is deliberately manual-only — a lock left behind by a crash blocks future runs until removed by hand, consistent with this script's existing halt-and-let-the-operator-decide philosophy, rather than an auto-expiry heuristic that a merely-slow run could also trip.

## [4.2.5] - 2026-07-09

### Added
- Single-instance guard: the script now acquires an exclusive `flock` on `state/.migrator.lock` before doing anything else, and exits immediately if another instance already holds it. Uses `flock` (tied to the process's file descriptor) rather than a PID file, so the lock is released automatically on any exit — including a crash or `SIGKILL` — with no stale-lock cleanup needed. Prevents two concurrent runs from racing on the same chunk-index state file or source manifest.

## [4.2.4] - 2026-07-09

### Fixed
- `Transfer::purge_source_manifest()` deleted each source file with its own standalone `rclone deletefile` process call, in a loop with a hardcoded 0.25s sleep between items. On a live TAR-CHUNK run this made purge the dominant cost of each chunk cycle (~45-55 min for a ~1700-item chunk) even though the actual API deletes were fast — the cost was ~1s of process/backend-init overhead paid over and over, plus the sleep. It also meant `DROPBOX_PACER_FLAGS`'s `--tpslimit` was being reset on every single invocation instead of pacing against one shared budget. Replaced the loop with one `rclone delete --files-from <manifest>` call per chunk, so the whole manifest purges through rclone's normal concurrent checkers/transfers in a single process.

## [4.2.3] - 2026-07-09

### Fixed
- The Source Size Assessment Matrix (`rclone size --json` during interactive setup) could crash the whole script: if the call ultimately failed and returned nothing, the downstream `bytes_count`/`objects_count` parsing wasn't guarded like the `rclone` call itself, so `pipefail`'s propagated grep-no-match triggered an uncaught `set -e` abort instead of falling back to "Unknown" (which `format_bytes` and the display line already supported).
- That same call's `rclone` stderr was discarded to `/dev/null`, so a failure here left no diagnostic trail at all — unlike everywhere else covered by the v4.2 durable log. Its stderr now appends to the durable log instead.

## [4.2.2] - 2026-07-09

### Added
- `TODO` section in README.md tracking planned future work: test coverage for the pure-logic functions (bin-packing, byte formatting, input validation, chunk-index state parsing) via `bats-core`, pacing for the remaining unpaced Drive-side setup listing calls, and making TAR-CHUNK's bin-packing itself resume-aware (today's fix only prevents destination-filename collisions, not manifest re-grouping after a restart).

Documentation-only release; no script behavior changes.

## [4.2.1] - 2026-07-09

### Fixed
- The crash-safety trap's `CURRENT_STAGE` tracking was only ever updated inside the TAR-CHUNK pipeline, so an uncaught crash during a RAW or TAR task would misreport whatever stage a prior TAR-CHUNK task had left behind. Adds `Diagnostics::mark_task_phase()`, the non-chunked counterpart to `mark_phase()`, with call sites at each mount/push/verify/purge transition in both modes.
- RAW mode's `rclone copy` call had no failure guard at all, unlike every other remote operation in the script — a failed copy would trigger a bare `set -e` abort instead of a clean logged failure and continue to the next queue item.

## [4.2] - 2026-07-08 to 2026-07-09

### Added
- Durable execution log (`logs/`, one file per run, next to the script) — `log_info`/`log_warn`/`log_err` and `Diagnostics::halt_chunk_pipeline`'s halt banner now persist to disk in addition to stderr, and a new `Diagnostics::mark_phase()` records a per-chunk phase marker (`BUILT`/`VERIFIED_LOCAL`/`PUSHED`/`VERIFIED_REMOTE`/`PURGED`/`FLUSHED`) so a crash's exact stage is visible from the log alone, without manual forensics.
- Crash-safety trap (`EXIT`/`INT`/`TERM`/`HUP`) — unmounts any live FUSE mount and logs the last known stage on any catchable termination. Best-effort only: cannot catch `SIGKILL`/OOM.
- Persisted, monotonic chunk index for TAR-CHUNK mode — `Packer::init` now scopes a small state file (`state/`, next to the script) by source+destination, so a restart continues chunk numbering from where it left off instead of resetting to `part001` and silently overwriting already-completed chunks on the remote. Self-heals when no state file exists yet (first run under this tracking, or a lost state file) by probing the destination for the highest existing chunk already there.
- `DROPBOX_PACER_FLAGS` — pacing (`--tpslimit`, `--low-level-retries`) applied to every rclone call against the Dropbox source remote: the TAR-CHUNK manifest scan and purge loop, and the three interactive-setup calls (top-level folder listing, sub-folder drilldown, payload size check) that previously had none.

### Fixed
- `Packer::persist_chunk_idx` is now wrapped in the same `if ! ...; then halt...; fi` pattern as every other stage in the chunk loop, so a failed state-file write halts with a proper diagnosed banner instead of a bare `set -e` abort.

## [4.1.1] - 2026-07-07

### Fixed
- `Transfer::resumable_push()` discarded `rclone copy`'s exit status — the function always returned success regardless of whether the push actually landed, so a failed chunk push could only ever be caught downstream by the remote size check in `Transfer::verify_remote_mass()`. The function now captures and propagates `rclone copy`'s real exit code, so a failed push halts the TAR-CHUNK pipeline immediately via `Diagnostics::halt_chunk_pipeline` instead of relying solely on the secondary size-verification step.

## [4.1] - 2026-07-06

### Added
- `prompt_strict_choice()` — a shared white-list input helper that re-prompts until the raw answer is exactly one of a given single-character set, rejecting empty input, stray carriage returns, multi-character strings, and out-of-set characters (e.g. Cyrillic look-alikes) instead of silently defaulting.

### Changed
- Wired `prompt_strict_choice()` into the four menu prompts most exposed to garbage input: profile choice (`1`-`3`), engine action (`1`-`3`), purge confirmation (`y`/`n`), and both recursive folder drill-down prompts (`y`/`n`) — one in `select_dst_path`, one in `configure_queue`.

## [4.0] - 2026-07-06

### Added
- **TAR-CHUNK mode** — a third queue profile that recursively scans a source tree, bin-packs files into size-bounded local archives (`chunk_bytes`), and processes them one at a time: build local tar → verify local integrity → push via `rclone copy` → verify remote size → purge only the source files in that chunk → flush the local buffer.
  - Fixes a v3.0 blind spot where a deeply nested subdirectory was invisible to archiving because scanning only went one level deep; the new manifest scan (`rclone lsf -R`) walks the full tree regardless of nesting.
  - Chunk purge is transactional per file: a failure at any stage (local tar build, local verify, remote push, remote verify, or purge) halts the whole pipeline via `Diagnostics::halt_chunk_pipeline` and leaves the local buffer, remaining source data, and destination untouched for manual inspection — it never silently continues to the next chunk or task.
  - Respects dry-run: chunks are still built and locally verified for a realistic size/count preview, but push, remote verify, purge, and buffer flush are skipped.

### Changed
- Refactored the task queue and execution engine into `Core::QueueManager`, `Engine::ChunkPacker`, `Engine::CloudTransfer`, and `System::Diagnostics` namespaces (parallel arrays instead of delimited `SRC|DST|MODE|PURGE` strings), so no code path IFS-splits a record to read a field.
- RAW mode now uses `rclone copy` instead of `rclone sync`, since `sync` deletes destination files absent from the source — unacceptable once destination paths can overlap across queue entries (e.g. multiple TAR-CHUNK batches landing under the same directory).

## [3.0] - 2026-06-30 to 2026-07-02

### Added
- Initial interactive, queue-based migrator: RAW (`rclone sync` + `rclone check`) and TAR (FUSE mount + streaming `tar` → `rclone rcat`) modes, numbered remote selection, per-task purge flag, and a review/execute loop.
- Interactive destination directory selection menu with infinite on-demand drilldown into subfolders, replacing free-text path entry.
- Dry-run simulation mode: an interactive `[Y/n]` safety prompt before any remote is touched, or `-d`/`--dry-run` to go straight into simulation. Integrity checks and purge are skipped while simulating.
- Source payload assessment matrix (total size / object count) and TAR-mode compressed-size projection shown before a folder is queued.
- Project `README.md` and `LICENSE` (Unlicense).

### Fixed
- 10 correctness bugs from code review: stderr/stdout leakage into captured remote names, a non-existent `rclone tar` subcommand replaced with FUSE mount + `tar` pipe, stale array indices after folder removal, missing `pipefail`, lost `PIPESTATUS` on the tar→rcat pipe, existence-only archive verification replaced with a non-zero byte-size check before purge, dead array initialization, and a shell-fork-heavy string-trim replaced with parameter expansion.
- Destination directory scan simplified to top-level only — a two-level scan was slow on large remotes and rarely needed for menu selection.
- Misaligned box-drawing characters in the README architecture diagram.
