#!/usr/bin/env bash
# Offline regression suite. Only sandbox copies and mocked service calls are used.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for dependency in bash jq mktemp cp; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 1; }
done
mkdir -p /tmp/opencode
SANDBOX=$(mktemp -d /tmp/opencode/test-rerun-requested.XXXXXX) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX"/{scripts/lib,configs,templates,bin,home,tmp,state,logs,fixtures}
cp "$ROOT/configs/system.conf" "$SANDBOX/configs/system.conf"
cp "$ROOT/scripts/lib/common.sh" "$SANDBOX/scripts/lib/common.sh"
cp "$ROOT/scripts/get-ado-bugs.sh" "$ROOT/scripts/repair-ado.sh" "$SANDBOX/scripts/"
cp "$ROOT/templates/tracking-issue.md" "$SANDBOX/templates/tracking-issue.md"
export TEST_SANDBOX="$SANDBOX" HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp"
unset BMS_NO_LOCAL_CONF BASH_ENV ENV AZURE_DEVOPS_EXT_PAT ADO_PAT GH_TOKEN GITHUB_TOKEN
cat > "$SANDBOX/configs/system.local.conf" <<'CONF'
STATE_DIR="$WORKSPACE_ROOT/state"
TEMP_DIR="$WORKSPACE_ROOT/tmp"
LOG_DIR="$WORKSPACE_ROOT/logs"
ADO_BUGS_FILE="$TEMP_DIR/ado-bugs.json"
APP_REPO_DIR="$WORKSPACE_ROOT/app"
APP_WORKTREE_DIR="$WORKSPACE_ROOT/worktrees"
GITHUB_ORG="offline"
GITHUB_REPO="fixture"
ADO_ORG="https://ado.invalid"
CONF
# Fail closed if a test unexpectedly reaches an external command. Even sleep is
# blocked: service failures must not turn the test suite into a retry timer.
for command_name in az gh curl wget git sleep herdr claude; do
  cat > "$SANDBOX/bin/$command_name" <<'BLOCK'
#!/usr/bin/env bash
printf 'Unexpected external command: %s\n' "$0 $*" >&2
printf '%s\n' "$0 $*" >> "$TEST_SANDBOX/fixtures/unexpected"
exit 97
BLOCK
  chmod +x "$SANDBOX/bin/$command_name"
done
export PATH="$SANDBOX/bin:$PATH"
cat > "$SANDBOX/fixtures/mocks.sh" <<'MOCKS'
mock_log() {
  jq -cn --args '$ARGS.positional' -- "$@" >> "$TEST_SANDBOX/fixtures/calls.jsonl"
}
mock_arg() {
  local wanted="$1"; shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$wanted" ]; then printf '%s' "${2:-}"; return; fi
    shift
  done
  return 1
}
az() {
  mock_log az "$@"
  case "$1 $2 ${3:-}" in
    'boards query --organization')
      mock_arg --wiql "$@" > "$TEST_SANDBOX/fixtures/query.txt"
      cat "$TEST_SANDBOX/fixtures/query.json" ;;
    'boards work-item show')
      local id; id=$(mock_arg --id "$@")
      cat "$TEST_SANDBOX/fixtures/item-$id.json" ;;
    'boards work-item update')
      local id state; id=$(mock_arg --id "$@")
      if state=$(mock_arg --state "$@"); then
        jq --arg s "$state" '.fields."System.State" = $s' \
          "$TEST_SANDBOX/fixtures/item-$id.json" > "$TEST_SANDBOX/fixtures/item.tmp"
        mv "$TEST_SANDBOX/fixtures/item.tmp" "$TEST_SANDBOX/fixtures/item-$id.json"
      fi
      echo '{}' ;;
    'devops invoke --organization') cat "$TEST_SANDBOX/fixtures/comments.json" ;;
    *) echo "Unexpected az arguments: $*" >&2; return 97 ;;
  esac
}
# No retry sleeps, token cache, or REST calls in this suite.
az_retry() { az "$@"; }
ado_set_tags() {
  mock_log tags "$@"
  # Capture the map at tag-write time to prove repair reconciles it first.
  if [ -f "$ADO_MAP_FILE" ]; then
    cp "$ADO_MAP_FILE" "$TEST_SANDBOX/fixtures/map-at-tags-$1.json"
  else
    echo '{}' > "$TEST_SANDBOX/fixtures/map-at-tags-$1.json"
  fi
  jq --arg tags "$2" '.fields."System.Tags" = $tags' \
    "$TEST_SANDBOX/fixtures/item-$1.json" > "$TEST_SANDBOX/fixtures/item.tmp"
  mv "$TEST_SANDBOX/fixtures/item.tmp" "$TEST_SANDBOX/fixtures/item-$1.json"
  printf '%s\n' "$2"
}
gh() {
  mock_log gh "$@"
  case "$1 ${2:-}" in
    'issue view')
      [ ! -f "$TEST_SANDBOX/fixtures/inaccessible" ] || return 1
      cat "$TEST_SANDBOX/fixtures/issue.json" ;;
    'issue create') echo 'https://github.com/offline/fixture/issues/900' ;;
    'issue comment'|'issue edit'|'issue reopen') return 0 ;;
    'api graphql')
      jq -n --arg p "$BOOSTCX_DELIVERY_PROJECT_ID" \
        '{data:{repository:{issue:{projectItems:{nodes:[{project:{id:$p}}]}}}}}' ;;
    *) echo "Unexpected gh arguments: $*" >&2; return 97 ;;
  esac
}
# Board/field population is out of scope; log these follow-ups so skipped and
# dry-run tests still prove they never execute.
add_tracking_issue_to_project() { mock_log project "$@"; }
set_tracking_issue_fields() { mock_log fields "$@"; }
pending_issue_fields() { mock_log pending_fields "$@"; echo '{"inputs":[],"names":[]}'; }
MOCKS
# Append only to the sandbox copy, leaving the real implementation untouched.
printf '\nsource "$REPO_ROOT/fixtures/mocks.sh"\n' >> "$SANDBOX/scripts/lib/common.sh"

