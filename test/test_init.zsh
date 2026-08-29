#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "init"

# Answers are one per prompt, in order:
#   deps command, deps watch, extra-step name, dev server, port, write?
answers() { print -rl -- "$@" }

repo="$(mk_repo)"
cd "$repo"

# Nothing recognisable: every prompt starts blank, and declining everything still
# leaves a usable skeleton.
run_gwt_in "$(answers '' '' '' 'y')" init
assert_rc 0 "init: writes with no answers at all"
assert_exists "$repo/.gwtrc" "init: created .gwtrc"
[[ "$(<$repo/.gwtrc)" == *"# gwt_setup() {"* ]] \
  && _ok "init: an empty config still shows the gwt_setup shape" \
  || _fail "init: an empty config still shows the gwt_setup shape" "$(<$repo/.gwtrc)"

# ...and gwt can source what it wrote.
run_gwt setup
assert_rc 0 "init: the file it wrote is valid zsh"

# It refuses to clobber, and says how to.
run_gwt_in "$(answers '' '' '' 'y')" init
assert_rc 80 "init: refuses an existing .gwtrc"
assert_err_has "gwt init --force" "init: points at --force"

# Detection fills the defaults in, and blank answers accept them.
rm "$repo/.gwtrc"
cat > "$repo/package.json" <<'JSON'
{ "name": "demo", "scripts": { "dev": "next dev -p 4300" } }
JSON
: > "$repo/package-lock.json"
run_gwt_in "$(answers '' '' '' '' '' 'y')" init
assert_rc 0 "init: succeeds on a detected node repo"
assert_err_has "[npm install]" "init: proposes the package manager it found"
assert_err_has "[package-lock.json]" "init: watches the lockfile it found"
assert_err_has "[npm run dev]" "init: proposes the dev script it found"
assert_err_has "[4300]" "init: reads the port out of the dev script"

rc="$(<$repo/.gwtrc)"
[[ "$rc" == *"GWT_SERVER='npm run dev'"* ]] \
  && _ok "init: writes GWT_SERVER" || _fail "init: writes GWT_SERVER" "$rc"
[[ "$rc" == *"GWT_SERVER_PORT=4300"* ]] \
  && _ok "init: writes GWT_SERVER_PORT" || _fail "init: writes GWT_SERVER_PORT" "$rc"
[[ "$rc" == *"gwt_step deps --watch package-lock.json -- npm install"* ]] \
  && _ok "init: writes the deps step" || _fail "init: writes the deps step" "$rc"

# The values it wrote are the ones gwt reads back for the dev server.
assert_eq "npm run dev" "$(_gwt_config_value "$repo" "${repo:t}" GWT_SERVER)" \
  "init: GWT_SERVER round-trips through the config reader"
assert_eq "4300" "$(_gwt_config_value "$repo" "${repo:t}" GWT_SERVER_PORT)" \
  "init: GWT_SERVER_PORT round-trips through the config reader"

# Typed answers override the detected ones, and --force rewrites.
run_gwt_in "$(answers 'yarn install --frozen-lockfile' 'yarn.lock' '' 'yarn dev' '5173' 'y')" init --force
assert_rc 0 "init --force: rewrites an existing .gwtrc"
rc="$(<$repo/.gwtrc)"
[[ "$rc" == *"gwt_step deps --watch yarn.lock -- yarn install --frozen-lockfile"* ]] \
  && _ok "init: typed answers beat the detected defaults" || _fail "init: typed answers beat the detected defaults" "$rc"
[[ "$rc" == *"GWT_SERVER_PORT=5173"* ]] \
  && _ok "init: takes the typed port" || _fail "init: takes the typed port" "$rc"

# Extra steps: name, command, watch list. A blank name ends the loop.
run_gwt_in "$(answers '' '' 'db' './bin/seed.sh' 'schema.sql' '' '' '' 'y')" init --force
assert_rc 0 "init: accepts an extra step"
rc="$(<$repo/.gwtrc)"
[[ "$rc" == *"gwt_step db --watch schema.sql -- ./bin/seed.sh"* ]] \
  && _ok "init: writes the extra step" || _fail "init: writes the extra step" "$rc"

