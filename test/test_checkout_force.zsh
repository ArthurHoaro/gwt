#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "checkout -f"

repo="$(mk_repo)"

# without -f, a held branch is refused and nothing moves
mk_branch "$repo" held-a
wt="$(mk_worktree "$repo" held-a)"
cd "$repo"
run_gwt checkout held-a
assert_rc 31 "checkout: refuses a branch held by a worktree"
assert_exists "$wt" "checkout: worktree survives refusal"
assert_eq main "$(git -C "$repo" symbolic-ref --short HEAD)" "checkout: HEAD unchanged on refusal"
assert_err_has "gwt checkout -f" "checkout: hints at -f"

# -f removes the holder and checks the branch out here
run_gwt checkout -f held-a
assert_rc 0 "checkout -f: succeeds"
assert_missing "$wt" "checkout -f: holder worktree removed"
assert_unregistered "$repo" "$wt" "checkout -f: holder unregistered"
assert_eq held-a "$(git -C "$repo" symbolic-ref --short HEAD)" "checkout -f: branch checked out here"
assert_branch "$repo" held-a "checkout -f: branch NOT deleted"
git -C "$repo" checkout -q main

# -f discards a dirty holder, but says so first
mk_branch "$repo" dirty-b
wt="$(mk_worktree "$repo" dirty-b)"
print -r -- "uncommitted" > "$wt/scratch.txt"
cd "$repo"
run_gwt checkout -f dirty-b
assert_rc 0 "checkout -f: removes a dirty holder"
assert_err_has "uncommitted change" "checkout -f: warns about losing changes"
assert_missing "$wt" "checkout -f: dirty holder removed"
git -C "$repo" checkout -q main

# already on the branch: nothing to remove
mk_branch "$repo" inside-b
wt="$(mk_worktree "$repo" inside-b)"
cd "$wt"
run_gwt checkout -f inside-b
assert_rc 0 "checkout -f: already on that branch is a no-op"
assert_exists "$wt" "checkout -f: no-op leaves the worktree alone"
cd "$repo"; git -C "$repo" worktree remove --force "$wt"

# A nested worktree is the only way to stand inside a holder without being on its
# branch; -f must refuse rather than delete the tree under your feet.
mk_branch "$repo" outer-b
mk_branch "$repo" other-b
outer="$(mk_worktree "$repo" outer-b)"
nested="$outer/nested"
git -C "$repo" worktree add -q "$nested" other-b
cd "$nested"
run_gwt checkout -f outer-b
assert_rc 27 "checkout -f: refuses to remove the holder you stand inside"
assert_exists "$outer" "checkout -f: holder survives that refusal"
assert_exists "$nested" "checkout -f: the tree under your feet survives"
cd "$repo"
git -C "$repo" worktree remove --force "$nested"
git -C "$repo" worktree remove --force "$outer"

# refuses to drop the main repo's own checkout
mk_branch "$repo" mainheld-b
cd "$repo"; git -C "$repo" checkout -q mainheld-b
wt2="$(mk_worktree "$repo" other-b)"
cd "$wt2"
run_gwt checkout -f mainheld-b
assert_rc 26 "checkout -f: refuses a branch held by the main repo"
assert_exists "$repo/README" "checkout -f: main repo untouched"
cd "$repo"; git -C "$repo" checkout -q main; git -C "$repo" worktree remove "$wt2"

# argument and lookup failures destroy nothing
run_gwt checkout
assert_rc 25 "checkout: missing branch argument"
run_gwt checkout -f no-such-branch
assert_rc 29 "checkout -f: unknown branch"
assert_eq main "$(git -C "$repo" symbolic-ref --short HEAD)" "checkout -f: HEAD unchanged on unknown branch"

cd /
gwt_test_done
