#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "serve-run"

launcher="$GWT_TEST_HOME/../libexec/gwt-serve-run"
repo="$(mk_repo)"
mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"
state="$HOME/.local/state/gwt/${repo:t}"

run_launcher() {
  GWT_OUT="$("$launcher" "$@" 2>"$GWT_TEST_ROOT/.stderr")"
  GWT_RC=$?
  GWT_ERR="$(<$GWT_TEST_ROOT/.stderr)"
}

run_launcher
assert_rc 2 "launcher: refuses with no repo argument"

run_launcher "${repo:t}"
assert_rc 3 "launcher: refuses with no target recorded"

mkdir -p "$state"
print -r -- "$GWT_TEST_ROOT/gone" > "$state/target"
run_launcher "${repo:t}"
assert_rc 4 "launcher: refuses a target that is not a directory"

print -r -- "$GWT_TEST_ROOT" > "$state/target"
run_launcher "${repo:t}"
assert_rc 5 "launcher: refuses a target that is not a git worktree"

print -r -- "$wt" > "$state/target"
run_launcher "${repo:t}"
assert_rc 7 "launcher: refuses when there is no .gwtrc"

write_gwtrc "$repo" 'GWT_SERVER_PORT=9000'
run_launcher "${repo:t}"
assert_rc 8 "launcher: refuses when GWT_SERVER is unset"

# It runs unattended under systemd, so the tracked-config refusal matters most here.
write_gwtrc "$repo" "GWT_SERVER='print -r -- PWNED'"
git -C "$repo" add -f .gwtrc
git -C "$repo" commit -qm "track the rc"
run_launcher "${repo:t}"
assert_rc 6 "launcher: refuses a tracked .gwtrc"
assert_eq "" "$GWT_OUT" "launcher: the tracked server command never ran"
assert_err_has "git tracks it" "launcher: says why it refused"

git -C "$repo" rm -q --cached .gwtrc
git -C "$repo" commit -qm untrack
write_gwtrc "$repo" "GWT_SERVER='print -r -- \"up \$GWT_REPO \${GWT_WORKTREE:t} \$GWT_BRANCH \${PWD:t}\"'"
run_launcher "${repo:t}"
assert_rc 0 "launcher: runs the server command"
assert_eq "up ${repo:t} wt-feat-a feat-a wt-feat-a" "$GWT_OUT" "launcher: execs it in the worktree with the hook env set"

cd /
gwt_test_done