# A command with shell syntax cannot be bare words after --; it gets a zsh -c.
chained='print -r -- one > chained.txt && print -r -- two >> chained.txt'
run_gwt_in "$(answers "$chained" '' '' '' '' 'y')" init --force
rc="$(<$repo/.gwtrc)"
[[ "$rc" == *"-- zsh -c '$chained'"* ]] \
  && _ok "init: wraps a command containing shell syntax" || _fail "init: wraps a command containing shell syntax" "$rc"
run_gwt setup
assert_rc 0 "init: the wrapped command runs"
assert_content "$repo/chained.txt" $'one\ntwo' "init: the wrapping preserves what the command does"

# A port that is not a number is re-asked rather than written.
run_gwt_in "$(answers '' '' '' 'npm run dev' 'eight' '8080' 'y')" init --force
assert_rc 0 "init: recovers from a bad port"
assert_err_has "a port must be a number" "init: says why it re-asked"
[[ "$(<$repo/.gwtrc)" == *"GWT_SERVER_PORT=8080"* ]] \
  && _ok "init: keeps the corrected port" || _fail "init: keeps the corrected port" "$(<$repo/.gwtrc)"

# Declining the preview writes nothing at all.
cp "$repo/.gwtrc" "$GWT_TEST_ROOT/before"
run_gwt_in "$(answers 'echo nope' '' '' '' '' 'n')" init --force
assert_rc 82 "init: declining the preview is a cancel"
assert_content "$repo/.gwtrc" "$(<$GWT_TEST_ROOT/before)" "init: declining leaves the file untouched"

# Ctrl-D at any prompt is a cancel, not a half-written file.
rm "$repo/.gwtrc"
run_gwt_in "" init
assert_rc 82 "init: EOF at the first prompt cancels"
assert_missing "$repo/.gwtrc" "init: a cancel writes nothing"

# .gwtrc must never be committable by accident.
run_gwt_in "$(answers '' '' '' '' '' 'y')" init
excl="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
grep -qxF '/.gwtrc' "$excl" \
  && _ok "init: registers .gwtrc in info/exclude" || _fail "init: registers .gwtrc in info/exclude" "not in $excl"

# A tracked .gwtrc is one gwt would refuse to source; do not write over it either.
git -C "$repo" add -f .gwtrc
git -C "$repo" commit -qm "commit the rc"
run_gwt_in "$(answers '' '' '' '' '' 'y')" init --force
assert_rc 81 "init: refuses when git tracks .gwtrc"
assert_err_has "git rm --cached" "init: says how to untrack it"

# It runs from inside a worktree too, and writes to the main checkout.
git -C "$repo" rm -q --cached .gwtrc
git -C "$repo" commit -qm untrack
rm "$repo/.gwtrc"
mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"
cd "$wt"
run_gwt_in "$(answers 'true' '' '' '' '' 'y')" init
assert_rc 0 "init: runs from inside a worktree"
assert_exists "$repo/.gwtrc" "init: writes to the main checkout, not the worktree"
assert_missing "$wt/.gwtrc" "init: leaves no .gwtrc in the worktree"

# Answers are trimmed, so a stray space does not end up in the step.
cd "$repo"
run_gwt_in "$(answers '   npm install   ' '  package-lock.json  ' '' '' '' 'y')" init --force
rc="$(<$repo/.gwtrc)"
[[ "$rc" == *"gwt_step deps --watch package-lock.json -- npm install"$'\n'* ]] \
  && _ok "init: trims whitespace around an answer" || _fail "init: trims whitespace around an answer" "$rc"

# A command that is not runnable is worth a word, but never blocks.
run_gwt_in "$(answers 'gwt-no-such-binary install' '' '' '' '' 'y')" init --force
assert_rc 0 "init: an unrunnable command is not a refusal"
assert_err_has "gwt-no-such-binary is not on your PATH" "init: says the command is not on PATH"

# Nothing may colour output that is not going to a terminal: gwt init has to stay
# usable from a script, and an escape byte in the transcript would break that.
[[ "$GWT_ERR" != *$'\e'* ]] \
  && _ok "init: emits no escape codes when stderr is not a terminal" \
  || _fail "init: emits no escape codes when stderr is not a terminal" "found an escape in the output"

# A user-level rc is not silently shadowed without a word.
rm "$repo/.gwtrc"
write_user_rc "$repo" 'gwt_setup() { : }'
run_gwt_in "$(answers '' '' '' '' '' 'y')" init
assert_err_has "takes precedence over it" "init: warns that a repo .gwtrc shadows the user rc"

cd /
gwt_test_done