fail() { echo "ASSERTION FAILED: $*" >&2; return 1; }
assert_json() {
  jq -e "$2" "$1" >/dev/null || fail "$1 does not satisfy: $2"
}
assert_equal() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_no_mutations() {
  assert_json "$SANDBOX/fixtures/calls.jsonl" 'true'
  jq -se 'all(.[]; (.[0] == "az" and .[1:4] != ["boards","work-item","update"]) or (.[0] == "gh" and (.[1:3] == ["issue","view"] or .[1:3] == ["api","graphql"])) or .[0] == "pending_fields")' \
    "$SANDBOX/fixtures/calls.jsonl" >/dev/null || fail 'unexpected mutation in service call log'
}
assert_calls() {
  jq -se "$1" "$SANDBOX/fixtures/calls.jsonl" >/dev/null || fail "service call assertion: $1"
}
snapshot() {
  # Compare content and presence (not mtimes or transient lock files).
  local f
  for f in "$ADO_MAP_FILE" "$ADO_RERUN_FILE" "$ADO_HISTORY_FILE"; do
    printf '%s\n' "${f##*/}"
    if [ -f "$f" ]; then cat "$f"; else echo ABSENT; fi
  done
}
item() {
  jq -n --argjson id "$1" --arg tags "$2" --arg state "${3:-Triaged}" \
    '{id:$id,fields:{"System.Title":"Fixture bug","System.Tags":$tags,"System.State":$state,"Microsoft.VSTS.TCM.ReproSteps":"Repro"}}' \
    > "$SANDBOX/fixtures/item-$1.json"
}
reset_fixture() {
  rm -f "$SANDBOX/state/"* "$SANDBOX/tmp/"* "$SANDBOX/fixtures/"{item-*,map-at-tags-*,calls.jsonl,query.txt,inaccessible,unexpected}
  echo '{}' > "$SANDBOX/state/ado-to-github-map.json"
  : > "$SANDBOX/fixtures/calls.jsonl"
  echo '[]' > "$SANDBOX/fixtures/query.json"
  echo '{"comments":[]}' > "$SANDBOX/fixtures/comments.json"
  echo '{"body":"OLD RCA body & details","state":"CLOSED","url":"https://github.com/offline/fixture/issues/42"}' > "$SANDBOX/fixtures/issue.json"
  source "$SANDBOX/scripts/lib/common.sh"
  printf '# Root Cause Analysis\nFresh RCA && resolution details\n' > "$TEMP_DIR/report.md"
}
collect_fixture() {
  # Includes substring false positives, normal tracked bugs, wrong states, and
  # both numeric and retained-sentinel reruns, plus a first-time migration.
  echo '{"1":"42","2":"77","3":"BLOCKED","4":"44","5":"55","6":"ALREADY_FIXED","8":"BLOCKED","9":"ALREADY_FIXED"}' > "$ADO_MAP_FILE"
  echo '{"6":{"status":"completed","issue":"66"}}' > "$ADO_RERUN_FILE"
  echo '{"1":[{"previous":"","outcome":"42"}]}' > "$ADO_HISTORY_FILE"
  item 1 ' unrelated ; rErUnReQuEsTeD ; MigratedToGitHub '
  item 2 'MigrateToGitHub'
  item 3 'MigrateToGitHub; ReRunRequestedLater'
  item 4 'ReRunRequested' 'In Development'
  item 5 'prefixReRunRequested'
  item 6 'ReRunRequested; AlreadyFixed'
  item 7 'migratetogithub'
  item 8 'MigrateToGitHub; RequiresAdditionalInformation'
  item 9 'MigrateToGitHub; AlreadyFixed'
  item 10 'MigrateToGitHub' 'New'
  item 11 'MigrateToGitHubExtra'
  echo '[{"id":1},{"id":2},{"id":3},{"id":4},{"id":5},{"id":6},{"id":7},{"id":8},{"id":9},{"id":10},{"id":11}]' > "$SANDBOX/fixtures/query.json"
}
assert_collection() {
  assert_json "$ADO_BUGS_FILE" 'map(.id) == ["1","6","7"] and .[0].rerun_requested == true and .[0].linked_issue == "42" and .[1].rerun_requested == true and .[1].linked_issue == "66" and .[2].rerun_requested == false'
  local query; query=$(cat "$SANDBOX/fixtures/query.txt")
  [[ "$query" == *"AND ([System.Tags] CONTAINS 'MigrateToGitHub' OR [System.Tags] CONTAINS 'ReRunRequested') AND [System.State] = 'Triaged'"* ]] || fail "incorrect WIQL: $query"
}
test_tags() {
  has_tag 'Other;  rErUnReQuEsTeD ; tail' ReRunRequested
  has_tag $'Other;\tMIGRATETOGITHUB\t' MigrateToGitHub
  if has_tag 'ReRunRequestedExtra; prefixReRunRequested; ReRun Requested' ReRunRequested; then fail 'substring matched'; fi
  if has_tag '' ReRunRequested; then fail 'empty tags matched'; fi
}
test_collector_dry() {
  collect_fixture
  local before; before=$(snapshot)
  bash "$SANDBOX/scripts/get-ado-bugs.sh" --limit 20 > "$TEMP_DIR/collector.log"
  assert_collection
  assert_equal "$(snapshot)" "$before"
  assert_no_mutations
}
test_collector_live() {
  collect_fixture
  local map history; map=$(cat "$ADO_MAP_FILE"); history=$(cat "$ADO_HISTORY_FILE")
  bash "$SANDBOX/scripts/get-ado-bugs.sh" --live --limit 20 > "$TEMP_DIR/collector.log"
  assert_collection
  assert_equal "$(cat "$ADO_MAP_FILE")" "$map"
  assert_equal "$(cat "$ADO_HISTORY_FILE")" "$history"
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"pending",issue:"42",outcome:"42"} and .["6"] == {status:"pending",issue:"66",outcome:"66"} and keys == ["1","6"]'
  assert_calls '[.[] | select(.[0:4] == ["az","boards","work-item","update"]) | .[index("--id")+1]] == ["1","6","7"]'
}
prepare_link() {
  item 1 'Unrelated; ReRunRequested; MigrateToGitHub; MigratedToGitHub; RequiresAdditionalInformation; AlreadyFixed'
  echo '{"1":"42"}' > "$ADO_MAP_FILE"
  echo '{"1":{"status":"pending","issue":"42"}}' > "$ADO_RERUN_FILE"
}
assert_reuse() {
  local state="$1"
  assert_calls 'all(.[]; .[0:3] != ["gh","issue","create"])'
  assert_calls '[.[] | select(.[0] == "gh") | .[1:3]] == '"$state"
  assert_calls 'any(.[]; .[0:3] == ["gh","issue","comment"] and .[3] == "42" and (.[index("--body")+1] | contains("Previous RCA / resolution plan") and contains("OLD RCA body & details")))'
  assert_calls 'any(.[]; .[0:3] == ["gh","issue","edit"] and .[3] == "42" and .[index("--title")+1] == "Fix: Fresh title" and (.[index("--body")+1] | contains("Fresh RCA && resolution details")))'
  assert_json "$ADO_MAP_FILE" '.["1"] == "42"'
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"completed",issue:"42",outcome:"42"}'
}
test_reuse_closed() {
  prepare_link; LIVE=true
  assert_equal "$(create_tracking_issue 1 'Fresh title' https://ado.invalid/1 "$TEMP_DIR/report.md" abc true)" 42
  assert_reuse '[["issue","view"],["issue","comment"],["issue","edit"],["issue","reopen"]]'
}
test_reuse_retained_open() {
  prepare_link; LIVE=true
  echo '{"1":"BLOCKED"}' > "$ADO_MAP_FILE"
  jq '.state = "OPEN"' "$SANDBOX/fixtures/issue.json" > "$TEMP_DIR/issue.tmp"
  mv "$TEMP_DIR/issue.tmp" "$SANDBOX/fixtures/issue.json"
  assert_equal "$(create_tracking_issue 1 'Fresh title' https://ado.invalid/1 "$TEMP_DIR/report.md" abc true)" 42
  assert_reuse '[["issue","view"],["issue","comment"],["issue","edit"]]'
  assert_json "$ADO_HISTORY_FILE" '.["1"][-1].previous == "BLOCKED" and .["1"][-1].outcome == "42"'
}
test_inaccessible() {
  prepare_link; LIVE=true
  touch "$SANDBOX/fixtures/inaccessible"
  local before rc=0; before=$(snapshot)
  create_tracking_issue 1 Title https://ado.invalid/1 "$TEMP_DIR/report.md" abc true > "$TEMP_DIR/result" || rc=$?
  assert_equal "$rc" 1
  assert_equal "$(snapshot)" "$before"
  assert_calls 'length == 1 and .[0][0:4] == ["gh","issue","view","42"]'
}
test_tracking_dry() {
  prepare_link
  local before; before=$(snapshot)
  create_tracking_issue 1 Title https://ado.invalid/1 "$TEMP_DIR/report.md" abc true > "$TEMP_DIR/result" 2> "$TEMP_DIR/preview"
  assert_equal "$(snapshot)" "$before"
  assert_calls 'length == 0'
  assert_equal "$(cat "$TEMP_DIR/result")" ''
  grep -q 'issue #42' "$TEMP_DIR/preview"
}
test_tracking_dry_new() {
  item 1 ReRunRequested
  local before; before=$(snapshot)
  create_tracking_issue 1 Title https://ado.invalid/1 "$TEMP_DIR/report.md" abc true > "$TEMP_DIR/result" 2> "$TEMP_DIR/preview"
  assert_equal "$(snapshot)" "$before"
  assert_calls 'length == 0'
  assert_equal "$(cat "$TEMP_DIR/result")" ''
  grep -q 'gh issue create' "$TEMP_DIR/preview"
}
test_reuse_unchanged_body() {
  prepare_link; LIVE=true
  local body
  body=$(render_tracking_issue_body "$TEMP_DIR/report.md" 1 https://ado.invalid/1 'Fresh title' abc)
  jq --arg body "$body" '.body = $body' "$SANDBOX/fixtures/issue.json" > "$TEMP_DIR/issue.tmp"
  mv "$TEMP_DIR/issue.tmp" "$SANDBOX/fixtures/issue.json"
  assert_equal "$(create_tracking_issue 1 'Fresh title' https://ado.invalid/1 "$TEMP_DIR/report.md" abc true)" 42
  assert_calls '[.[] | select(.[0] == "gh") | .[1:3]] == [["issue","view"],["issue","edit"],["issue","reopen"]]'
}
test_new_issue() {
  item 1 ReRunRequested; LIVE=true
  assert_equal "$(create_tracking_issue 1 Title https://ado.invalid/1 "$TEMP_DIR/report.md" abc true)" 900
  assert_calls '[.[] | select(.[0] == "gh") | .[1:3]] == [["issue","create"]]'
  assert_json "$ADO_MAP_FILE" '.["1"] == "900"'
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"completed",issue:"900",outcome:"900"}'
}
test_default_flag() {
  item 1 MigrateToGitHub; LIVE=true
  assert_equal "$(create_tracking_issue 1 Title https://ado.invalid/1 "$TEMP_DIR/report.md" abc)" 900
  assert_calls 'any(.[]; .[0:3] == ["gh","issue","create"])'
  [ ! -f "$ADO_RERUN_FILE" ] || fail 'default flag wrote rerun ledger'
}
assert_outcome() {
  local value="$1" tag="$2"
  assert_json "$ADO_MAP_FILE" '.["1"] == "'"$value"'"'
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"completed",issue:"42",outcome:"'"$value"'"}'
  assert_json "$ADO_HISTORY_FILE" '.["1"] | length == 1 and .[0].previous == "42" and .[0].outcome == "'"$value"'" and (.[0].at | length > 0)'
  assert_equal "$(ado_linked_issue 1)" 42
  assert_equal "$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-1.json")" "Unrelated; $tag"
  assert_calls 'all(.[]; .[0] != "gh") and any(.[]; .[0:4] == ["az","boards","work-item","update"] and index("--discussion") != null)'
}
test_blocked() {
  prepare_link; LIVE=true
  post_ado_blocker_comment 1 "$TEMP_DIR/report.md"
  assert_outcome BLOCKED "$BLOCKED_TAG"
}
test_already_fixed() {
  prepare_link; LIVE=true
  post_ado_already_fixed_comment 1 "$TEMP_DIR/report.md" abc
  assert_outcome ALREADY_FIXED "$ALREADY_FIXED_TAG"
}
test_outcome_dry() {
  prepare_link
  local before; before=$(snapshot)
  post_ado_blocker_comment 1 "$TEMP_DIR/report.md" > "$TEMP_DIR/preview"
  post_ado_already_fixed_comment 1 "$TEMP_DIR/report.md" abc >> "$TEMP_DIR/preview"
  assert_equal "$(snapshot)" "$before"
  assert_calls 'length == 0'
}
test_repair_skip() {
  echo '{"1":"42","2":"BLOCKED","3":"ALREADY_FIXED","4":"44"}' > "$ADO_MAP_FILE"
  echo '{"1":{"status":"pending","issue":"42"},"4":{"status":"completed","issue":"44"}}' > "$ADO_RERUN_FILE"
  item 1 MigratedToGitHub 'In Development'
  item 2 ReRunRequested Triaged
  item 3 rErUnReQuEsTeD 'In Development'
  item 4 ReRunRequested Triaged
  local before; before=$(snapshot)
  bash "$SANDBOX/scripts/repair-ado.sh" --live > "$TEMP_DIR/repair.log"
  assert_equal "$(snapshot)" "$before"
  assert_calls 'length == 4 and all(.[]; .[0:4] == ["az","boards","work-item","show"])'
  assert_equal "$(grep -c 'rerun queued/in progress' "$TEMP_DIR/repair.log")" 4
}
test_repair_completed() {
  echo '{"1":"BLOCKED","2":"42"}' > "$ADO_MAP_FILE"
  echo '{"1":{"status":"completed","issue":"41"},"2":{"status":"completed","issue":"42"}}' > "$ADO_RERUN_FILE"
  item 1 'Unrelated; ReRunRequested; MigrateToGitHub; AlreadyFixed' 'In Development'
  item 2 'Unrelated; ReRunRequested; RequiresAdditionalInformation' 'In Development'
  echo '{"comments":[{"text":"More information is required before this bug can be investigated"},{"text":"RCA complete - tracking issue updated after rerun: #42 (https://github.com/offline/fixture/issues/42)"}]}' > "$SANDBOX/fixtures/comments.json"
  local before; before=$(snapshot)
  bash "$SANDBOX/scripts/repair-ado.sh" --live > "$TEMP_DIR/repair.log"
  assert_equal "$(snapshot)" "$before"
  assert_equal "$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-1.json")" "Unrelated; $BLOCKED_TAG"
  assert_equal "$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-2.json")" "Unrelated; $MIGRATED_TAG"
  assert_calls '[.[] | select(.[0] == "tags") | .[1]] == ["1","2"]'
  assert_calls 'all(.[]; .[0:4] != ["az","boards","work-item","update"] and .[0:3] != ["gh","issue","create"])'
  grep -q '2 repaired, 0 still need attention' "$TEMP_DIR/repair.log"
}

