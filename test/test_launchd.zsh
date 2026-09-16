#!/usr/bin/env zsh
source "${${(%):-%x}:A:h}/harness.zsh"
gwt_test_init "launchd"

function _gwt_supervisor { print -r -- launchd }
launchctl_log="$GWT_TEST_ROOT/launchctl.log"
: > "$launchctl_log"

function _gwt_launchctl {
  print -r -- "$*" >> "$launchctl_log"
  if [[ "$1" == print ]]; then
    print -r -- $'state = running\npid = 4242'
  fi
}
function _gwt_port_holder { return 1 }
function _gwt_open_url { return 0 }

mkdir -p "$HOME/.local/bin"
ln -s "$GWT_TEST_HOME/../libexec/gwt-serve-run" "$HOME/.local/bin/gwt-serve-run"

repo="$(mk_repo)"
mk_branch "$repo" feat-a
wt="$(mk_worktree "$repo" feat-a)"
write_gwtrc "$repo" "GWT_SERVER='npm run dev'" 'GWT_SERVER_PORT=9000'

cd "$wt"
run_gwt serve
assert_rc 0 "launchd: serve starts"

plist="$HOME/Library/LaunchAgents/com.github.arthurhoaro.gwt.${repo:t}.plist"
assert_exists "$plist" "launchd: serve writes a per-repo agent"
grep -qF "$HOME/.local/bin/gwt-serve-run" "$plist" \
  && _ok "launchd: agent uses the installed launcher" \
  || _fail "launchd: agent uses the installed launcher" "launcher missing from $plist"
grep -qF "${XDG_STATE_HOME:-$HOME/.local/state}/gwt/${repo:t}/server.log" "$plist" \
  && _ok "launchd: agent records the server log" \
  || _fail "launchd: agent records the server log" "log path missing from $plist"
grep -q "^bootstrap gui/$UID $plist$" "$launchctl_log" \
  && _ok "launchd: agent is bootstrapped" \
  || _fail "launchd: agent is bootstrapped" "calls: $(<"$launchctl_log")"

run_gwt serve status
assert_rc 0 "launchd: status succeeds"
assert_out_has "running" "launchd: status reports the agent state"
assert_out_has "pid 4242" "launchd: status reports the agent pid"

run_gwt serve stop
assert_rc 0 "launchd: stop succeeds"
grep -q "^bootout gui/$UID/com.github.arthurhoaro.gwt.${repo:t}$" "$launchctl_log" \
  && _ok "launchd: stop removes the running agent" \
  || _fail "launchd: stop removes the running agent" "calls: $(<"$launchctl_log")"

cd /
gwt_test_done
