#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "gwtrc"

repo="$(mk_repo)"
log="$GWT_TEST_ROOT/hook.log"
mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"

# A tracked .gwtrc is code that arrived with a pull. It is never sourced.
write_gwtrc "$repo" 'gwt_setup() { print -r -- PWNED >> '"$log"' }'
git -C "$repo" add -f .gwtrc
git -C "$repo" commit -qm "commit the rc"
cd "$wt"
run_gwt setup
assert_rc 50 "gwtrc: refuses a tracked .gwtrc"
assert_missing "$log" "gwtrc: the tracked hook never ran"
assert_err_has "git tracks it" "gwtrc: says why it refused"

# add must refuse it too, not just setup
cd "$repo"
run_gwt add feat-b
assert_missing "$log" "gwtrc: add does not run a tracked hook either"
cd "$repo"

# untracked again, it works
git -C "$repo" rm -q --cached .gwtrc
git -C "$repo" commit -qm untrack
cd "$wt"
run_gwt setup
assert_rc 0 "gwtrc: an untracked .gwtrc is sourced"
assert_content "$log" PWNED "gwtrc: the hook runs once untracked"

# resolution order: repo file, then per-repo user config, then global
rm "$repo/.gwtrc"
: > $log
write_global_rc 'gwt_setup() { print -r -- global >> '"$log"' }'
run_gwt setup
assert_content "$log" global "gwtrc: falls back to the global rc"

: > $log
write_user_rc "$repo" 'gwt_setup() { print -r -- per-repo >> '"$log"' }'
run_gwt setup
assert_content "$log" per-repo "gwtrc: per-repo user config beats global"

: > $log
write_gwtrc "$repo" 'gwt_setup() { print -r -- repo-file >> '"$log"' }'
run_gwt setup
assert_content "$log" repo-file "gwtrc: the repo file wins over both"

# nothing the config defines may reach the calling shell
write_gwtrc "$repo" \
  "GWT_SERVER='npm run dev'" \
  'GWT_SERVER_PORT=9000' \
  'gwt_setup() { : }'
run_gwt setup
assert_eq "" "$GWT_SERVER" "gwtrc: GWT_SERVER does not leak into the caller"
assert_eq "" "$GWT_SERVER_PORT" "gwtrc: GWT_SERVER_PORT does not leak into the caller"
assert_eq 0 "${+functions[gwt_setup]}" "gwtrc: gwt_setup does not leak into the caller"

# add runs setup, and --no-setup skips it
: > $log
write_gwtrc "$repo" 'gwt_setup() { print -r -- "ran-in-${GWT_WORKTREE:t}" >> '"$log"' }'
cd "$repo"
run_gwt add feat-c
assert_rc 0 "add: succeeds with a setup hook"
assert_content "$log" "ran-in-wt-feat-c" "add: runs setup in the new worktree"
cd "$repo"
: > $log
run_gwt add feat-d --no-setup
assert_rc 0 "add --no-setup: succeeds"
assert_eq 0 "$(grep -c ran-in $log)" "add --no-setup: skips the hook"
cd "$repo"

# a failing hook must not strand you: still cd in, still report
write_gwtrc "$repo" 'gwt_setup() { return 7 }'
cd "$repo"
gwt add feat-e >/dev/null 2>&1
rc=$?
assert_eq 51 "$rc" "add: a failing hook returns non-zero"
assert_eq "$(wt_path $repo feat-e)" "$PWD" "add: a failing hook still leaves you in the worktree"
cd "$repo"

# teardown runs inside the worktree, just before it goes
: > $log
write_gwtrc "$repo" 'gwt_teardown() { print -r -- "bye-${GWT_WORKTREE:t}-$(pwd -P | sed "s#.*/##")" >> '"$log"' }'
run_gwt rm feat-c
assert_rc 0 "rm: succeeds with a teardown hook"
assert_content "$log" "bye-wt-feat-c-wt-feat-c" "rm: teardown runs in the worktree being removed"
assert_missing "$(wt_path $repo feat-c)" "rm: worktree still removed"

# a failing teardown must never block a removal
: > $log
write_gwtrc "$repo" 'gwt_teardown() { print -r -- tried >> '"$log"'; return 9 }'
run_gwt rm feat-d
assert_rc 0 "rm: a failing teardown does not block removal"
assert_content "$log" tried "rm: the teardown was attempted"
assert_missing "$(wt_path $repo feat-d)" "rm: worktree removed despite the failure"

# the step cache goes away with the worktree
write_gwtrc "$repo" 'gwt_setup() { gwt_step deps --watch README -- true }'
cd "$repo"
run_gwt add feat-f
state="$(git -C "$(wt_path $repo feat-f)" rev-parse --absolute-git-dir)/gwt-state"
assert_exists "$state/deps" "state: recorded for the new worktree"
cd "$repo"
run_gwt rm feat-f
assert_missing "$state" "state: git removes it along with the worktree"

cd /
gwt_test_done
