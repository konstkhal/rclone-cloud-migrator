# Changelog

All notable changes to `rclone-cloud-migrator` are documented in this file.

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
