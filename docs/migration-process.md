# ADO Bug Migration Process

This describes the real, current migration pipeline (`scripts/start-bug-migration.sh` and
`scripts/start-parallel-investigation.sh`). It replaces earlier design drafts in this repo's
history, which used fictional `herdr`/`az` syntax and a broader fixing/PR/QA workflow this
system no longer implements. Treat the header comments in `scripts/*.sh` as the ultimate
source of truth if this doc and the code ever disagree.

## Scope

ADO bug ticket -> investigated, reviewable GitHub tracking issue. Nothing more. This pipeline
never writes application code, never opens a branch that gets merged, and never opens a pull
request. What happens after the tracking issue exists (approval, assignment, implementation)
is your team's own process.

## Phase 1: Query ADO (`get-ado-bugs.sh`)

- Runs a WIQL query against `$ADO_ORG`/`$ADO_PROJECT` for open Bug work items tagged
  `$MIGRATION_TAG` (default `MigrateToGitHub`).
- Skips bugs already recorded in `state/ado-to-github-map.json` (already migrated, or
  previously `BLOCKED` pending more information).
- For each remaining bug (up to `--limit N`), fetches the full work item and writes a
  structured entry (title, description/repro steps, expected/actual results, tenant, priority,
  tags, state, ADO URL) to `ado-bugs.json`.

## Phase 2: Parallel Investigation (`start-parallel-investigation.sh`)

- Clones/fetches the target app repo (`bcx-reporting-platform`, path configured by
  `APP_REPO_DIR`) if needed, and installs the vendored `agents/bcx-bug-rca-agent.md` into it if
  that checkout doesn't already have it.
- Checks out **one shared, read-only worktree** for the whole run - a detached-HEAD checkout of
  `origin/<branch>` (default `main`). Because `bcx-bug-rca-agent` never writes code, every bug
  investigated in this run reads the same checkout concurrently instead of each needing its own
  worktree. It exists purely to isolate this run's code snapshot from whatever else is
  happening in the app repo, and is deleted once every bug in the run has finished.
- For each bug, opens a dedicated Herdr pane and starts a real `claude` agent in it, prompting
  it to run `bcx-bug-rca-agent` against that ADO ticket. Sets the ADO ticket to `Active` as soon
  as investigation starts.
- Each agent writes its findings to a uniquely-named file (`RESOLUTION-PLAN-<ado-id>.md`, not a
  fixed name, since bugs share a directory) and replies in chat with a one-line confirmation
  only - the pipeline never trusts raw chat output as the source of truth.
- The pipeline does **not** trust a "settled" agent as proof of real work: it requires the
  report file to actually exist and be a substantial size before acting on it. A missing or
  suspiciously small file leaves the pane open for manual inspection instead of guessing.
- The terminal you ran the script from shows a live status table (one row per bug, refreshed
  every couple of seconds) instead of interleaved raw log output from every concurrent job -
  each bug's own detail (prompts, dry-run previews, blocker content) goes to
  `temp/log-<ado-id>.txt` instead. See `troubleshooting.md` for reading it during/after a run.
- Exactly one deterministic outcome follows, decided by script logic - never the agent itself:
  - **Resolution plan produced** -> a GitHub tracking issue is created from the report
    (`create_tracking_issue` in `scripts/lib/common.sh`): title `Fix: <ADO bug title>`, body =
    the report verbatim plus an `ADO-#<id>` footer. The ADO ticket gets a comment linking to
    the new issue, and its tag flips `MigrateToGitHub` -> `MigratedToGitHub`.
  - **Blocker found** (the agent's own Step 0 clarity check failed) -> no GitHub issue is
    created. The report's content is instead posted as an ADO comment
    (`post_ado_blocker_comment`), the ticket's tag flips to `RequiresAdditionalInformation`, and
    the bug is marked `BLOCKED` in `state/ado-to-github-map.json` so it's skipped on future runs
    until you clear that entry (and re-add the migration tag) once more information is
    available.

## Dry run vs. live

Everything defaults to a dry run (`--limit 1`, no `--live`): investigation itself always
happens (it's non-destructive - a read-only worktree and an agent conversation), but nothing is
written to ADO or GitHub. Pass `--live` to actually create tracking issues and post ADO
comments.

## Running it

```bash
./scripts/start-bug-migration.sh                       # dry run, one bug
./scripts/start-bug-migration.sh --limit 10 --live      # process up to 10 bugs for real
./scripts/start-bug-migration.sh --branch release/6.17.1 --live   # investigate against a different base
./scripts/test-bug-migration.sh                          # verify: issues created, no leftover shared worktree
```

See `README.md` for prerequisites and configuration.
