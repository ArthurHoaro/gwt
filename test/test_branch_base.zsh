#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "branch-base"

repo="$(mk_repo)"

# main moves ahead on origin while the local checkout stays behind, so "based on the
# default branch" and "based on the local one" resolve to different commits.
print -r -- ahead > "$repo/ahead.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm "ahead on main"
git -C "$repo" push -q origin main
origin_tip="$(git -C "$repo" rev-parse origin/main)"
git -C "$repo" reset -q --hard HEAD~1
stale_tip="$(git -C "$repo" rev-parse HEAD)"

# a side branch with a commit of its own, to stand on
mk_unmerged_branch "$repo" side
side_tip="$(git -C "$repo" rev-parse side)"

tip_of() { git -C "$repo" rev-parse "refs/heads/$1" }
upstream_of() { git -C "$repo" for-each-ref --format='%(upstream:short)' "refs/heads/$1" }

cd "$repo"
git -C "$repo" checkout -q side

# --- the default: the project's default branch, not where you stand ---------

run_gwt add feat-a
assert_rc 0 "add: creates a new branch"
assert_eq "$origin_tip" "$(tip_of feat-a)" "add: a new branch starts at the default branch"
assert_err_has "branching 'feat-a' off origin/main" "add: says what it branched off"
assert_eq "" "$(upstream_of feat-a)" "add: a new branch does not adopt the base as its upstream"

cd "$repo"
run_gwt go feat-b
assert_eq "$origin_tip" "$(tip_of feat-b)" "go: creates a new branch the same way"

# --- -b still names the base --------------------------------------------------

cd "$repo"
run_gwt add -b side feat-c
assert_rc 0 "add -b: succeeds"
assert_eq "$side_tip" "$(tip_of feat-c)" "add -b: an explicit start point wins"

cd "$repo"
git -C "$repo" checkout -q main
run_gwt add -b HEAD feat-d
assert_eq "$stale_tip" "$(tip_of feat-d)" "add -b HEAD: still branches off where you stand"

# --- the repo can ask for git's own behaviour ---------------------------------

write_gwtrc "$repo" "GWT_NEW_BRANCH_BASE=HEAD"
cd "$repo"
git -C "$repo" checkout -q side
run_gwt add feat-e
assert_eq "$side_tip" "$(tip_of feat-e)" "rc: GWT_NEW_BRANCH_BASE=HEAD branches off the current branch"
[[ "$GWT_ERR" == *"branching 'feat-e'"* ]] \
  && _fail "rc: HEAD is git's own behaviour, and says nothing" "note was printed" \
  || _ok "rc: HEAD is git's own behaviour, and says nothing"

write_gwtrc "$repo" "GWT_NEW_BRANCH_BASE=side"
cd "$repo"
run_gwt add feat-f
assert_eq "$side_tip" "$(tip_of feat-f)" "rc: any other ref names the base"

# --- the environment covers repos that have no rc of their own ----------------

rm -f "$repo/.gwtrc"
cd "$repo"
GWT_NEW_BRANCH_BASE=side run_gwt add feat-g
assert_eq "$side_tip" "$(tip_of feat-g)" "env: GWT_NEW_BRANCH_BASE is the fallback"

write_gwtrc "$repo" "GWT_NEW_BRANCH_BASE=main"
cd "$repo"
GWT_NEW_BRANCH_BASE=side run_gwt add feat-h
assert_eq "$stale_tip" "$(tip_of feat-h)" "env: the repo's rc wins over the environment"

# --- branches that already exist are untouched by any of it -------------------

rm -f "$repo/.gwtrc"
cd "$repo"
git -C "$repo" checkout -q main
run_gwt add side
assert_rc 0 "add: an existing branch is checked out, not recreated"
assert_eq "$side_tip" "$(tip_of side)" "add: an existing branch keeps its own tip"

cd /
gwt_test_done
