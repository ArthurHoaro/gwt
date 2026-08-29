#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "serve"

# Nothing here may reach the real systemd. Every call is recorded instead.
sysctl_log="$GWT_TEST_ROOT/systemctl.log"
: > "$sysctl_log"
typeset -g STUB_UNIT_INSTALLED=1
function _gwt_systemctl {
  print -r -- "$*" >> "$sysctl_log"
  case "$1" in
    cat) (( STUB_UNIT_INSTALLED )) && return 0 || return 1 ;;
    show)
      case "$2" in
        -p) case "$3" in
              ActiveState) print -r -- active ;;
              SubState) print -r -- running ;;
              *) print -r -- "" ;;
            esac ;;
      esac
      return 0 ;;
  esac
  return 0
}
function _gwt_journalctl { print -r -- "journalctl $*" >> "$sysctl_log" }
typeset -g STUB_PORT_HOLDER=""
function _gwt_port_holder { print -r -- "$STUB_PORT_HOLDER" }
function _gwt_pid_is_ours { [[ "$STUB_HOLDER_IS_OURS" == 1 ]] }
function _gwt_pid_cmdline { print -r -- "next-dev --port 9000" }

sysctl_calls() { grep -c . "$sysctl_log" }
restarts()    { grep -c '^restart ' "$sysctl_log" }
target_file() { print -r -- "$(_gwt_state_home)/${repo:t}/target" }
read_target() { local f; f="$(target_file)"; [[ -r "$f" ]] && print -r -- "$(<$f)" }
last_call() { tail -1 "$sysctl_log" }

repo="$(mk_repo)"
mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"
mk_branch "$repo" feat-b
wt2="$(mk_worktree "$repo" feat-b)"
write_gwtrc "$repo" "GWT_SERVER='npm run dev'" 'GWT_SERVER_PORT=9000'

# no unit installed yet
STUB_UNIT_INSTALLED=0
cd "$wt"
run_gwt serve
assert_rc 65 "serve: refuses when the unit is not installed"
assert_err_has "install.sh" "serve: points at the installer"
STUB_UNIT_INSTALLED=1

# pointing the server at the worktree you are in
run_gwt serve
assert_rc 0 "serve: succeeds"
assert_eq "$wt" "$(read_target)" "serve: records the target worktree"
assert_eq "restart gwt-server@${repo:t}.service" "$(last_call)" "serve: restarts the unit"

# retargeting is just running it again somewhere else
cd "$wt2"
run_gwt serve
assert_rc 0 "serve: retargets"
assert_eq "$wt2" "$(read_target)" "serve: the new worktree owns it"

# the port guard is the whole point: refuse rather than restart-loop
STUB_PORT_HOLDER=4242
STUB_HOLDER_IS_OURS=0
cd "$wt"
before="$(restarts)"
run_gwt serve
assert_rc 62 "serve: refuses when the port is held by someone else"
assert_err_has "held by pid 4242" "serve: names the offending pid"
assert_err_has "next-dev --port 9000" "serve: prints the offending command line"
assert_eq "$before" "$(restarts)" "serve: never starts the unit when the port is taken"
assert_eq "$wt2" "$(read_target)" "serve: does not retarget on a refusal"

# our own server holding the port is fine
STUB_HOLDER_IS_OURS=1
run_gwt serve
assert_rc 0 "serve: starts when the port holder is our own unit"
STUB_PORT_HOLDER=""

# stop, status, logs, open
run_gwt serve stop
assert_rc 0 "serve stop: succeeds"
assert_eq "stop gwt-server@${repo:t}.service" "$(last_call)" "serve stop: stops the unit"

run_gwt serve status
assert_rc 0 "serve status: succeeds"
assert_out_has "target: $wt" "serve status: shows the target worktree"
assert_out_has "feat-a" "serve status: shows its branch"
assert_out_has "9000" "serve status: shows the port"

run_gwt serve logs
assert_rc 0 "serve logs: succeeds"
assert_eq "journalctl -u gwt-server@${repo:t}.service -n 200" "$(last_call)" "serve logs: reads this repo's unit"
run_gwt serve logs -f
assert_eq "journalctl -u gwt-server@${repo:t}.service -f -n 200" "$(last_call)" "serve logs -f: follows"

run_gwt serve nonsense
assert_rc 64 "serve: rejects an unknown subcommand"

# config problems
write_gwtrc "$repo" 'GWT_SERVER_PORT=9000'
run_gwt serve
assert_rc 60 "serve: refuses without GWT_SERVER"
write_gwtrc "$repo" "GWT_SERVER='npm run dev'" 'GWT_SERVER_PORT=9000'
git -C "$repo" add -f .gwtrc && git -C "$repo" commit -qm "track the rc"
run_gwt serve
assert_rc 50 "serve: refuses a tracked .gwtrc"
git -C "$repo" rm -q --cached .gwtrc && git -C "$repo" commit -qm untrack

# removing the worktree that owns the server stops it first
cd "$wt"
run_gwt serve
assert_eq "$wt" "$(read_target)" "serve: targeting the tree about to be removed"
cd "$repo"
run_gwt rm feat-a
assert_rc 0 "rm: succeeds while the server targets that worktree"
assert_eq "stop gwt-server@${repo:t}.service" "$(last_call)" "rm: stops the server first"
assert_missing "$(target_file)" "rm: clears the stale target"

# removing an unrelated worktree must not touch the server
cd "$wt2"
run_gwt serve
mk_branch "$repo" feat-c
wt3="$(mk_worktree "$repo" feat-c)"
cd "$repo"
before="$(sysctl_calls)"
run_gwt rm feat-c
assert_rc 0 "rm: succeeds for an unrelated worktree"
assert_eq "$before" "$(sysctl_calls)" "rm: leaves the server alone when it targets elsewhere"
assert_eq "$wt2" "$(read_target)" "rm: target unchanged"

# gwt list marks the worktree that owns the server
run_gwt list
assert_rc 0 "list: succeeds"
print -r -- "$GWT_OUT" | grep -q "▶ .*${wt2:t}" \
  && _ok "list: marks the serving worktree" \
  || _fail "list: marks the serving worktree" "got: ${GWT_OUT//$'\n'/ | }"
print -r -- "$GWT_OUT" | grep -q "^  .*${repo:t}" \
  && _ok "list: leaves other rows unmarked" \
  || _fail "list: leaves other rows unmarked" "got: ${GWT_OUT//$'\n'/ | }"
[[ "$GWT_OUT" == *"$wt2"* ]] \
  && _fail "list: shows names, not raw paths" "the full worktree path leaked into the display" \
  || _ok "list: shows names, not raw paths"

# dirty column
print -r -- "changed" >> "$wt2/README"
run_gwt list
print -r -- "$GWT_OUT" | grep -q "${wt2:t}.*●" \
  && _ok "list: flags a dirty worktree" \
  || _fail "list: flags a dirty worktree" "got: ${GWT_OUT//$'\n'/ | }"

# a repo with no server configured never reaches systemd
before="$(sysctl_calls)"
repo2="$(mk_repo other)"
mk_branch "$repo2" x
wtx="$(mk_worktree "$repo2" x)"
cd "$repo2"
run_gwt rm x
assert_eq "$before" "$(sysctl_calls)" "rm: no systemd contact for a repo with no server"

cd /
gwt_test_done
