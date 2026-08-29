#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "setup"

repo="$(mk_repo)"
print -r -- '{"v":1}' > "$repo/package-lock.json"
git -C "$repo" add package-lock.json
git -C "$repo" commit -qm lockfile
log="$GWT_TEST_ROOT/hook.log"

mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"
cd "$wt"

# no config at all
run_gwt setup
assert_rc 0 "setup: succeeds with no .gwtrc"

# a config that sets no hook at all is not a failure
write_gwtrc "$repo" "# nothing here yet"
run_gwt setup
assert_rc 0 "setup: a .gwtrc that defines no hook succeeds"

# the plain string form runs, and keeps running: it has no cache
write_gwtrc "$repo" "GWT_SETUP='print -r -- string-form >> $log'"
run_gwt setup
run_gwt setup
assert_rc 0 "setup: GWT_SETUP string form succeeds"
assert_eq 2 "$(grep -c string-form $log)" "setup: the string form always runs"

# hooks are told where they are
: > $log
write_gwtrc "$repo" \
  'gwt_setup() { print -r -- "$GWT_REPO $GWT_BRANCH ${GWT_WORKTREE:t} ${GWT_MAIN_ROOT:t}" >> '"$log"' }'
run_gwt setup
assert_content "$log" "${repo:t} feat-a wt-feat-a ${repo:t}" "setup: exports repo, branch, worktree and main root"

# a function beats the string
: > $log
write_gwtrc "$repo" \
  "GWT_SETUP='print -r -- from-string >> $log'" \
  'gwt_setup() { print -r -- from-function >> '"$log"' }'
run_gwt setup
assert_content "$log" "from-function" "setup: gwt_setup wins over GWT_SETUP"

# gwt_step caches on the watched file
: > $log
write_gwtrc "$repo" \
  'gwt_setup() { gwt_step deps --watch package-lock.json -- sh -c "echo ran >> '"$log"'" }'
run_gwt setup
assert_eq 1 "$(grep -c ran $log)" "gwt_step: runs the first time"
run_gwt setup
assert_eq 1 "$(grep -c ran $log)" "gwt_step: skips while the watched file is unchanged"
assert_err_has "unchanged, skipping" "gwt_step: says why it skipped"

print -r -- '{"v":2}' > "$wt/package-lock.json"
run_gwt setup
assert_eq 2 "$(grep -c ran $log)" "gwt_step: reruns when the watched file changes"

print -r -- '{"v":3}' > "$wt/package-lock.json"
run_gwt setup --force
assert_eq 3 "$(grep -c ran $log)" "gwt_step: --force ignores the cache"
run_gwt setup
assert_eq 3 "$(grep -c ran $log)" "gwt_step: --force still records the new hash"

# npm rewrites the very lockfile it is watched on, so the state to record is what
# the command left behind, not what was there before it ran
: > $log
print -r -- v1 > "$wt/lock.txt"
write_gwtrc "$repo" \
  'gwt_setup() { gwt_step rewrite --watch lock.txt -- sh -c "echo ran >> '"$log"'; echo rewritten > lock.txt" }'
run_gwt setup
assert_eq 1 "$(grep -c ran $log)" "gwt_step: runs a step that rewrites what it watches"
run_gwt setup
assert_eq 1 "$(grep -c ran $log)" "gwt_step: records the state the command left behind"

# state lives in the worktree's own git dir, so git removes it with the worktree
state="$(git -C "$wt" rev-parse --absolute-git-dir)/gwt-state"
assert_exists "$state/deps" "gwt_step: records state in the worktree git dir"
[[ "$state" == *"/worktrees/wt-feat-a/"* ]] \
  && _ok "gwt_step: state is under .git/worktrees/<name>" \
  || _fail "gwt_step: state is under .git/worktrees/<name>" "got $state"

# no --watch means no cache
: > $log
write_gwtrc "$repo" \
  'gwt_setup() { gwt_step always -- sh -c "echo ran >> '"$log"'" }'
run_gwt setup
run_gwt setup
assert_eq 2 "$(grep -c ran $log)" "gwt_step: a step with no --watch always runs"

# a failed step records nothing, so it is retried
: > $log
write_gwtrc "$repo" \
  'gwt_setup() { gwt_step flaky --watch package-lock.json -- sh -c "echo tried >> '"$log"'; exit 1" }'
run_gwt setup
assert_rc 51 "setup: reports a failing step"
run_gwt setup
assert_eq 2 "$(grep -c tried $log)" "gwt_step: a failed step is not cached"

# usage errors
write_gwtrc "$repo" 'gwt_setup() { gwt_step noargs }'
run_gwt setup
assert_rc 51 "gwt_step: a step with no command fails"

cd /
gwt_test_done
