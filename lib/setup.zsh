# Setup hooks. .gwtrc is sourced in a subshell so nothing it defines — variables,
# gwt_setup, anything else — reaches the interactive shell that called gwt.

function _gwt_hash_files {
  (( $+commands[sha256sum] )) || return 1
  local f
  for f in "$@"; do
    if [[ -f "$f" ]]; then sha256sum -- "$f"; else print -r -- "absent $f"; fi
  done | sha256sum | cut -d' ' -f1
}

function _gwt_state_dir {
  local d
  d="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
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
      [[ -n "${(P)var}" ]] && eval "${(P)var}"
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
