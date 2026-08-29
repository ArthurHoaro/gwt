#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "pick"

repo="$(mk_repo)"
mk_branch "$repo" feat-a
wt_a="$(mk_worktree "$repo" feat-a)"
mk_branch "$repo" feat-b
wt_b="$(mk_worktree "$repo" feat-b)"
cd "$repo"

# rows carry the display, the path and the branch, tab separated
rows=( ${(f)"$(_gwt_worktree_rows "$repo" "${repo:t}")"} )
assert_eq 3 "${#rows}" "rows: one per worktree including the main checkout"
row_b=""
for r in "${rows[@]}"; do [[ "$r" == *$'\t'"$wt_b"$'\t'* ]] && row_b="$r"; done
[[ -n "$row_b" ]] && _ok "rows: carry the worktree path" || _fail "rows: carry the worktree path" "no row for $wt_b"
assert_eq "feat-b" "${row_b##*$'\t'}" "rows: carry the branch"
[[ "${row_b%%$'\t'*}" == *wt-feat-b* ]] \
  && _ok "rows: the display field is the human-readable one" \
  || _fail "rows: the display field is the human-readable one" "got ${row_b%%$'\t'*}"

# the real picker, driven through a stub fzf that takes the first line
stub="$GWT_TEST_ROOT/bin"
mkdir -p "$stub"
cat > "$stub/fzf" <<'FZF'
#!/bin/sh
head -1
FZF
chmod +x "$stub/fzf"
PATH="$stub:$PATH"
rehash
picked="$(_gwt_pick "${rows[@]}")"
assert_eq "${rows[1]}" "$picked" "pick: fzf receives the rows and its choice comes back"

# bare `gwt go` cds to whatever the picker returned
function _gwt_pick { print -r -- "$row_b" }
cd "$repo"
run_gwt go
assert_rc 0 "go: succeeds with no argument"
assert_eq "$wt_b" "$PWD" "go: cds to the picked worktree"

# cancelling changes nothing
cd "$repo"
function _gwt_pick { return 130 }
run_gwt go
assert_rc 0 "go: cancelling the picker is not an error"
assert_eq "$repo" "$PWD" "go: cancelling leaves you where you were"

# an empty choice is also a no-op
function _gwt_pick { print -r -- "" }
run_gwt go
assert_rc 0 "go: an empty choice is not an error"
assert_eq "$repo" "$PWD" "go: an empty choice leaves you where you were"

# `gwt add` with no argument still fails; only `go` picks
run_gwt add
assert_rc 4 "add: still requires a branch argument"

# named `gwt go` is unaffected by the picker
function _gwt_pick { print -r -- "SHOULD-NOT-BE-USED"; return 0 }
cd "$repo"
run_gwt go feat-a
assert_rc 0 "go <branch>: still goes straight there"
assert_eq "$wt_a" "$PWD" "go <branch>: ignores the picker"

# no worktrees to choose from
cd /
repo2="$(mk_repo solo)"
cd "$repo2"
function _gwt_pick { return 1 }
rows2=( ${(f)"$(_gwt_worktree_rows "$repo2" solo)"} )
assert_eq 1 "${#rows2}" "rows: a repo with no linked worktrees has just the main checkout"

cd /
gwt_test_done
