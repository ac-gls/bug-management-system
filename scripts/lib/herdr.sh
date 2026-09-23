#!/bin/bash
# Thin wrappers over the real herdr CLI (herdr 0.8.0), verified live against a running
# `herdr` server/session before this file was written:
#   herdr workspace create --cwd <path> --label <text>
#     -> JSON: .result.workspace.workspace_id, .result.root_pane.pane_id
#   herdr agent start <name> --kind claude --pane <pane_id> --timeout <ms>
#     -> despite docs claiming success means "the expected agent was detected... and is ready
#     for input", confirmed live under load that it can report success while the pane is
#     actually still sitting at a bare shell prompt with "claude" typed but never submitted -
#     verify the real Claude Code banner before trusting this (see herdr_start_claude).
#   herdr agent send-keys <name> <down|enter>  (dismisses the one-time "trust this folder?"
#     dialog that appears the first time Claude Code opens a brand-new worktree directory -
#     its default-highlighted option is "No, exit", not the trust option, so this must move
#     down before confirming rather than just pressing enter)
#   herdr agent prompt <name> "<text>" --wait --timeout <ms>
#   herdr agent read <name> --source recent-unwrapped|visible --lines <n>
#     -> recent/recent-unwrapped read scrollback, which is always empty while Claude Code runs
#     its fullscreen (alternate-screen) renderer - confirmed live on v2.1.280. Only `visible`
#     sees that screen. Use herdr_read below rather than calling this directly.
#   herdr workspace close <workspace_id>
#
# Requires jq.

# Opens a new herdr workspace rooted at <cwd>, returns "<workspace_id> <pane_id>" on stdout.
# Focused (not --no-focus) on purpose: the point of running this through herdr instead of
# plain background jobs is to watch the agents work - attach the TUI (`herdr session attach
# default`) before running the pipeline script to see each bug's pane as it opens.
herdr_open_pane() {
  local cwd="$1" label="$2" json
  json=$(herdr workspace create --cwd "$cwd" --label "$label") || return 1
  local ws pane actual_cwd
  ws=$(echo "$json" | jq -r '.result.workspace.workspace_id')
  pane=$(echo "$json" | jq -r '.result.root_pane.pane_id')
  actual_cwd=$(echo "$json" | jq -r '.result.root_pane.cwd')
  if [ -z "$ws" ] || [ "$ws" = "null" ] || [ -z "$pane" ] || [ "$pane" = "null" ]; then
    echo "herdr_open_pane: unexpected response: $json" >&2
    return 1
  fi
  # Confirmed in practice this can silently happen (e.g. a nonexistent path from a failed
  # worktree creation upstream) - herdr opens the pane at some fallback cwd instead of
  # erroring, which then quietly runs the agent in the wrong directory entirely.
  if [ "$actual_cwd" != "$cwd" ]; then
    echo "herdr_open_pane: requested cwd '$cwd' but pane opened at '$actual_cwd' - closing it" >&2
    herdr workspace close "$ws" >/dev/null 2>&1
    return 1
  fi
  echo "$ws $pane"
}

# Prints an agent's terminal output: scrollback when there is any (classic renderer), else the
# visible screen (fullscreen renderer, where scrollback is always empty - see header).
# Args: <agent-name> <lines>
herdr_read() {
  local name="$1" lines="$2" out
  out=$(herdr agent read "$name" --source recent-unwrapped --lines "$lines" 2>/dev/null)
  if ! printf '%s' "$out" | grep -q '[^[:space:]]'; then
    out=$(herdr agent read "$name" --source visible --lines "$lines" 2>/dev/null)
  fi
  printf '%s\n' "$out"
}

herdr_close_workspace() {
  herdr workspace close "$1" >/dev/null 2>&1 || true
}

