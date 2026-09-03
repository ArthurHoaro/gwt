#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "setup-bg"

repo="$(mk_repo)"
marker="$GWT_TEST_ROOT/hook.log"

state_of() { print -r -- "$(git -C "$1" rev-parse --absolute-git-dir)/gwt-state" }

wait_for() {
  local f="$1" i=0
  while (( i < 200 )); do
    [[ -s "$f" ]] && return 0
    sleep 0.1
    (( i++ ))
  done
  return 1
}

# --- a background run, followed back into the foreground -------------------

write_gwtrc "$repo" \
  'gwt_setup() { gwt_step slow -- sh -c "echo working; sleep 1; echo finished" }'
mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"
cd "$wt"
d="$(state_of "$wt")"

run_gwt setup --bg
assert_rc 0 "setup --bg: returns without waiting for the hook"
assert_err_has "running in the background" "setup --bg: says how to follow it"
assert_exists "$d/setup.log" "setup --bg: logs into the worktree's own git dir"

run_gwt setup status
assert_out_has "running" "setup status: reports a live run"

run_gwt setup
assert_rc 53 "setup: refuses a second run while one is live"
run_gwt setup --bg
assert_rc 53 "setup --bg: refuses a second run while one is live"

run_gwt setup attach
assert_rc 0 "setup attach: returns the run's own exit code"
assert_out_has "working" "setup attach: streams the hook's output"
assert_out_has "finished" "setup attach: stays until the hook is done"
assert_err_has "setup finished" "setup attach: says how it ended"

run_gwt setup status
assert_out_has "finished ok" "setup status: reports the outcome after the fact"

# --- a hook that fails in the background ----------------------------------

write_gwtrc "$repo" 'gwt_setup() { gwt_step bad -- sh -c "echo trying; exit 3" }'
run_gwt setup --bg
assert_rc 0 "setup --bg: a run starts again once the last one is done"
wait_for "$d/setup.status" || _fail "setup --bg: the run records an exit code" "timed out"

run_gwt setup attach
assert_rc 51 "setup attach: a failed run comes back non-zero"
assert_out_has "trying" "setup attach: replays the log of a finished run"
run_gwt setup status
assert_out_has "failed (exit 51)" "setup status: names the exit code"

# --- the repo can ask for background by default ---------------------------

write_gwtrc "$repo" 'GWT_SETUP_BG=1' \
  "gwt_setup() { sleep 1; print -r -- ran >> $marker }"

mk_branch "$repo" feat-b
cd "$repo"
run_gwt add feat-b
assert_rc 0 "add: returns straight away when the rc asks for background"
assert_err_has "running in the background" "add: says the setup is in the background"
b="$(state_of "$(wt_path "$repo" feat-b)")"
assert_exists "$b/setup.log" "add: recorded a background run"
wait_for "$b/setup.status" || _fail "add: the background hook finishes" "timed out"
assert_content "$marker" "ran" "add: the backgrounded hook really ran"

: > "$marker"
mk_branch "$repo" feat-c
cd "$repo"
run_gwt add --fg feat-c
assert_rc 0 "add --fg: overrides the rc"
assert_content "$marker" "ran" "add --fg: the hook is done before add returns"
c="$(state_of "$(wt_path "$repo" feat-c)")"
assert_missing "$c/setup.log" "add --fg: nothing is recorded as a background run"

# --- removing a worktree stops the run still writing into it --------------

write_gwtrc "$repo" 'gwt_setup() { gwt_step slow -- sh -c "sleep 30" }'
mk_branch "$repo" feat-d
cd "$repo"
run_gwt add --bg feat-d
dd="$(state_of "$(wt_path "$repo" feat-d)")"
wait_for "$dd/setup.pid" || _fail "add --bg: the runner records its pid" "timed out"
pid="$(<$dd/setup.pid)"

cd "$repo"
run_gwt rm feat-d
assert_rc 0 "rm: removes a worktree whose setup is still running"
assert_err_has "stopping the setup" "rm: says it stopped the live run"
i=0
while (( i < 30 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.1; (( i++ )); done
kill -0 "$pid" 2>/dev/null \
  && _fail "rm: the setup process is gone" "pid $pid still alive" \
  || _ok "rm: the setup process is gone"

# --- worktrees with no run of their own -----------------------------------

mk_branch "$repo" feat-e
e="$(mk_worktree "$repo" feat-e)"
cd "$e"
run_gwt setup status
assert_out_has "no background run" "setup status: says when nothing has run here"
run_gwt setup attach
assert_rc 54 "setup attach: nothing to attach to"
run_gwt setup bogus
assert_rc 52 "setup: rejects an unknown subcommand"

# A pid the runner no longer owns must not read as live, or a recycled pid would
# leave the worktree permanently "running".
mkdir -p "$(state_of "$e")"
print -r -- $$ > "$(state_of "$e")/setup.pid"
run_gwt setup status
assert_out_has "interrupted" "setup status: a pid that is not the runner reads as interrupted"
run_gwt setup attach
assert_rc 51 "setup attach: an interrupted run comes back non-zero"

cd /
gwt_test_done