test_outcome_map_failure_recovery() {
  prepare_link; LIVE=true
  item 1 'Unrelated; ReRunRequested; MigrateToGitHub; MigratedToGitHub; AlreadyFixed' 'In Development'
  local tags ledger rc=0
  tags=$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-1.json")
  # Fail only this shell's helper; subprocess repair reloads the real helper.
  ado_map_set() { return 1; }
  post_ado_blocker_comment 1 "$TEMP_DIR/report.md" > "$TEMP_DIR/result" 2> "$TEMP_DIR/error" || rc=$?
  assert_equal "$rc" 3
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"completed",issue:"42",outcome:"BLOCKED"}'
  ledger=$(cat "$ADO_RERUN_FILE")
  assert_json "$ADO_MAP_FILE" '.["1"] == "42"'
  [ ! -f "$ADO_HISTORY_FILE" ] || fail 'failed map helper wrote history'
  assert_equal "$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-1.json")" "$tags"
  assert_calls 'length == 1 and .[0][0:4] == ["az","boards","work-item","update"]'
  # The prior discussion was posted successfully. Supply it for repair's read.
  echo '{"comments":[{"text":"More information is required before this bug can be investigated"}]}' > "$SANDBOX/fixtures/comments.json"
  : > "$SANDBOX/fixtures/calls.jsonl"
  bash "$SANDBOX/scripts/repair-ado.sh" --live > "$TEMP_DIR/repair.log"
  assert_json "$ADO_MAP_FILE" '.["1"] == "BLOCKED"'
  assert_json "$SANDBOX/fixtures/map-at-tags-1.json" '.["1"] == "BLOCKED"'
  assert_json "$ADO_HISTORY_FILE" '.["1"] | length == 1 and .[0].previous == "42" and .[0].outcome == "BLOCKED"'
  assert_equal "$(cat "$ADO_RERUN_FILE")" "$ledger"
  assert_equal "$(ado_linked_issue 1)" 42
  assert_equal "$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-1.json")" "Unrelated; $BLOCKED_TAG"
  assert_calls 'any(.[]; .[0] == "tags") and all(.[]; .[0] != "gh" and .[0:4] != ["az","boards","work-item","update"])'
  grep -q '1 repaired, 0 still need attention' "$TEMP_DIR/repair.log"
}
test_tracking_ledger_failure() {
  prepare_link; LIVE=true
  echo '{"1":"BLOCKED"}' > "$ADO_MAP_FILE"
  local before_item before_ledger rc=0
  before_item=$(cat "$SANDBOX/fixtures/item-1.json")
  before_ledger=$(cat "$ADO_RERUN_FILE")
  ado_rerun_set() { return 1; }
  create_tracking_issue 1 'Fresh title' https://ado.invalid/1 "$TEMP_DIR/report.md" abc true > "$TEMP_DIR/result" 2> "$TEMP_DIR/error" || rc=$?
  assert_equal "$rc" 1
  assert_json "$ADO_MAP_FILE" '.["1"] == "42"'
  assert_json "$ADO_HISTORY_FILE" '.["1"][-1].previous == "BLOCKED" and .["1"][-1].outcome == "42"'
  assert_equal "$(cat "$ADO_RERUN_FILE")" "$before_ledger"
  assert_equal "$(cat "$SANDBOX/fixtures/item-1.json")" "$before_item"
  assert_equal "$(ado_linked_issue 1)" 42
  assert_calls '[.[] | .[0]] | all(.[]; . == "gh")'
  assert_calls '[.[] | .[1:3]] == [["issue","view"],["issue","comment"],["issue","edit"],["issue","reopen"]]'
}
test_prepare_standalone_rerun() {
  echo '{"1":"42"}' > "$ADO_MAP_FILE"
  item 1 ReRunRequested
  echo '[{"id":1}]' > "$SANDBOX/fixtures/query.json"
  local before; before=$(snapshot)
  bash "$SANDBOX/scripts/get-ado-bugs.sh" --limit 20 > "$TEMP_DIR/collector.log"
  assert_equal "$(snapshot)" "$before"
  assert_json "$ADO_BUGS_FILE" 'length == 1 and .[0].rerun_requested and .[0].linked_issue == "42"'
  prepare_ado_rerun 1
  assert_equal "$(snapshot)" "$before"
  : > "$SANDBOX/fixtures/calls.jsonl"
  LIVE=true
  prepare_ado_rerun 1
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"pending",issue:"42",outcome:"42"}'
  assert_json "$ADO_MAP_FILE" '.["1"] == "42"'
  assert_calls 'length == 0'
  post_ado_blocker_comment 1 "$TEMP_DIR/report.md"
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"completed",issue:"42",outcome:"BLOCKED"}'
  assert_json "$ADO_MAP_FILE" '.["1"] == "BLOCKED"'
  assert_equal "$(ado_linked_issue 1)" 42
  assert_equal "$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-1.json")" "$BLOCKED_TAG"
}
test_missing_map_dry() {
  rm "$ADO_MAP_FILE"
  source "$SANDBOX/scripts/lib/common.sh"
  local before; before=$(snapshot)
  [ ! -f "$ADO_MAP_FILE" ] || fail 'sourcing common created missing map'
  assert_equal "$(ado_map_get 1)" ''
  item 1 ReRunRequested
  echo '[{"id":1}]' > "$SANDBOX/fixtures/query.json"
  bash "$SANDBOX/scripts/get-ado-bugs.sh" --limit 20 > "$TEMP_DIR/collector.log"
  assert_json "$ADO_BUGS_FILE" 'length == 1 and .[0].rerun_requested and .[0].linked_issue == ""'
  prepare_ado_rerun 1
  create_tracking_issue 1 Title https://ado.invalid/1 "$TEMP_DIR/report.md" abc true > "$TEMP_DIR/result" 2> "$TEMP_DIR/preview"
  post_ado_blocker_comment 1 "$TEMP_DIR/report.md" >> "$TEMP_DIR/preview"
  bash "$SANDBOX/scripts/repair-ado.sh" > "$TEMP_DIR/repair.log"
  assert_equal "$(snapshot)" "$before"
  assert_no_mutations
}
test_repair_missing_map_completed() {
  rm "$ADO_MAP_FILE"
  echo '{"1":{"status":"completed","issue":"42","outcome":"BLOCKED"}}' > "$ADO_RERUN_FILE"
  item 1 'Unrelated; ReRunRequested; MigrateToGitHub; MigratedToGitHub; AlreadyFixed' 'In Development'
  echo '{"comments":[{"text":"More information is required before this bug can be investigated"}]}' > "$SANDBOX/fixtures/comments.json"
  local before tags rc=0
  before=$(snapshot)
  tags=$(cat "$SANDBOX/fixtures/item-1.json")
  bash "$SANDBOX/scripts/repair-ado.sh" > "$TEMP_DIR/repair-dry.log" || rc=$?
  assert_equal "$rc" 1
  assert_equal "$(snapshot)" "$before"
  assert_equal "$(cat "$SANDBOX/fixtures/item-1.json")" "$tags"
  assert_no_mutations
  : > "$SANDBOX/fixtures/calls.jsonl"
  # No explicit ID: discover this record from the ledger without a map file.
  bash "$SANDBOX/scripts/repair-ado.sh" --live > "$TEMP_DIR/repair.log"
  assert_json "$ADO_MAP_FILE" '.["1"] == "BLOCKED"'
  assert_json "$SANDBOX/fixtures/map-at-tags-1.json" '.["1"] == "BLOCKED"'
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"completed",issue:"42",outcome:"BLOCKED"}'
  assert_json "$ADO_HISTORY_FILE" '.["1"] | length == 1 and .[0].previous == "" and .[0].outcome == "BLOCKED"'
  assert_equal "$(ado_linked_issue 1)" 42
  assert_equal "$(jq -r '.fields."System.Tags"' "$SANDBOX/fixtures/item-1.json")" "Unrelated; $BLOCKED_TAG"
  assert_calls 'any(.[]; .[0] == "tags") and all(.[]; .[0] != "gh")'
  grep -q '1 repaired, 0 still need attention' "$TEMP_DIR/repair.log"
}

