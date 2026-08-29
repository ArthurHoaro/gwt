# Test harness: fixtures, assertions, and the sandbox guard.
# Every test runs against throwaway repos in a temp dir. See the guard in gwt_test_init.

# %x is the file being sourced. $0 would be the *function* name at call time,
# which resolves against the caller's cwd instead of this directory.
typeset -g GWT_TEST_HOME="${${(%):-%x}:A:h}"

typeset -g GWT_TEST_N=0 GWT_TEST_FAILED=0
typeset -g GWT_TEST_ROOT GWT_TEST_NAME
typeset -g GWT_RC GWT_OUT GWT_ERR

gwt_test_init() {
  GWT_TEST_NAME="$1"
  GWT_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gwt-test.XXXXXXXX")"

  # These tests call `git worktree remove --force` and `git branch -d`. If the sandbox
  # is not a temp dir we created ourselves, they must not run at all.
  [[ -d "$GWT_TEST_ROOT" ]] || { print -ru2 -- "FATAL: mktemp failed"; exit 99 }
  _gwt_test_is_sandbox "$GWT_TEST_ROOT" || {
    print -ru2 -- "FATAL: sandbox $GWT_TEST_ROOT is not a fresh temp dir; refusing to run"
    exit 99
  }

  export GWT_BASE="$GWT_TEST_ROOT/trees"
  export GIT_CONFIG_NOSYSTEM=1
  export HOME="$GWT_TEST_ROOT/home"
  unset XDG_CONFIG_HOME XDG_STATE_HOME
  mkdir -p "$HOME"

  source "$GWT_TEST_HOME/../gwt.plugin.zsh"
}

