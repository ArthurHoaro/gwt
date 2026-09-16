#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "pick-tree"

repo="$(mk_repo)"
mk_carry_fixture "$repo"
mk_branch "$repo" feat-a
wt_a="$(mk_worktree "$repo" feat-a)"
mk_branch "$repo" feat-b
wt_b="$(mk_worktree "$repo" feat-b)"

row_for() {
  local wt="$1" r
  for r in ${(f)"$(_gwt_pickable_rows "$repo" "${repo:t}" $2)"}; do
    [[ "$r" == *$'\t'"$wt"$'\t'* ]] && { print -r -- "$r"; return 0 }
  done
  return 1
}
paths_offered() {
  local r out=()
  for r in ${(f)"$(_gwt_pickable_rows "$repo" "${repo:t}" $1)"}; do
    out+=( "${${r#*$'\t'}%%$'\t'*}" )
  done
  print -r -- " ${out[*]} "
}

# --- what the picker offers -----------------------------------------------

cd "$repo"
offered="$(paths_offered)"
[[ "$offered" != *" $repo "* ]] \
  && _ok "rows: the main checkout is never offered" \
  || _fail "rows: the main checkout is never offered" "got $offered"
[[ "$offered" == *" $wt_a "* && "$offered" == *" $wt_b "* ]] \
  && _ok "rows: every linked worktree is offered" \
  || _fail "rows: every linked worktree is offered" "got $offered"

cd "$wt_a"
offered="$(paths_offered)"
[[ "$offered" != *" $wt_a "* ]] \
  && _ok "rows: the worktree you are standing in is left out" \
  || _fail "rows: the worktree you are standing in is left out" "got $offered"
[[ "$offered" == *" $wt_b "* ]] \
  && _ok "rows: the others are still offered" \
  || _fail "rows: the others are still offered" "got $offered"

# rm names a branch, so it cannot be pointed at a detached worktree
det="$GWT_BASE/${repo:t}/wt-detached"
mkdir -p "${det:h}"
git -C "$repo" worktree add -q --detach "$det" main
cd "$repo"
[[ "$(paths_offered)" == *" $det "* ]] \
  && _ok "rows: a detached worktree is offered when a path is enough" \
  || _fail "rows: a detached worktree is offered when a path is enough" "got $(paths_offered)"
[[ "$(paths_offered branch)" != *" $det "* ]] \
  && _ok "rows: a detached worktree is left out when a branch is needed" \
  || _fail "rows: a detached worktree is left out when a branch is needed" "got $(paths_offered branch)"
git -C "$repo" worktree remove "$det"

# --- gwt rm ---------------------------------------------------------------

cd "$repo"
row_b="$(row_for "$wt_b" branch)"
function _gwt_pick { print -r -- "$row_b" }
run_gwt rm
assert_rc 0 "rm: succeeds with no argument"
assert_unregistered "$repo" "$wt_b" "rm: removes the picked worktree"
assert_missing "$wt_b" "rm: the picked directory is gone"
assert_no_branch "$repo" feat-b "rm: the picked branch was merged, so it went too"
assert_registered "$repo" "$wt_a" "rm: leaves the others alone"

# the picked branch goes through every refusal the named form has
cd "$wt_a"
row_a="$(cd "$repo" && row_for "$wt_a" branch)"
function _gwt_pick { print -r -- "$row_a" }
run_gwt rm
assert_rc 16 "rm: the only worktree left is the one you stand in, so there is nothing to pick"
assert_registered "$repo" "$wt_a" "rm: nothing was removed"

cd "$repo"
function _gwt_pick { return 130 }
run_gwt rm
assert_rc 0 "rm: cancelling the picker is not an error"
assert_registered "$repo" "$wt_a" "rm: cancelling removes nothing"

function _gwt_pick { print -r -- "" }
run_gwt rm
assert_rc 0 "rm: an empty choice is not an error"
assert_registered "$repo" "$wt_a" "rm: an empty choice removes nothing"

function _gwt_pick { print -r -- "SHOULD-NOT-BE-USED" }
run_gwt rm feat-a
assert_rc 0 "rm <branch>: still removes what it was told to"
assert_unregistered "$repo" "$wt_a" "rm <branch>: ignores the picker"

# nothing left to pick
cd "$repo"
function _gwt_pick { print -r -- "SHOULD-NOT-BE-USED" }
run_gwt rm
assert_rc 16 "rm: says so when there is no worktree to pick"

# --- gwt sync -------------------------------------------------------------

mk_branch "$repo" feat-c
wt_c="$(mk_worktree "$repo" feat-c)"
cd "$repo"
row_c="$(row_for "$wt_c")"
function _gwt_pick { print -r -- "$row_c" }
run_gwt sync
assert_rc 0 "sync: succeeds from outside a worktree with no argument"
assert_content "$wt_c/.env" "MAIN_ENV" "sync: carried into the picked worktree"

# inside a worktree the picker stays out of the way
rm -f "$wt_c/.env"
cd "$wt_c"
function _gwt_pick { print -r -- "SHOULD-NOT-BE-USED" }
run_gwt sync
assert_rc 0 "sync: still means this worktree when you are in one"
assert_content "$wt_c/.env" "MAIN_ENV" "sync: carried into the worktree you stand in"

cd "$repo"
function _gwt_pick { return 130 }
rm -f "$wt_c/.env"
run_gwt sync
assert_rc 0 "sync: cancelling the picker is not an error"
assert_missing "$wt_c/.env" "sync: cancelling carries nothing"

git -C "$repo" worktree remove "$wt_c"
cd "$repo"
function _gwt_pick { print -r -- "SHOULD-NOT-BE-USED" }
run_gwt sync
assert_rc 40 "sync: says so when there is no worktree to pick"

cd /
gwt_test_done
