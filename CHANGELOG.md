# Changelog

All notable changes to `rclone-cloud-migrator` are documented in this file.

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
