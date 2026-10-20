# Brief 1792521845: Drain the household Dropbox account to Google Drive

Project: rclone-cloud-migrator
From: Lead
Type: feature
Urgency: urgent
Related: none

## Description

The Owner has directed that the household Dropbox account (the `dropboxNav` remote, the
Owner's wife's account) be drained to Google Drive, raised as a separate task of its own
weight rather than another line on the board. Vikunja task 21 "Migrate wife's Dropbox to
Google Drive" already exists and is the oldest open item in this project: it is the reason
`smart_migrator.sh` was written in the first place, and it has never been run to
completion. The Owner called it important and set no deadline.

This Brief exists because the tooling question is now settled and the job is no longer
blocked on it. The `cryo_chamber` programme finished on 2026-09-20, which freed both the
machine and the Drive-side attention it was consuming, and v5.8.0 - the release that fixed
TAR-CHUNK resume and added the completion contract - merged to master today. What remains
undecided is how to run this particular migration, and that decision is not the Lead's to
take alone.

## Evidence

State of the tooling, as of master `d133bb3`:

- v5.8.0 is merged and live-validated. Its resume arithmetic and completion contract were
  proven against a real 86,975-file, 170.03 GiB recovery that ran 47h47m and drained its
  source completely, verified against the destination and a source re-listing rather than
  against the script's exit status.
- `tests/resume_arithmetic.bats` exists (bats-core, 15 cases, `rclone` replaced by a
  recording double). It mocks `rclone`; the mount, the tar build and the push are covered
  only by that live run.

Known constraints specific to this source, all previously observed, none hypothetical:

- **The source account is roughly 119x over its plan**: 1011 GiB used against an 8.5 GiB
  allowance. Reads and deletes work; every upload is rejected with
  `path/insufficient_space`. A drain *out of* Dropbox is therefore possible, but the
  source-side remote-lock file cannot be written and will keep failing in the log. That
  warning is expected and is not to be "fixed" by swapping the upload primitive.
- **Recursive listing hits a wall.** `rclone lsf -R` against this account hangs at roughly
  6600 directories in a single operation. The known-good approach is per-subtree divide
  and conquer, subdividing on the wall and pruning file-bearing subtrees.
- **Purge against Dropbox is server-side throttled**, with a floor of roughly 70 to 120
  minutes per chunk. A dedicated purge remote was tested against this and made it worse,
  not better.
- Open defect, Vikunja 175: when the completion contract's source re-listing dies under it
  (a suspend, a dropped connection), the pipeline halts a correct run as a failure and
  advises a rescan that does not apply. It recurred on this machine as recently as today.

## Requested outcome

One RFC, opened against this Brief, that puts the following before the Owner for a
decision. The Lead will write the Implications and propose a Resolution; none of these is
settled and the Lead is not deciding them here.

1. Mode: RAW copy, TAR, or TAR-CHUNK, and the chunk size if chunked. The cryo precedent
   used 5 GiB TAR-CHUNK, but that source was Drive-to-Drive with a FUSE mount, and this
   one is a throttled third-party remote roughly six times larger.
2. Purge policy: whether the source is purged as chunks verify (as the cryo job did), or
   left intact and deleted by the Owner afterwards. This is a household account with one
   over-quota copy of what may be the only copy of some of it, so the answer is not
   automatically "yes" as it was for the staging folders.
3. Destination layout on Drive, and whether the result is browsable or archival.
4. Whether it runs unattended under a systemd user unit, as the cryo job did, and if so
   what disables that unit when the job finishes.
5. Whether the listing wall is worked around inside `smart_migrator.sh` or by splitting
   the job into per-subtree tasks by hand.

The Owner's decision on items 2 and 4 is the one the Lead most needs before any Issue can
be written: both are destructive or long-running by nature, and both were learned the hard
way on the previous job.