# Starts a claude agent in an existing pane and dismisses the first-run trust dialog.
# Args: <agent-name> <pane-id>
#
# A pane freshly created by `workspace create` can still be "busy" (shell still settling)
# for a moment before it reports as an available interactive prompt - `agent start` fails
# immediately with agent_pane_busy in that window rather than waiting it out itself, so this
# retries a few times with a short backoff instead of failing on the first race.
herdr_start_claude() {
  local name="$1" pane="$2" attempt out
  for attempt in 1 2 3 4 5; do
    out=$(herdr agent start "$name" --kind "$HERDR_AGENT_KIND" --pane "$pane" --timeout 45000 2>&1)
    if [ $? -eq 0 ]; then
      sleep 1
      # The dialog's cursor defaults to "No, exit" (confirmed live), not "Yes, I trust this
      # folder" - a blind Enter here would select "No, exit" and silently kill the agent
      # before it ever sees a prompt. Only act when the dialog is actually showing (it isn't
      # on a worktree path Claude has already been trusted on), and pick "Yes" explicitly by
      # moving down one option first instead of trusting Enter's default.
      if herdr agent read "$name" --source visible --lines 30 2>/dev/null | grep -q "Yes, I trust this folder"; then
        herdr agent send-keys "$name" down >/dev/null 2>&1 || true
        sleep 0.3
        herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
      fi
      sleep 1

      # `agent start`'s own exit code is not proof the CLI actually launched: confirmed live
      # (every one of 9 investigations in one run) that under load it reports success while
      # the pane is still sitting at a bare shell prompt with "claude" typed but never
      # submitted - the same submitting-Enter starvation herdr_prompt_and_wait already works
      # around, just hitting the launch keystroke instead of the prompt one. Trusting that
      # exit code sent every subsequent prompt into a plain shell, which of course could never
      # "start working". Require the actual Claude Code banner before declaring success, and
      # recover with a bare Enter (same recipe as herdr_prompt_and_wait) if it hasn't rendered
      # yet - it's a shared, well-tested fallback, harmless to send again if Claude is already
      # up (an extra Enter on an empty composer is a no-op).
      # The banner alone isn't enough: on a tall pane the composer is padded with blank lines
      # and the banner scrolls out of the 30-line window (confirmed live - Claude was up and
      # idle but the check failed). The composer's footer markers never appear in a bare
      # shell, so any of them is equally good proof the CLI is running.
      local ready_attempt
      for ready_attempt in 1 2 3 4 5; do
        if herdr_read "$name" 40 \
            | grep -qE "Claude Code v|shift\+tab to cycle|/effort"; then
          return 0
        fi
        herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
        sleep 2
      done
      echo "herdr_start_claude: agent '$name' reported started but never showed the Claude Code banner; recent output:" >&2
      herdr_read "$name" 40 >&2
      return 1
    fi
    if echo "$out" | grep -q "agent_pane_busy"; then
      sleep 2
      continue
    fi
    echo "herdr_start_claude: $out" >&2
    return 1
  done
  echo "herdr_start_claude: pane $pane still busy after retries" >&2
  return 1
}

# Sends one prompt and blocks until the agent genuinely finishes real work.
# Args: <agent-name> <prompt-text> [timeout-ms]
# Returns 0 and prints nothing meaningful on success; on failure, dumps recent pane
# output to stderr for diagnostics and returns non-zero.
#
# Two-phase by design, not one `--wait --timeout <big>` call:
# Phase 1 confirms the agent actually reaches "working" shortly after submission - this is
# the only way to tell a genuine submission from a no-op. `agent wait`/`agent prompt --wait`
# without --until just check "is the agent CURRENTLY idle/done/blocked", and the agent starts
# out idle - so if the submitting Enter never registers (confirmed to happen even with
# --wait), the very first such check trivially "succeeds" immediately without any real work
# ever happening. This produced 6 live GitHub issues from empty pane content in one run
# before the bug was found: a bare recovery Enter landed on an already-idle agent, `agent
# wait` saw "still idle" and reported success, and the pipeline treated that as a completed
# investigation.
# Phase 2 (only reached once "working" has actually been observed) waits for real completion.
herdr_prompt_and_wait() {
  local name="$1" prompt="$2" timeout="${3:-$HERDR_AGENT_TIMEOUT_MS}"
  local confirm_timeout=15000
  local attempt started=false

  for attempt in 1 2 3; do
    if [ "$attempt" -eq 1 ]; then
      herdr agent prompt "$name" "$prompt" --wait --until working --timeout "$confirm_timeout" >/dev/null 2>&1 && { started=true; break; }
    else
      echo "herdr_prompt_and_wait: agent '$name' has not started working after submission (recovery attempt $((attempt - 1))) - sending a bare Enter" >&2
      herdr agent send-keys "$name" enter >/dev/null 2>&1
      herdr agent wait "$name" --until working --timeout "$confirm_timeout" >/dev/null 2>&1 && { started=true; break; }
    fi
  done

  if [ "$started" != true ]; then
    echo "herdr_prompt_and_wait: agent '$name' never started working after ${attempt} attempt(s); recent output:" >&2
    herdr_read "$name" 300 >&2
    return 1
  fi

  if ! herdr agent wait "$name" --timeout "$timeout" >/dev/null 2>&1; then
    echo "herdr_prompt_and_wait: agent '$name' did not settle within ${timeout}ms after starting work; recent output:" >&2
    herdr_read "$name" 300 >&2
    return 1
  fi
}

# Prints the agent's recent terminal output (used to capture a final report).
herdr_capture() {
  local name="$1" lines="${2:-500}"
  herdr_read "$name" "$lines"
}
