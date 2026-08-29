#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "prune"

repo="$(mk_repo)"
cd "$repo"

mk_branch "$repo" merged-a                  # points at main: merged
wt_merged="$(mk_worktree "$repo" merged-a)"
mk_unmerged_branch "$repo" busy-a           # ahead of main, no upstream
wt_busy="$(mk_worktree "$repo" busy-a)"
mk_gone_branch "$repo" gone-a               # upstream deleted on origin
wt_gone="$(mk_worktree "$repo" gone-a)"

# criteria are not optional
run_gwt prune
assert_rc 72 "prune: refuses without --merged"
assert_exists "$wt_merged" "prune: removes nothing without criteria"

# preview
run_gwt prune --merged -n
assert_rc 0 "prune -n: succeeds"
assert_err_has "merged-a" "prune -n: lists the merged branch"
assert_err_has "gone-a" "prune -n: lists the branch gone on origin"
assert_err_has "would remove" "prune -n: labels the report as hypothetical"
[[ "$GWT_ERR" == *busy-a* ]] \
  && _fail "prune -n: leaves an unmerged branch alone" "busy-a was listed" \
  || _ok "prune -n: leaves an unmerged branch alone"
[[ "$GWT_ERR" == *"remove  main"* ]] \
  && _fail "prune -n: never lists the default branch" "main was listed" \
  || _ok "prune -n: never lists the default branch"
assert_exists "$wt_merged" "prune -n: changes nothing"
assert_exists "$wt_gone" "prune -n: really changes nothing"

# declining the prompt
run_gwt_in n prune --merged
assert_rc 0 "prune: declining is not an error"
assert_err_has "aborted" "prune: says it aborted"
assert_exists "$wt_merged" "prune: declining removes nothing"

# a non-interactive caller with nothing on stdin aborts instead of hanging
mk_branch "$repo" merged-z
wt_z="$(mk_worktree "$repo" merged-z)"
gwt prune --merged >/dev/null 2>&1 </dev/null
assert_eq 0 "$?" "prune: EOF on stdin is not an error"
assert_exists "$wt_z" "prune: EOF on stdin removes nothing"
git -C "$repo" worktree remove "$wt_z"

# accepting it
run_gwt_in y prune --merged
assert_rc 0 "prune: succeeds"
assert_missing "$wt_merged" "prune: removes the merged worktree"
assert_missing "$wt_gone" "prune: removes the worktree gone on origin"
assert_exists "$wt_busy" "prune: keeps the unmerged worktree"
assert_no_branch "$repo" merged-a "prune: deletes the merged branch"
assert_branch "$repo" gone-a "prune: keeps an unmerged branch whose upstream vanished"
assert_err_has "pruned 2 worktree(s)" "prune: reports the count"

# nothing left to do
run_gwt prune --merged -n
assert_rc 0 "prune: succeeds when there is nothing to prune"
assert_err_has "nothing to prune" "prune: says so"

# -f skips the prompt entirely
mk_branch "$repo" merged-b
wt_b="$(mk_worktree "$repo" merged-b)"
run_gwt prune --merged -f
assert_rc 0 "prune -f: succeeds without a prompt"
assert_missing "$wt_b" "prune -f: removed it"

# the worktree you are standing in is skipped, not failed
mk_branch "$repo" merged-c
wt_c="$(mk_worktree "$repo" merged-c)"
mk_branch "$repo" merged-d
wt_d="$(mk_worktree "$repo" merged-d)"
cd "$wt_c"
run_gwt prune --merged -f
assert_rc 0 "prune: succeeds while you stand in a candidate"
assert_exists "$wt_c" "prune: skips the worktree you are in"
assert_missing "$wt_d" "prune: still removes the others"
assert_err_has "you are in it" "prune: says why it skipped"

# the main checkout is never a candidate
cd "$repo"
assert_exists "$repo/README" "prune: main checkout untouched"
assert_branch "$repo" main "prune: default branch untouched"

# Both exclusions matter only when the main checkout is NOT on the default branch:
# a repo sitting on a feature branch with the default branch in a linked worktree.
repo3="$(mk_repo third)"
cd "$repo3"
mk_branch "$repo3" side-a
git -C "$repo3" checkout -q side-a
wt_default="$(mk_worktree "$repo3" main)"
# Stand somewhere that is not a candidate, so neither exclusion is masked by the
# "you are in it" skip.
mk_unmerged_branch "$repo3" neutral
wt_neutral="$(mk_worktree "$repo3" neutral)"
cd "$wt_neutral"
run_gwt prune --merged -n
assert_rc 0 "prune: succeeds with the default branch in a worktree"
[[ "$GWT_ERR" == *"remove  side-a"* ]] \
  && _fail "prune: never lists the main checkout" "side-a, the main checkout, was listed" \
  || _ok "prune: never lists the main checkout"
[[ "$GWT_ERR" == *"remove  main"* ]] \
  && _fail "prune: never lists the default branch worktree" "main was listed" \
  || _ok "prune: never lists the default branch worktree"
assert_exists "$wt_default" "prune: the default branch worktree survives"
assert_exists "$repo3/README" "prune: the main checkout survives"

cd /
gwt_test_done