# The name prefix ties the path to our own mktemp template, so neither the guard
# nor the cleanup can ever match a directory we did not create.
_gwt_test_is_sandbox() {
  setopt local_options extended_glob
  local d root="$1"
  local -a allowed=(/tmp /var/tmp)
  [[ -n "$TMPDIR" ]] && allowed+=("${TMPDIR:A}")
  for d in $allowed; do
    [[ "$root" == "$d"/gwt-test.[A-Za-z0-9]## ]] && return 0
  done
  return 1
}

gwt_test_cleanup() {
  [[ -n "$GWT_TEST_KEEP" ]] && { print -ru2 -- "kept: $GWT_TEST_ROOT"; return }
  _gwt_test_is_sandbox "$GWT_TEST_ROOT" && rm -rf "$GWT_TEST_ROOT"
}

gwt_test_done() {
  print -r -- "# $GWT_TEST_NAME: $((GWT_TEST_N - GWT_TEST_FAILED))/$GWT_TEST_N passed"
  (( GWT_TEST_FAILED == 0 ))
}

# --- fixtures -------------------------------------------------------------

mk_repo() {
  local name="${1:-repo}"
  local origin="$GWT_TEST_ROOT/$name.git" main="$GWT_TEST_ROOT/$name"
  git init -q -b main --bare "$origin"
  git clone -q "$origin" "$main" 2>/dev/null
  git -C "$main" config user.email test@example.invalid
  git -C "$main" config user.name test
  git -C "$main" config commit.gpgsign false
  print -r -- "seed" > "$main/README"
  git -C "$main" add -A
  git -C "$main" commit -qm init
  git -C "$main" push -q -u origin main
  print -r -- "$main"
}

# Branch pointing at main: `git branch -d` considers it merged.
mk_branch() { git -C "$1" branch "$2" }

# Branch with a commit of its own: `git branch -d` must refuse it.
mk_unmerged_branch() {
  local repo="$1" name="$2" stage="$GWT_TEST_ROOT/.stage"
  git -C "$repo" worktree add -q -b "$name" "$stage" main
  print -r -- "work" > "$stage/$name-work.txt"
  git -C "$stage" add -A
  git -C "$stage" commit -qm "work on $name"
  git -C "$repo" worktree remove "$stage"
}

wt_path() { print -r -- "$GWT_BASE/${1:t}/wt-$2" }

# Gitignored state a worktree might inherit: two config files, a heavy dep dir,
# and a build dir with one subdirectory worth excluding.
mk_carry_fixture() {
  local repo="$1"
  mkdir -p "$repo"/{.next/cache,.next/server,node_modules/pkg,config}
  print -r -- "main-cache"  > "$repo/.next/cache/big.js"
  print -r -- "main-server" > "$repo/.next/server/s.js"
  print -r -- "main-dep"    > "$repo/node_modules/pkg/p.js"
  print -r -- "MAIN_ENV"    > "$repo/.env"
  print -r -- "MAIN_LOCAL"  > "$repo/.env.local"
  print -r -- "tracked"     > "$repo/config/settings.json"
  printf '%s\n' 'node_modules' '.next' '.env*' > "$repo/.gitignore"
  git -C "$repo" add .gitignore config/settings.json
  git -C "$repo" commit -qm fixture
}

write_gwtrc()     { local repo="$1"; shift; printf '%s\n' "$@" > "$repo/.gwtrc" }
write_user_rc()   { local repo="$1"; shift; mkdir -p "$HOME/.config/gwt/${repo:t}"; printf '%s\n' "$@" > "$HOME/.config/gwt/${repo:t}/rc" }
write_global_rc() { mkdir -p "$HOME/.config/gwt"; printf '%s\n' "$@" > "$HOME/.config/gwt/rc" }

write_include() { local repo="$1"; shift; printf '%s\n' "$@" > "$repo/.worktreeinclude" }

write_user_include() {
  local repo="$1"; shift
  mkdir -p "$HOME/.config/gwt/${repo:t}"
  printf '%s\n' "$@" > "$HOME/.config/gwt/${repo:t}/worktreeinclude"
}

mk_worktree() {
  local repo="$1" branch="$2" p
  p="$(wt_path "$repo" "$branch")"
  mkdir -p "${p:h}"
  git -C "$repo" worktree add -q "$p" "$branch"
  print -r -- "$p"
}

# Fixtures use plain git, never gwt, so setup never depends on the code under test.
run_gwt() {
  gwt "$@" >"$GWT_TEST_ROOT/.stdout" 2>"$GWT_TEST_ROOT/.stderr"
  GWT_RC=$?
  GWT_OUT="$(<"$GWT_TEST_ROOT/.stdout")"
  GWT_ERR="$(<"$GWT_TEST_ROOT/.stderr")"
}

# --- assertions -----------------------------------------------------------

_ok()   { (( GWT_TEST_N++ )); print -r -- "ok $GWT_TEST_N - $1" }
_fail() { (( GWT_TEST_N++, GWT_TEST_FAILED++ )); print -r -- "not ok $GWT_TEST_N - $1"; print -r -- "  $2" }

assert_rc() {
  local want="$1" desc="$2"
  (( GWT_RC == want )) && { _ok "$desc"; return }
  _fail "$desc" "expected rc $want, got $GWT_RC; stderr: ${GWT_ERR//$'\n'/ | }"
}

assert_exists() { [[ -e "$1" ]] && _ok "$2" || _fail "$2" "missing: $1" }
assert_missing() { [[ ! -e "$1" ]] && _ok "$2" || _fail "$2" "should be gone: $1" }

assert_branch() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2" \
    && _ok "$3" || _fail "$3" "branch '$2' should exist"
}
assert_no_branch() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2" \
    && _fail "$3" "branch '$2' should be gone" || _ok "$3"
}

assert_registered() {
  git -C "$1" worktree list --porcelain | grep -qxF "worktree $2" \
    && _ok "$3" || _fail "$3" "worktree not registered: $2"
}
assert_unregistered() {
  git -C "$1" worktree list --porcelain | grep -qxF "worktree $2" \
    && _fail "$3" "worktree still registered: $2" || _ok "$3"
}

assert_content() {
  local path="$1" want="$2" desc="$3"
  [[ -f "$path" ]] || { _fail "$desc" "missing file: $path"; return }
  local got="$(<$path)"
  [[ "$got" == "$want" ]] && _ok "$desc" || _fail "$desc" "expected '$want', got '$got'"
}

assert_out_has() { [[ "$GWT_OUT" == *"$1"* ]] && _ok "$2" || _fail "$2" "stdout lacked '$1': ${GWT_OUT//$'\n'/ | }" }

assert_eq() { [[ "$1" == "$2" ]] && _ok "$3" || _fail "$3" "expected '$1', got '$2'" }
assert_err_has() { [[ "$GWT_ERR" == *"$1"* ]] && _ok "$2" || _fail "$2" "stderr lacked '$1': ${GWT_ERR//$'\n'/ | }" }

# Must be set here, at the top level of the sourcing script: a trap set inside a
# function is local to that function and would fire the moment init returned.
trap gwt_test_cleanup EXIT INT TERM
