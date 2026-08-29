#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "reset -d"

repo="$(mk_repo)"

# plain reset only moves you; it never removes anything
mk_branch "$repo" keep-a
wt="$(mk_worktree "$repo" keep-a)"
cd "$wt"
run_gwt reset
assert_rc 0 "reset: succeeds"
assert_eq "$repo" "$PWD" "reset: back at the main repo root"
assert_exists "$wt" "reset: worktree NOT removed without -d"
assert_branch "$repo" keep-a "reset: branch untouched"

# -d from a merged worktree removes the tree and the branch
cd "$wt"
run_gwt reset -d
assert_rc 0 "reset -d: succeeds"
assert_eq "$repo" "$PWD" "reset -d: back at the main repo root"
assert_missing "$wt" "reset -d: worktree removed"
assert_no_branch "$repo" keep-a "reset -d: merged branch deleted"

# -d keeps an unmerged branch
mk_unmerged_branch "$repo" keep-b
wt="$(mk_worktree "$repo" keep-b)"
cd "$wt"
run_gwt reset -d
assert_rc 0 "reset -d: succeeds on an unmerged branch"
assert_missing "$wt" "reset -d: unmerged worktree removed"
assert_branch "$repo" keep-b "reset -d: unmerged branch NOT deleted"

# -d from the main repo must not remove the main repo
cd "$repo"
run_gwt reset -d
assert_rc 0 "reset -d: no-op in the main repo"
assert_exists "$repo/README" "reset -d: main repo NOT removed"
assert_exists "$repo/.git" "reset -d: main git dir intact"
assert_err_has "not inside a linked worktree" "reset -d: says there was nothing to remove"

# -d on a detached HEAD removes the path directly
p="$(wt_path "$repo" detached-c)"
mkdir -p "${p:h}"
git -C "$repo" worktree add -q --detach "$p" main
cd "$p"
run_gwt reset -d
assert_rc 0 "reset -d: succeeds on a detached HEAD"
assert_eq "$repo" "$PWD" "reset -d: back at the main repo root from detached HEAD"
assert_missing "$p" "reset -d: detached worktree removed"

# a dirty worktree is refused, and you still end up back at the root
mk_branch "$repo" dirty-c
wt="$(mk_worktree "$repo" dirty-c)"
print -r -- "uncommitted" > "$wt/scratch.txt"
cd "$wt"
run_gwt reset -d
assert_rc 20 "reset -d: dirty worktree refused"
assert_eq "$repo" "$PWD" "reset -d: you are moved out even when removal fails"
assert_exists "$wt/scratch.txt" "reset -d: uncommitted file survives"
assert_branch "$repo" dirty-c "reset -d: branch survives a refused removal"

cd /
gwt_test_done
