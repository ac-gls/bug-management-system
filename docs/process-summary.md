# Process Summary: ADO -> GitHub Issue Creation

## Overview

This system's job stops at a reviewed, well-formed GitHub tracking issue. It does not
implement fixes, run tests, or open pull requests - that work happens outside this repo, on
whatever cadence and process your team already uses.

## The Process

### Step 1: Tag Bugs in Azure DevOps

- Add the `MigrateToGitHub` tag to any ADO Bug work item you want migrated.
- The bug must be open (not `Closed`/`Resolved`/`Done`).

### Step 2: Run the Migration

```bash
./scripts/start-bug-migration.sh --limit 10 --live
```

This queries ADO for tagged bugs, investigates each one (in parallel, via
`bcx-bug-rca-agent` against a shared read-only checkout of the app repo - see
`migration-process.md`), and for each bug does exactly one of:

- Creates a GitHub tracking issue whose body **is** the agent's resolution plan, with a footer
  linking back to the ADO ticket. Comments the issue link back onto the ADO ticket.
- Posts a comment on the ADO ticket explaining what additional information is needed, if the
  agent couldn't establish enough context to investigate (no GitHub issue is created in this
  case).

Without `--live`, nothing is created - the plan/blocker is only shown for review.

### Step 3: Human Review

Read the tracking issue. It's the actual RCA output - root cause, defect location, proposed
fix, tenant-safety and regression-risk notes, a reviewer checklist - not a copy of the raw ADO
ticket. From here, approving the plan, assigning it, and implementing the fix is entirely your
team's own process; this repo has no further role.

## Why Parallel Investigation Is Safe

Every bug in a migration run investigates concurrently against the **same** read-only worktree
(a detached checkout, never committed to), because the investigation agent only ever reads code
and writes its own uniquely-named report file. That worktree is created once per run and
removed once every bug has finished - it exists only to give the run an isolated, consistent
code snapshot, not to persist anything.

State that prevents duplicate/racing work:

- `state/ado-to-github-map.json` - which ADO bugs already have a GitHub issue, or are
  `BLOCKED` pending more information. Both exclude a bug from future runs until cleared.
- Every mutating step (issue creation, ADO comments, tag changes) is decided by deterministic
  script logic reading a verified report file - never by trusting an agent's own claim of
  success.

## What This System Does Not Do

- Does not write, test, or refactor application code.
- Does not open branches meant to be merged, or pull requests.
- Does not gate on any "ready for implementation" label - that concept belongs to whatever
  process your team runs after the tracking issue exists.
