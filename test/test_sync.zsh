#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "sync"

repo="$(mk_repo)"
mk_carry_fixture "$repo"
write_include "$repo" '.env' '.env*.local' 'node_modules' '.next' '!.next/cache' 'config/settings.json'
mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"
cd "$repo"

# a stale copy is the case gwt sync exists for
print -r -- "STALE" > "$wt/.env.local"
print -r -- "SAME"  > "$wt/.env"
print -r -- "SAME"  > "$repo/.env"
run_gwt sync feat-a
assert_rc 0 "sync: succeeds"
assert_content "$wt/.env.local" MAIN_LOCAL "sync: refreshes a stale file"
assert_content "$wt/.env" SAME "sync: leaves an identical file alone"
assert_err_has "1 updated" "sync: counts only the file that actually drifted"

# a missing file is added
rm "$wt/.env.local"
run_gwt sync feat-a
assert_rc 0 "sync: succeeds with a missing file"
assert_content "$wt/.env.local" MAIN_LOCAL "sync: adds a missing file"

# a directory the worktree already owns is its own state
mkdir -p "$wt/node_modules/pkg"
print -r -- "worktree-dep" > "$wt/node_modules/pkg/p.js"
print -r -- "worktree-only" > "$wt/node_modules/pkg/extra.js"
run_gwt sync feat-a
assert_rc 0 "sync: succeeds with an existing directory"
assert_content "$wt/node_modules/pkg/p.js" worktree-dep "sync: does NOT replace a directory by default"
assert_exists "$wt/node_modules/pkg/extra.js" "sync: worktree-only file survives"
assert_err_has "--force to replace" "sync: says how to override"

# --force replaces it
run_gwt sync --force feat-a
assert_rc 0 "sync --force: succeeds"
assert_content "$wt/node_modules/pkg/p.js" main-dep "sync --force: replaces the directory"
assert_missing "$wt/node_modules/pkg/extra.js" "sync --force: worktree-only file is gone"

# negation still applies on sync
assert_exists "$wt/.next/server/s.js" "sync: carries the rest of a pruned directory"
assert_missing "$wt/.next/cache" "sync: honours the ! entry"

# -n reports without acting
print -r -- "STALE2" > "$wt/.env.local"
run_gwt sync -n feat-a
assert_rc 0 "sync -n: succeeds"
assert_content "$wt/.env.local" STALE2 "sync -n: changes nothing"
assert_err_has "would carry" "sync -n: labels the report as hypothetical"

# the main checkout is never a destination
assert_content "$repo/.env.local" MAIN_LOCAL "sync: main checkout untouched"
assert_missing "$repo/node_modules/pkg/extra.js" "sync: nothing written back to main"

# tracked files are never carried, so worktree edits to them survive
print -r -- "worktree-edit" > "$wt/config/settings.json"
run_gwt sync feat-a
assert_content "$wt/config/settings.json" worktree-edit "sync: never overwrites a tracked file"

# registration happens on a real carry
ex="$repo/.git/info/exclude"
assert_eq 1 "$(grep -cxF '/.worktreeinclude' $ex)" "sync: registers .worktreeinclude"
assert_eq 1 "$(grep -cxF '/.gwtrc' $ex)" "sync: registers .gwtrc"
run_gwt sync feat-a
assert_eq 1 "$(grep -cxF '/.worktreeinclude' $ex)" "sync: registration is idempotent"

# --all covers every worktree and never the main repo
mk_branch "$repo" feat-b
wt2="$(mk_worktree "$repo" feat-b)"
rm -f "$wt/.env" "$wt2/.env"
cd "$repo"
run_gwt sync --all
assert_rc 0 "sync --all: succeeds"
assert_exists "$wt/.env" "sync --all: reaches the first worktree"
assert_exists "$wt2/.env" "sync --all: reaches the second worktree"
assert_content "$repo/.env" SAME "sync --all: main checkout untouched"
print -r -- "$GWT_ERR" | grep -qx "${repo:t}:" \
  && _fail "sync --all: never targets the main repo" "main repo appeared as a sync target" \
  || _ok "sync --all: never targets the main repo"

# argument errors
run_gwt sync --all feat-a
assert_rc 43 "sync: --all rejects a branch argument"
run_gwt sync no-such-branch
assert_rc 41 "sync: unknown branch"
cd "$repo"
run_gwt sync
assert_rc 40 "sync: refuses to guess from the main repo"

# from inside a worktree, no argument needed
rm -f "$wt/.env"
cd "$wt"
run_gwt sync
assert_rc 0 "sync: works from inside a worktree"
assert_exists "$wt/.env" "sync: carried into the worktree you stand in"

cd /
gwt_test_done
