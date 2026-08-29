# Carry-over: what a fresh or existing worktree inherits from the main checkout.
# With a .worktreeinclude it is an allowlist; without one it is every gitignored
# path except heavy regenerable dirs, which is what gwt did before the file existed.

typeset -ga _GWT_CP_FLAGS

function _gwt_cp_flags {
  (( ${#_GWT_CP_FLAGS} )) && return
  _GWT_CP_FLAGS=(-a)
  cp --help 2>/dev/null | grep -q -- '--reflink' && _GWT_CP_FLAGS+=(--reflink=auto)
}

function _gwt_plan_include {
  git -C "$1" ls-files --others --ignored --exclude-from="$2" --directory 2>/dev/null
}

function _gwt_plan_legacy {
  local skip_re='(^|/)(node_modules|\.next|\.nuxt|dist|build|out|coverage|\.turbo|\.cache|\.parcel-cache|\.venv|venv|__pycache__|target|\.gradle|\.idea|\.vscode/\.history)(/|$)'
  local item
  for item in ${(f)"$(git -C "$1" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)"}; do
    [[ "$item" =~ $skip_re ]] && continue
    print -r -- "$item"
  done
}

function _gwt_plan {
  local src="$1" inc="$2"
  [[ -n "$inc" ]] && { _gwt_plan_include "$src" "$inc"; return }
  _gwt_plan_legacy "$src"
}

# A tracked file is never carried: --others already excludes it. Say so, because an
# entry that silently does nothing looks like the copy failed.
function _gwt_tracked_conflicts {
  local src="$1" inc="$2" line
  [[ -n "$inc" ]] || return 0
  git -C "$src" ls-files 2>/dev/null \
    | git -C "$src" -c core.excludesFile="$inc" check-ignore --no-index -v --stdin 2>/dev/null \
    | while IFS= read -r line; do
        [[ "$line" == "$inc:"* ]] && print -r -- "${line#*$'\t'}"
      done
}

function _gwt_prune_patterns {
  local inc="$1" line
  [[ -n "$inc" && -f "$inc" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == '!'* ]] || continue
    line="${${line#\!}#/}"
    print -r -- "${line%/}"
  done < "$inc"
}

function _gwt_pruned_here {
  local rel="$1" p
  shift
  for p in "$@"; do
    [[ "$rel" == ${~p} || "$rel" == ${~p}/* ]] && return 0
  done
  return 1
}

function _gwt_prune_inside {
  local rel="$1" p
  shift
  for p in "$@"; do
    [[ "$p" == "$rel"/* ]] && return 0
  done
  return 1
}

# gitignore cannot re-include a path whose parent directory is excluded, so a '!'
# entry under a carried directory is applied here instead of by git.
function _gwt_copy_pruned {
  local src="$1" dst="$2" rel="$3"
  shift 3
  _gwt_pruned_here "$rel" "$@" && return 0

  if [[ -d "$src" && ! -L "$src" ]] && _gwt_prune_inside "$rel" "$@"; then
    mkdir -p "$dst" || return 1
    local child
    for child in "$src"/*(ND); do
      _gwt_copy_pruned "$child" "$dst/${child:t}" "$rel/${child:t}" "$@" || return 1
    done
    return 0
  fi

  cp $_GWT_CP_FLAGS -- "$src" "$dst"
}

function _gwt_entry_size { du -sh -- "$1" 2>/dev/null | cut -f1 }

# mode: create (fresh worktree, never clobber) | sync (refresh an existing one)
function _gwt_carry_over {
  local src="$1" dst="$2" repo="$3" mode="$4" dry="$5" force="$6"
  [[ -d "$src" && -d "$dst" ]] || return 0

  _gwt_cp_flags

  local inc=""
  inc="$(_gwt_include_file "$src" "$repo")" || inc=""
  [[ "$inc" == "$src/.worktreeinclude" ]] && _gwt_register_excludes "$src"

  local -a plan prunes
  plan=( ${(f)"$(_gwt_plan "$src" "$inc")"} )
  prunes=( ${(f)"$(_gwt_prune_patterns "$inc")"} )
  (( ${#plan} )) || return 0

  local entry clean sp dp action failed=0
  local -i added=0 updated=0 replaced=0 skipped=0

  for entry in "${plan[@]}"; do
    clean="${entry%/}"
    sp="$src/$clean"
    [[ -e "$sp" ]] || continue
    dp="$dst/$clean"

    if [[ ! -e "$dp" ]]; then
      action=add
    elif [[ "$mode" != sync ]]; then
      action=skip
    elif [[ -d "$dp" ]]; then
      # A directory the worktree already has is its own state (installed deps, caches).
      # Replacing it is a real loss, so it needs --force.
      [[ -n "$force" ]] && action=replace || action=skip
    elif cmp -s -- "$sp" "$dp"; then
      action=same
    else
      action=update
    fi

    case "$action" in
      skip) (( skipped++ )); [[ "$mode" == sync ]] && print -r -- "  skip    $clean (exists; --force to replace)" >&2 ;;
      same) ;;
      *)
        if [[ -z "$dry" ]]; then
          mkdir -p "${dp:h}" 2>/dev/null
          [[ "$action" == replace || "$action" == update ]] && rm -rf -- "$dp"
          if ! _gwt_copy_pruned "$sp" "$dp" "$clean" "${prunes[@]}" 2>/dev/null; then
            print -r -- "error: failed to carry $clean" >&2
            (( failed++ ))
            continue
          fi
        fi
        case "$action" in
          add) (( added++ )) ;;
          update) (( updated++ )) ;;
          replace) (( replaced++ )) ;;
        esac
        [[ "$mode" == sync ]] && print -r -- "  ${action}$(printf '%*s' $(( 8 - ${#action} )) '')$clean" >&2
        ;;
    esac
  done

  if [[ "$mode" == sync ]]; then
    print -r -- "${dry:+would }carry: $added added, $updated updated, $replaced replaced, $skipped skipped" >&2
  elif (( added )); then
    if [[ -n "$inc" ]]; then
      print -r -- "📋 carried $added path(s) from $src" >&2
    else
      print -r -- "📋 copied $added gitignored path(s) from $src" >&2
    fi
  fi

  (( failed )) && return 1
  return 0
}

function _gwt_include_report {
  local src="$1" repo="$2"
  local inc=""
  inc="$(_gwt_include_file "$src" "$repo")" || inc=""

  if [[ -n "$inc" ]]; then
    print -r -- "include file: $inc"
  else
    print -r -- "include file: none — carrying gitignored paths minus build dirs"
  fi

  local -a plan prunes conflicts paths
  plan=( ${(f)"$(_gwt_plan "$src" "$inc")"} )
  prunes=( ${(f)"$(_gwt_prune_patterns "$inc")"} )
  conflicts=( ${(f)"$(_gwt_tracked_conflicts "$src" "$inc")"} )

  if (( ! ${#plan} )); then
    print -r -- "carry: nothing"
  else
    print -r -- "carry:"
    local entry clean
    for entry in "${plan[@]}"; do
      clean="${entry%/}"
      [[ -e "$src/$clean" ]] || continue
      paths+=( "$src/$clean" )
      printf '  %6s  %s\n' "$(_gwt_entry_size "$src/$clean")" "$clean"
    done
  fi

  if (( ${#prunes} )); then
    print -r -- "prune:"
    local p
    for p in "${prunes[@]}"; do print -r -- "          $p"; done
  fi

  if (( ${#conflicts} )); then
    print -r -- "warning: these are tracked by git and are never carried:"
    local c
    for c in "${conflicts[@]}"; do print -r -- "          $c"; done
  fi

  if (( ${#paths} )); then
    print -r -- "total: $(du -shc -- "${paths[@]}" 2>/dev/null | tail -1 | cut -f1) across ${#paths} path(s)"
  fi
  return 0
}
