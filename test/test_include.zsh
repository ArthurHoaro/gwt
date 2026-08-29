#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "include"

repo="$(mk_repo)"
mk_carry_fixture "$repo"
cd "$repo"

# no .worktreeinclude: the pre-Phase-1 rules, which skip heavy build dirs
run_gwt include
assert_rc 0 "include: succeeds without a .worktreeinclude"
assert_out_has "include file: none" "include: reports the fallback"
assert_out_has ".env" "include: fallback carries gitignored config"
[[ "$GWT_OUT" == *node_modules* ]] \
  && _fail "include: fallback skips node_modules" "node_modules was listed" \
  || _ok "include: fallback skips node_modules"

# with a file, the allowlist decides
write_include "$repo" '.env' '.env*.local' 'node_modules' '.next' '!.next/cache' 'config/settings.json'
run_gwt include
assert_rc 0 "include: succeeds with a .worktreeinclude"
assert_out_has ".worktreeinclude" "include: names the resolved file"
assert_out_has "node_modules" "include: allowlist carries node_modules"
assert_out_has ".next/cache" "include: reports the pruned path"
assert_out_has "config/settings.json" "include: warns about the tracked entry"
assert_out_has "tracked by git" "include: explains why it is skipped"

# dry run must not touch anything
assert_content "$repo/.env" MAIN_ENV "include: leaves the main checkout alone"
assert_missing "$GWT_BASE" "include: creates no worktrees"

# include inspects; it never writes. Registration belongs to the commands that carry.
ex="$repo/.git/info/exclude"
assert_eq 0 "$(grep -cxF '/.worktreeinclude' $ex)" "include: writes nothing to info/exclude"

# per-repo user config is the second choice, the repo file the first
rm "$repo/.worktreeinclude"
write_user_include "$repo" '.env'
run_gwt include
assert_out_has ".config/gwt/${repo:t}/worktreeinclude" "include: falls back to user config"
write_include "$repo" 'node_modules'
run_gwt include
assert_out_has "$repo/.worktreeinclude" "include: repo file wins over user config"
[[ "$GWT_OUT" == *".env"* ]] \
  && _fail "include: repo file fully replaces user config" "user-config entry still applied" \
  || _ok "include: repo file fully replaces user config"

# an allowlist that matches nothing
write_include "$repo" 'no-such-path'
run_gwt include
assert_rc 0 "include: succeeds when nothing matches"
assert_out_has "carry: nothing" "include: says so plainly"

cd /
gwt_test_done