test_normal_reset_completion_failure() {
  # A manually cleared map must not leave an obsolete completion authoritative.
  rm "$ADO_MAP_FILE"
  echo '{"1":{"status":"completed","issue":"42","outcome":"BLOCKED"}}' > "$ADO_RERUN_FILE"
  item 1 'Unrelated; MigrateToGitHub; RequiresAdditionalInformation' 'In Development'
  LIVE=true
  local before_item pending_ledger rc=0
  before_item=$(cat "$SANDBOX/fixtures/item-1.json")
  ado_rerun_set() {
    mock_log ledger_set "$@"
    # Pending preparation remains real; only the completion write fails.
    [ "$2" != completed ] || return 1
    with_lock ado-map _ado_rerun_set_unlocked "$@"
  }
  gh() {
    mock_log gh "$@"
    [ "$1 ${2:-}" = 'issue create' ] || return 97
    # Assert at the service boundary, not just after the attempted completion.
    assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"pending",issue:"42",outcome:"42"}' || return 97
    [ ! -f "$ADO_MAP_FILE" ] || return 97
    echo 'https://github.com/offline/fixture/issues/900'
  }
  create_tracking_issue 1 'Manual reset' https://ado.invalid/1 "$TEMP_DIR/report.md" abc false > "$TEMP_DIR/result" 2> "$TEMP_DIR/error" || rc=$?
  assert_equal "$rc" 1
  assert_equal "$(cat "$TEMP_DIR/result")" ''
  assert_json "$ADO_MAP_FILE" '.["1"] == "900"'
  assert_json "$ADO_HISTORY_FILE" '.["1"] | length == 1 and .[0].previous == "" and .[0].outcome == "900"'
  assert_json "$ADO_RERUN_FILE" '.["1"] == {status:"pending",issue:"42",outcome:"42"}'
  pending_ledger=$(cat "$ADO_RERUN_FILE")
  assert_equal "$(cat "$SANDBOX/fixtures/item-1.json")" "$before_item"
  assert_equal "$(ado_linked_issue 1)" 900
  assert_calls 'length == 3 and .[0] == ["ledger_set","1","pending","42"] and .[1][0:3] == ["gh","issue","create"] and .[2] == ["ledger_set","1","completed","900"]'
  grep -qF "add $RERUN_REQUESTED_TAG in $ADO_NEW_STATE to retry this manually reset migration safely" "$TEMP_DIR/error"
  : > "$SANDBOX/fixtures/calls.jsonl"
  # Reload real helpers in the subprocess: pending must suppress obsolete repair.
  local before; before=$(snapshot)
  bash "$SANDBOX/scripts/repair-ado.sh" --live > "$TEMP_DIR/repair.log"
  assert_equal "$(snapshot)" "$before"
  assert_equal "$(cat "$ADO_RERUN_FILE")" "$pending_ledger"
  assert_equal "$(cat "$SANDBOX/fixtures/item-1.json")" "$before_item"
  assert_json "$ADO_MAP_FILE" '.["1"] == "900"'
  assert_calls 'length == 1 and .[0][0:4] == ["az","boards","work-item","show"]'
  grep -q 'rerun queued/in progress - skipping repair' "$TEMP_DIR/repair.log"
}

passed=0 failed=0
for test in test_tags test_collector_dry test_collector_live test_reuse_closed \
  test_reuse_retained_open test_reuse_unchanged_body test_inaccessible \
  test_tracking_dry test_tracking_dry_new test_new_issue \
  test_default_flag test_blocked test_already_fixed test_outcome_dry \
  test_repair_skip test_repair_completed test_outcome_map_failure_recovery \
  test_tracking_ledger_failure test_prepare_standalone_rerun \
  test_missing_map_dry test_repair_missing_map_completed \
  test_normal_reset_completion_failure; do
  (
    set -eE
    trap 'echo "Failure at line $LINENO: $BASH_COMMAND" >&2' ERR
    reset_fixture
    "$test"
    [ ! -f "$SANDBOX/fixtures/unexpected" ] || fail 'blocked external command attempted'
  ) > "$SANDBOX/logs/$test.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS $test"; passed=$((passed + 1))
  else
    echo "FAIL $test (exit $rc)"
    cat "$SANDBOX/logs/$test.log"
    failed=$((failed + 1))
  fi
done
echo "$passed passed, $failed failed (offline sandbox only)."
[ "$failed" -eq 0 ]
