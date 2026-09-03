# Setup hooks. .gwtrc is sourced in a subshell so nothing it defines — variables,
# gwt_setup, anything else — reaches the interactive shell that called gwt.

function _gwt_hash_files {
  (( $+commands[sha256sum] )) || return 1
  local f
  for f in "$@"; do
    if [[ -f "$f" ]]; then sha256sum -- "$f"; else print -r -- "absent $f"; fi
  done | sha256sum | cut -d' ' -f1
}

# The optional argument names a worktree; with none, the one the caller stands in.
function _gwt_state_dir {
  local d
  local -a where
  [[ -n "$1" ]] && where=( -C "$1" )
  d="$(git "${where[@]}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  print -r -- "$d/gwt-state"
}

# gwt_step <name> [--watch <file>]... -- <command>...
# Runs the command unless every watched file is byte-identical to what was present
# the last time it succeeded here. Git deletes the state with the worktree.
function gwt_step {
  local name="$1"
  (( $# )) && shift
  [[ -n "$name" && "$name" != */* ]] || {
    print -ru2 -- "gwt_step: bad step name '$name'"
    return 2
  }

  local -a watch cmd
  while (( $# )); do
    case "$1" in
      --watch)
        (( $# >= 2 )) || { print -ru2 -- "gwt_step: --watch needs a file"; return 2 }
        watch+=( "$2" ); shift 2 ;;
      --) shift; cmd=( "$@" ); break ;;
      *) print -ru2 -- "gwt_step: unexpected argument '$1'"; return 2 ;;
    esac
  done
  (( ${#cmd} )) || { print -ru2 -- "gwt_step: $name has no command"; return 2 }

  local state_dir hash_file before
  state_dir="$(_gwt_state_dir)" && hash_file="$state_dir/$name"

  if (( ${#watch} )) && [[ -n "$hash_file" && -z "$_GWT_STEP_FORCE" ]]; then
    before="$(_gwt_hash_files "${watch[@]}")"
    if [[ -n "$before" && -r "$hash_file" && "$(<$hash_file)" == "$before" ]]; then
      print -ru2 -- "gwt: $name unchanged, skipping"
      return 0
    fi
  fi

  print -ru2 -- "gwt: $name"
  "${cmd[@]}" || return $?

  # Hash after the fact: npm and friends rewrite the very lockfile being watched,
  # and what is on disk now is what the next run should compare against.
  if (( ${#watch} )) && [[ -n "$hash_file" ]]; then
    local after
    after="$(_gwt_hash_files "${watch[@]}")"
    [[ -n "$after" ]] && { mkdir -p "$state_dir" 2>/dev/null && print -r -- "$after" > "$hash_file" }
  fi
  return 0
}

function _gwt_run_hook {
  local main_root="$1" repo="$2" tree="$3" branch="$4" force="$5" kind="$6"
  local cfg rc=0

  cfg="$(_gwt_config_file "$main_root" "$repo")"
  rc=$?
  (( rc == 2 )) && return 50
  (( rc == 0 )) || return 0

  (
    cd "$tree" 2>/dev/null || exit 1
    export GWT_WORKTREE="$tree" GWT_BRANCH="$branch" GWT_MAIN_ROOT="$main_root" GWT_REPO="$repo"
    _GWT_STEP_FORCE="$force"
    unfunction gwt_setup gwt_teardown 2>/dev/null
    unset GWT_SETUP GWT_TEARDOWN
    source "$cfg" || exit 1
    if (( $+functions[gwt_$kind] )); then
      "gwt_$kind"
    else
      local var="GWT_${kind:u}"
      [[ -n "${(P)var}" ]] || exit 0
      eval "${(P)var}"
    fi
  )
}

function _gwt_run_setup {
  _gwt_run_hook "$1" "$2" "$3" "$4" "$5" setup
  local rc=$?
  (( rc == 0 || rc == 50 )) || return 51
  return $rc
}

# Teardown must never block a removal: report and carry on.
function _gwt_run_teardown {
  _gwt_run_hook "$1" "$2" "$3" "$4" "" teardown \
    || print -ru2 -- "note: teardown hook failed; removing anyway"
  return 0
}

# --- background runs ------------------------------------------------------
# A backgrounded hook is a detached process writing to a log beside the step cache,
# so it outlives the shell that started it and can be watched from any other one.

# The runner records its own pid, so a stale pid left behind by a killed run must not
# read as live: the cmdline says whether this pid is still that runner.
function _gwt_setup_alive {
  local pid="$1"
  [[ -n "$pid" && "$pid" == <-> ]] || return 1
  [[ -r /proc/$pid/cmdline ]] || return 1
  _gwt_pid_cmdline "$pid" | grep -q gwt-setup-run
}

# Where the background run stands, as a word plus its detail:
#   running <pid> <epoch>   done <code>   interrupted   none
# A running pid of 0 is the gap between the spawn and the runner recording its own.
function _gwt_setup_state {
  local d="$1" pid="" started=""
  [[ -r "$d/setup.status" ]] && { print -r -- "done $(<$d/setup.status)"; return 0 }
  [[ -r "$d/setup.pid" ]] && pid="$(<$d/setup.pid)"
  [[ -r "$d/setup.started" ]] && started="$(<$d/setup.started)"
  if _gwt_setup_alive "$pid"; then
    print -r -- "running $pid $started"
    return 0
  fi
  [[ -n "$pid" ]] && { print -r -- interrupted; return 0 }
  [[ -n "$started" ]] && { print -r -- "running 0 $started"; return 0 }
  print -r -- none
}

function _gwt_setup_is_running {
  local d state
  d="$(_gwt_state_dir "$1")" || return 1
  state="$(_gwt_setup_state "$d")"
  [[ "${state%% *}" == running ]]
}

function _gwt_setup_elapsed {
  local -i s
  [[ "$1" == <-> ]] || { print -rn -- "an unknown time"; return 0 }
  (( s = $(date +%s) - $1 ))
  (( s < 0 )) && s=0
  (( s < 60 )) && { print -rn -- "${s}s"; return 0 }
  printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
}

function _gwt_setup_outcome {
  [[ "$1" == 0 ]] \
    && print -ru2 -- "gwt: setup finished" \
    || print -ru2 -- "gwt: setup failed (exit $1)"
}

# A finished log is read, not followed, so it gets the pager an install log deserves.
function _gwt_setup_page {
  [[ -s "$1" ]] || return 0
  if [[ -t 1 ]] && (( $+commands[less] )); then
    less -FRX -- "$1"
  else
    cat -- "$1"
  fi
}

# Detached and in its own session: a long install must not die with the terminal that
# started it, and ctrl-c in a shell that watches it must not reach it either.
function _gwt_setup_spawn {
  local main_root="$1" repo="$2" tree="$3" branch="$4" force="$5" d runner
  runner="$_GWT_ROOT/libexec/gwt-setup-run"
  [[ -x "$runner" ]] || { print -ru2 -- "error: setup runner not found at $runner"; return 51 }
  d="$(_gwt_state_dir "$tree")" || { print -ru2 -- "error: cannot locate the git dir of $tree"; return 51 }
  mkdir -p "$d" || return 51

  rm -f "$d/setup.pid" "$d/setup.status"
  : > "$d/setup.log" || return 51
  date +%s > "$d/setup.started"

  local -a launch=( "$runner" "$main_root" "$repo" "$tree" "$branch" "$force" )
  (( $+commands[setsid] )) && launch=( setsid --fork "${launch[@]}" )
  "${launch[@]}" </dev/null >>"$d/setup.log" 2>&1 &!

  print -ru2 -- "gwt: setup running in the background — 'gwt setup attach' to follow it"
  return 0
}

function _gwt_setup_attach {
  local d="$1" log="$d/setup.log" state pid="" code detached="" waited=0

  state="$(_gwt_setup_state "$d")"
  case "$state" in
    none)
      print -ru2 -- "note: no background setup has run in this worktree"
      return 54 ;;
    interrupted)
      _gwt_setup_page "$log"
      print -ru2 -- "gwt: setup was interrupted; no exit code recorded"
      return 51 ;;
    done*)
      _gwt_setup_page "$log"
      code="${state##* }"
      _gwt_setup_outcome "$code"
      [[ "$code" == <-> ]] || return 51
      return $code ;;
  esac

  while (( waited < 50 )); do
    [[ -s "$d/setup.pid" || -r "$d/setup.status" ]] && break
    sleep 0.1
    (( waited++ ))
  done
  [[ -r "$d/setup.pid" ]] && pid="$(<$d/setup.pid)"
  if [[ -z "$pid" ]]; then
    [[ -r "$d/setup.status" ]] && { _gwt_setup_attach "$d"; return $? }
    print -ru2 -- "error: setup was started here but never recorded its pid"
    return 54
  fi

  print -ru2 -- "gwt: following setup (pid $pid) — ctrl-c detaches, it keeps running"
  trap 'detached=1' INT
  # --pid ends the follow the moment the runner exits: that is what makes this a
  # foreground run rather than an endless tail.
  tail -n +1 -f --pid="$pid" -- "$log"
  trap - INT
  [[ -n "$detached" ]] && {
    print -ru2 -- "gwt: detached; 'gwt setup attach' comes back to it"
    return 130
  }

  waited=0
  while (( waited < 30 )); do
    [[ -r "$d/setup.status" ]] && break
    sleep 0.1
    (( waited++ ))
  done
  [[ -r "$d/setup.status" ]] || {
    print -ru2 -- "gwt: setup ended without recording an exit code"
    return 51
  }
  code="$(<$d/setup.status)"
  _gwt_setup_outcome "$code"
  [[ "$code" == <-> ]] || return 51
  return $code
}

function _gwt_setup_report {
  local d="$1" tree="$2" state pid code
  state="$(_gwt_setup_state "$d")"
  print -r -- "worktree: ${tree:t}"
  case "${state%% *}" in
    running)
      pid="${${state#running }%% *}"
      print -r -- "setup:    running for $(_gwt_setup_elapsed "${state##* }")$( (( pid )) && print -rn -- " (pid $pid)")"
      ;;
    done)
      code="${state##* }"
      [[ "$code" == 0 ]] \
        && print -r -- "setup:    finished ok" \
        || print -r -- "setup:    failed (exit $code)"
      ;;
    interrupted) print -r -- "setup:    interrupted; no exit code recorded" ;;
    none)        print -r -- "setup:    no background run recorded here" ;;
  esac
  [[ -s "$d/setup.log" ]] && print -r -- "log:      $d/setup.log"
  return 0
}

# Called before a worktree is removed: an install still writing into a directory that
# is about to go is worse than a killed install. The runner leads its own process
# group, so the whole install tree goes with it.
function _gwt_setup_release {
  local tree="$1" d pid=""
  d="$(_gwt_state_dir "$tree")" || return 0
  [[ -r "$d/setup.pid" ]] && pid="$(<$d/setup.pid)"
  _gwt_setup_alive "$pid" || return 0
  print -ru2 -- "■ stopping the setup still running in ${tree:t} (pid $pid)"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  return 0
}

function _gwt_setup_wants_bg {
  local main_root="$1" repo="$2" bg="$3"
  case "$bg" in
    bg) return 0 ;;
    fg) return 1 ;;
  esac
  # A tracked .gwtrc is refused here too; let the run itself say so, once.
  [[ "$(_gwt_config_value "$main_root" "$repo" GWT_SETUP_BG 2>/dev/null)" == 1 ]]
}

# Every path that runs setup on demand comes through here, so the fg/bg choice and
# the one-run-at-a-time rule are made in one place.
function _gwt_setup_start {
  local main_root="$1" repo="$2" tree="$3" branch="$4" force="$5" bg="$6"
  if _gwt_setup_is_running "$tree"; then
    print -ru2 -- "error: setup is already running in ${tree:t} — 'gwt setup attach' to follow it"
    return 53
  fi
  if _gwt_setup_wants_bg "$main_root" "$repo" "$bg"; then
    _gwt_setup_spawn "$main_root" "$repo" "$tree" "$branch" "$force"
  else
    _gwt_run_setup "$main_root" "$repo" "$tree" "$branch" "$force"
  fi
}

function _gwt_setup_cmd {
  local sub="$1" main_root="$2" repo="$3" tree="$4" force="$5" bg="$6" d
  case "$sub" in
    ""|run)
      _gwt_setup_start "$main_root" "$repo" "$tree" "$(_gwt_current_branch)" "$force" "$bg"
      return $? ;;
    attach|fg)
      d="$(_gwt_state_dir "$tree")" || return 54
      _gwt_setup_attach "$d"
      return $? ;;
    status)
      d="$(_gwt_state_dir "$tree")" || return 54
      _gwt_setup_report "$d" "$tree"
      return $? ;;
    *)
      print -ru2 -- "error: unknown 'gwt setup' subcommand: $sub"
      return 52 ;;
  esac
}
