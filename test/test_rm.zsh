#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "rm"

repo="$(mk_repo)"

# merged branch: worktree and branch both go
mk_branch "$repo" merged-a
wt="$(mk_worktree "$repo" merged-a)"
cd "$repo"
run_gwt rm merged-a
assert_rc 0 "rm: merged branch succeeds"
assert_missing "$wt" "rm: worktree directory removed"
assert_unregistered "$repo" "$wt" "rm: worktree unregistered"
assert_no_branch "$repo" merged-a "rm: merged branch deleted"

# unmerged branch: worktree goes, branch is kept
mk_unmerged_branch "$repo" unmerged-a
wt="$(mk_worktree "$repo" unmerged-a)"
cd "$repo"
run_gwt rm unmerged-a
assert_rc 0 "rm: unmerged branch succeeds"
assert_missing "$wt" "rm: unmerged worktree removed"
assert_branch "$repo" unmerged-a "rm: unmerged branch NOT deleted"
assert_err_has "not fully merged" "rm: warns branch was kept"

# dirty worktree: git refuses, and nothing is lost
mk_branch "$repo" dirty-a
wt="$(mk_worktree "$repo" dirty-a)"
print -r -- "uncommitted" > "$wt/scratch.txt"
cd "$repo"
run_gwt rm dirty-a
assert_rc 20 "rm: dirty worktree refused"
assert_exists "$wt/scratch.txt" "rm: uncommitted file survives"
assert_registered "$repo" "$wt" "rm: dirty worktree still registered"
assert_branch "$repo" dirty-a "rm: branch survives a refused removal"
rm -f "$wt/scratch.txt"; git -C "$repo" worktree remove "$wt"

# refuses from inside the worktree
mk_branch "$repo" inside-a
wt="$(mk_worktree "$repo" inside-a)"
cd "$wt"
run_gwt rm inside-a
assert_rc 17 "rm: refuses from inside the worktree"
assert_exists "$wt" "rm: worktree survives refusal from inside"
assert_branch "$repo" inside-a "rm: branch survives refusal from inside"
cd "$repo"; git -C "$repo" worktree remove "$wt"

# refuses to delete the branch checked out where you stand
mk_branch "$repo" current-a
cd "$repo"; git -C "$repo" checkout -q current-a
run_gwt rm current-a
assert_rc 23 "rm: refuses branch checked out in the main repo"
assert_branch "$repo" current-a "rm: current branch survives"
assert_exists "$repo/README" "rm: main repo untouched"
git -C "$repo" checkout -q main

# no worktree directory
mk_branch "$repo" nowt-a
cd "$repo"
run_gwt rm nowt-a
assert_rc 19 "rm: reports missing worktree directory"
assert_branch "$repo" nowt-a "rm: branch survives when worktree is absent"

# missing argument destroys nothing
cd "$repo"
run_gwt rm
assert_rc 16 "rm: missing branch argument"

# slashed branch names: prune empty parents but never $BASE/$REPO
mk_branch "$repo" feat/nested
wt="$(mk_worktree "$repo" feat/nested)"
cd "$repo"
run_gwt rm feat/nested
assert_rc 0 "rm: slashed branch name succeeds"
assert_missing "$wt" "rm: nested worktree removed"
assert_missing "$GWT_BASE/${repo:t}/wt-feat" "rm: emptied parent directory pruned"
assert_exists "$GWT_BASE/${repo:t}" "rm: repo worktree root NOT pruned"

cd /
gwt_test_done
