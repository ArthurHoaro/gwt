# Git WorkTree helper: add/go/rm/reset with per-repo worktree folders
# Use 'function gwt' and unalias so we don't conflict with alias git='git '
#
# Exit codes (for debugging):
#   0   success
#   1   no command / show usage
#   2   not in a git repo
#   3   reset: cd to root failed
#   4   add|go: branch argument missing
#   5   add|go: cd to existing worktree dir failed
#   6   add|go: git fetch failed
#   7   add|go: mkdir parent failed
#   8   add|go: branch already checked out elsewhere
#   9   add|go: cd to existing (unregistered) dir failed
#  10   add|go: worktree add (local branch) failed
#  11   add|go: cd after worktree add (local) failed
#  12   add|go: worktree add (from remote) failed
#  13   add|go: cd after worktree add (remote) failed
#  14   add|go: worktree add (new branch) failed
#  15   add|go: cd after worktree add (new branch) failed
#  16   rm: branch argument missing
#  17   rm: refusing (current dir is inside that worktree)
#  18   rm: refusing (branch is current branch here)
#  19   rm: worktree directory not found
#  20   rm: worktree remove failed
#  21   unknown command
#  22   -b given without a start point
#  23   rm: refusing (branch is checked out in the main repo)
#  24   reset -d: worktree remove failed (detached HEAD; otherwise see rm codes)
#  25   checkout: branch argument missing
#  26   checkout: refusing (branch is checked out in the main repo)
#  27   checkout: refusing (current dir is inside the worktree to remove)
#  28   checkout -f: worktree remove --force failed
#  29   checkout: no such branch (not local, not on remote)
#  30   checkout: git checkout failed
#  31   checkout: branch held by a worktree (retry with -f)
#  40   sync: not inside a worktree and no branch given
#  41   sync: no worktree found for that branch
#  42   sync: one or more paths failed to carry
#  43   sync: --all takes no branch argument
#  50   setup: refusing to source a .gwtrc that git tracks
#  51   setup: hook returned non-zero
#  60   serve: no GWT_SERVER (or GWT_SERVER_PORT) configured
#  61   serve: not inside a worktree
#  62   serve: the port is held by a process that is not ours
#  63   serve: systemctl or the launcher failed
#  64   serve: unknown 'gwt serve' subcommand
#  65   serve: the systemd unit is not installed
#  66   serve: no server target set yet
#  70   prune: one or more worktrees failed to remove
#  71   go: nothing to choose from
#  72   prune: no criteria given, or no default branch
#  80   init: .gwtrc already exists (use --force)
#  81   init: git tracks .gwtrc
#  82   init: cancelled at a prompt
#  83   init: could not write .gwtrc
#

# Current branch (empty if detached)
function _gwt_current_branch { git symbolic-ref --quiet --short HEAD 2>/dev/null || true }

# Where the branch is actually checked out (if anywhere).
# This, not "$BASE/$REPO/wt-$branch", is the source of truth: a worktree keeps its
# directory name when the branch inside it is renamed or swapped.
function _gwt_checked_out_paths {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{wt=substr($0,10)}
    /^branch /{if (substr($0,8)==b) print wt}
  '
}

# One row per worktree: display<TAB>path<TAB>branch. Both the listing and the picker
# read these, so they can never drift apart.
# Dirtiness compares the index and working tree only: a full status walk over every
# worktree is too slow with dozens of them.
function _gwt_worktree_rows {
  local main_root="$1" repo="$2" served wt br dirty counts ahead behind mark disp
  served="$(_gwt_server_target "$repo" 2>/dev/null)"

  git worktree list --porcelain | awk '
    /^worktree /{wt=substr($0,10)}
    /^branch /{print wt "\t" substr($0,19); wt=""}
    /^detached/{print wt "\t(detached)"; wt=""}
  ' | while IFS=$'\t' read -r wt br; do
    [[ -n "$wt" ]] || continue
    mark=" "
    [[ -n "$served" && "$wt" == "$served" ]] && mark="▶"

    dirty=" "
    git -C "$wt" diff --quiet --ignore-submodules 2>/dev/null \
      && git -C "$wt" diff --cached --quiet --ignore-submodules 2>/dev/null \
      || dirty="●"

    counts="$(git -C "$wt" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"
    behind="${counts%%[[:space:]]*}"
    ahead="${counts##*[[:space:]]}"
    [[ "$counts" == *[0-9]* ]] || { ahead=0; behind=0 }

    disp="$(printf '%s %-28s %-26s %s %s%s' "$mark" "${wt:t}" "$br" "$dirty" \
      "$( (( ahead )) && print -rn -- "↑$ahead " )" "$( (( behind )) && print -rn -- "↓$behind" )")"
    printf '%s\t%s\t%s\n' "$disp" "$wt" "$br"
  done
}

function _gwt_list {
  local row
  for row in ${(f)"$(_gwt_worktree_rows "$1" "$2")"}; do
    print -r -- "${row%%$'\t'*}"
  done
}

# One row per branch that has no worktree: display<TAB><TAB>branch. The empty path
# field is what tells `gwt go` to create the worktree instead of cd'ing into one.
# Most recently committed first, and remote-only branches after the local ones.
function _gwt_branch_rows {
  local remote="$1" b when disp wtb
  local -A held is_local

  while read -r wtb; do
    [[ -n "$wtb" ]] && held[$wtb]=1
  done < <(git worktree list --porcelain | awk '/^branch refs\/heads\//{print substr($0,19)}')

  while IFS=$'\t' read -r b when; do
    is_local[$b]=1
    [[ -n "${held[$b]}" ]] && continue
    disp="$(printf '+ %-28s %-26s' "$when" "$b")"
    printf '%s\t\t%s\n' "$disp" "$b"
  done < <(git for-each-ref --sort=-committerdate \
    --format='%(refname:short)%09%(committerdate:relative)' refs/heads)

  while IFS=$'\t' read -r b when; do
    [[ "$b" == HEAD || -n "${is_local[$b]}" ]] && continue
    disp="$(printf '+ %-28s %-26s %s' "$when" "$b" "$remote")"
    printf '%s\t\t%s\n' "$disp" "$b"
  done < <(git for-each-ref --sort=-committerdate \
    --format='%(refname:lstrip=3)%09%(committerdate:relative)' "refs/remotes/$remote")
}

# fzf when it is there, zsh's select when it is not. Tests replace this wholesale.
function _gwt_pick {
  local -a rows=("$@")
  (( ${#rows} )) || return 1
  if (( $+commands[fzf] )); then
    print -rl -- "${rows[@]}" \
      | fzf --delimiter=$'\t' --with-nth=1 --no-multi --height=40% --reverse --prompt='go> '
    return $?
  fi
  local choice
  select choice in ${rows[@]%%$'\t'*}; do
    [[ -n "$choice" ]] && { print -r -- "${rows[$REPLY]}"; return 0 }
  done
  return 1
}

unalias gwt 2>/dev/null
function gwt {
  local BASE="${GWT_BASE:-/home/arthur/projects/codesignal/tree-codesignal}"
  local REMOTE="origin"

  local cmd="$1"; shift

  local branch="" start_point="" delete_tree="" force="" dry_run="" all="" no_setup="" merged=""
  while (( $# )); do
    case "$1" in
      -b) (( $# >= 2 )) || { print -r -- "error: -b requires a start point" >&2; return 22; }
          start_point="$2"; shift 2 ;;
      -d|--delete) delete_tree=1; shift ;;
      -f|--force) force=1; shift ;;
      -n|--dry-run) dry_run=1; shift ;;
      --all) all=1; shift ;;
      --no-setup) no_setup=1; shift ;;
      --merged) merged=1; shift ;;
       *) branch="$1"; shift ;;
    esac
  done

  local usage="
usage:
  gwt add [-b <start>] <branch>  # create worktree from <start> (default: HEAD), cd into it
  gwt go  [-b <start>] <branch>  # cd into worktree if exists; otherwise create from <start>
  gwt rm  <branch>               # remove worktree; delete branch if merged; prune
  gwt checkout [-f] <branch>     # checkout <branch> here; -f force-removes a worktree holding it
  gwt reset [-d]                 # cd back to main repo root (non-tree); -d also removes the worktree you left
  gwt list                       # list all worktrees for current repo
  gwt sync [-n] [--force] [<branch>|--all]
                                 # re-carry files from the main checkout into an existing worktree
  gwt include                    # show what a worktree would inherit; changes nothing
  gwt init [--force]             # wizard: write this repo's .gwtrc; --force overwrites an existing one
  gwt setup [--force]            # re-run this repo's setup hook here; --force ignores the step cache
  gwt serve [stop|restart|status|logs [-f]|open]
                                 # point this repo's single dev server at the current worktree
  gwt prune --merged [-n] [-f]   # remove worktrees whose branch is merged or gone on origin
"

  if [[ -z "$cmd" ]]; then
    print -r -- "$usage" >&2
    return 1
  fi

  # Must be in a git repo for all commands.
  # Main (non-worktree) repo root: parent of the common git dir. REPO must come from
  # here, not from --show-toplevel, which inside a worktree is the worktree itself.
  local REPO DIR MAIN_ROOT
  MAIN_ROOT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { print -r -- "error: not in a git repo" >&2; return 2; }
  MAIN_ROOT="${MAIN_ROOT:h}"
  REPO="${MAIN_ROOT:t}"

  # Worktree dir for a branch
  if [[ -n "$branch" ]]; then
    DIR="$BASE/$REPO/wt-$branch"
  fi

  case "$cmd" in
    list)
      _gwt_list "$MAIN_ROOT" "$REPO"
      return 0
      ;;

    prune)
      [[ -n "$merged" ]] || {
        print -r -- "usage: gwt prune --merged [-n] [-f]   # -n previews, -f skips the prompt" >&2
        return 72
      }

      git fetch --prune "$REMOTE" >/dev/null 2>&1 \
        || print -r -- "note: fetch failed; classifying from local refs only" >&2

      local default
      default="$(_gwt_default_branch)" || {
        print -r -- "error: cannot determine the default branch" >&2
        return 72
      }

      local here_real cb
      here_real="$(pwd -P)"
      cb="$(_gwt_current_branch)"

      local -a candidates skipped
      local row b wt reason wt_real
      for row in ${(f)"$(_gwt_prune_candidates "$MAIN_ROOT" "$default")"}; do
        b="${row%%$'\t'*}"
        wt="${${row#*$'\t'}%%$'\t'*}"
        reason="${row##*$'\t'}"
        wt_real="$wt"
        [[ -d "$wt" ]] && wt_real="$(cd "$wt" && pwd -P)"
        if [[ "$here_real/" == "$wt_real/"* || "$cb" == "$b" ]]; then
          skipped+=( "$b (you are in it)" )
          continue
        fi
        candidates+=( "$row" )
      done

      for row in "${skipped[@]}"; do
        print -r -- "  skip    $row" >&2
      done

      (( ${#candidates} )) || { print -r -- "nothing to prune" >&2; return 0 }

      for row in "${candidates[@]}"; do
        printf '  remove  %-30s %s\n' "${row%%$'\t'*}" "${row##*$'\t'}" >&2
      done

      [[ -n "$dry_run" ]] && {
        print -r -- "would remove ${#candidates} worktree(s)" >&2
        return 0
      }

      if [[ -z "$force" ]]; then
        print -rn -- "remove ${#candidates} worktree(s)? [y/N] " >&2
        local reply=""
        # Wait indefinitely for a person, but never hang a script: a pipe that never
        # delivers would otherwise block this destructive command forever.
        if [[ -t 0 ]]; then
          read -r reply || reply=""
        else
          read -t 5 -r reply || reply=""
        fi
        [[ "$reply" == [yY]* ]] || { print -r -- "aborted" >&2; return 0 }
      fi

      local -i removed=0 failed=0
      for row in "${candidates[@]}"; do
        b="${row%%$'\t'*}"
        if gwt rm "$b"; then
          (( removed++ ))
        else
          print -r -- "error: could not remove '$b'" >&2
          (( failed++ ))
        fi
      done
      if (( failed )); then
        print -r -- "pruned $removed worktree(s), $failed failed" >&2
        return 70
      fi
      print -r -- "pruned $removed worktree(s)" >&2
      return 0
      ;;

    serve)
      _gwt_serve "$branch" "$MAIN_ROOT" "$REPO" "$force"
      return $?
      ;;

    include)
      _gwt_include_report "$MAIN_ROOT" "$REPO"
      return 0
      ;;

    init)
      _gwt_init "$MAIN_ROOT" "$REPO" "$force"
      return $?
      ;;

    setup)
      local here
      here="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)"
      [[ -n "$here" ]] || { print -r -- "error: not in a worktree" >&2; return 2 }
      _gwt_run_setup "$MAIN_ROOT" "$REPO" "$here" "$(_gwt_current_branch)" "$force"
      return $?
      ;;

    sync)
      local -a targets
      if [[ -n "$all" ]]; then
        [[ -n "$branch" ]] && { print -r -- "error: --all takes no branch argument" >&2; return 43; }
        local wt
        for wt in ${(f)"$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')"}; do
          [[ "$wt" == "$MAIN_ROOT" ]] && continue
          targets+=( "$wt" )
        done
      elif [[ -n "$branch" ]]; then
        local found
        found="$(_gwt_checked_out_paths "$branch")"
        found="${found%%$'\n'*}"
        [[ -n "$found" ]] || { [[ -d "$DIR" ]] && found="$DIR" }
        [[ -n "$found" ]] || { print -r -- "error: no worktree found for '$branch'" >&2; return 41; }
        targets=( "$found" )
      else
        local here
        here="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)"
        if [[ -z "$here" || "$here" == "$MAIN_ROOT" ]]; then
          print -r -- "error: not inside a worktree; name a branch or use --all" >&2
          return 40
        fi
        targets=( "$here" )
      fi

      (( ${#targets} )) || { print -r -- "note: no worktrees to sync" >&2; return 0 }

      local t rc=0
      for t in "${targets[@]}"; do
        print -r -- "${t:t}:" >&2
        _gwt_carry_over "$MAIN_ROOT" "$t" "$REPO" sync "$dry_run" "$force" || rc=42
      done
      return $rc
      ;;

    reset)
      # Snapshot the worktree before leaving it: -d removes the one we're cd'ing out of.
      local from_wt="" from_branch=""
      if [[ -n "$delete_tree" ]]; then
        from_wt="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)"
        [[ "$from_wt" == "$MAIN_ROOT" ]] && from_wt=""
        from_branch="$(_gwt_current_branch)"
      fi

      # Go back to the main (non-tree) repo root, even from inside a worktree.
      cd "$MAIN_ROOT" || { print -r -- "error: failed to cd to $MAIN_ROOT" >&2; return 3; }

      [[ -n "$delete_tree" ]] || return 0

      if [[ -z "$from_wt" ]]; then
        print -r -- "note: not inside a linked worktree; nothing to remove" >&2
        return 0
      fi

      # Detached HEAD gives `gwt rm` no branch to resolve; remove the path directly.
      if [[ -z "$from_branch" ]]; then
        _gwt_server_release "$REPO" "$from_wt"
        git worktree remove "$from_wt" >/dev/null || { print -r -- "error: git worktree remove failed" >&2; return 24; }
        git worktree prune >/dev/null 2>&1 || true
        return 0
      fi

      gwt rm "$from_branch"
      return $?
      ;;

    add|go)
      local setup_rc=0

      # bare `gwt go` is a picker over the existing worktrees plus every branch that
      # has none; picking one of those falls through to the normal `gwt go <branch>`.
      if [[ "$cmd" == "go" && -z "$branch" ]]; then
        local -a rows
        rows=(
          ${(f)"$(_gwt_worktree_rows "$MAIN_ROOT" "$REPO")"}
          ${(f)"$(_gwt_branch_rows "$REMOTE")"}
        )
        (( ${#rows} )) || { print -r -- "error: nothing to choose from" >&2; return 71 }
        local picked dest
        picked="$(_gwt_pick "${rows[@]}")" || return 0
        [[ -n "$picked" ]] || return 0
        dest="${${picked#*$'\t'}%%$'\t'*}"
        if [[ -z "$dest" ]]; then
          gwt go ${no_setup:+--no-setup} "${picked##*$'\t'}"
          return $?
        fi
        cd "$dest" || { print -r -- "error: failed to cd to $dest" >&2; return 5; }
        return 0
      fi

      [[ -z "$branch" ]] && { print -r -- "$usage" >&2; return 4; }

      # 🧹 prune stale metadata first
      git worktree prune >/dev/null 2>&1 || true

      # Branch already checked out somewhere: "go" follows it, "add" refuses.
      local paths
      paths="$(_gwt_checked_out_paths "$branch")"
      if [[ -n "$paths" ]]; then
        if [[ "$cmd" == "go" ]]; then
          cd "${paths%%$'\n'*}" || { print -r -- "error: failed to cd to $paths" >&2; return 5; }
          return 0
        fi
        print -r -- "error: branch '$branch' is already checked out at:" >&2
        print -r -- "$paths" >&2
        return 8
      fi

      # If "go" and dir exists already -> just cd.
      if [[ "$cmd" == "go" && -d "$DIR" ]]; then
        cd "$DIR" || { print -r -- "error: failed to cd to $DIR" >&2; return 5; }
        return 0
      fi

      # 🔁 fetch first so remote detection is reliable
      git fetch --prune "$REMOTE" >/dev/null || { print -r -- "error: git fetch failed" >&2; return 6; }

      mkdir -p "${DIR:h}" || { print -r -- "error: failed to mkdir ${DIR:h}" >&2; return 7; }

      # If worktree directory exists but is not registered properly, "go" will cd; "add" will fail later.
      # We'll treat existing directory as "go" behavior:
      if [[ -d "$DIR" ]]; then
        cd "$DIR" || { print -r -- "error: failed to cd to $DIR" >&2; return 9; }
        return 0
      fi

      # Local branch exists?
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        git worktree add "$DIR" "$branch" >/dev/null || { print -r -- "error: git worktree add failed" >&2; return 10; }
        _gwt_carry_over "$MAIN_ROOT" "$DIR" "$REPO" create "" ""
        [[ -z "$no_setup" ]] && { _gwt_run_setup "$MAIN_ROOT" "$REPO" "$DIR" "$branch" "" || setup_rc=$? }
        cd "$DIR" || { print -r -- "error: failed to cd to $DIR" >&2; return 11; }
        return $setup_rc
      fi

      # 🧠 Remote branch exists? create local branch from it + set upstream.
      if git show-ref --verify --quiet "refs/remotes/$REMOTE/$branch"; then
        git worktree add -b "$branch" "$DIR" "$REMOTE/$branch" >/dev/null || { print -r -- "error: git worktree add failed" >&2; return 12; }
        git -C "$DIR" branch --set-upstream-to="$REMOTE/$branch" "$branch" >/dev/null 2>&1 || true
        _gwt_carry_over "$MAIN_ROOT" "$DIR" "$REPO" create "" ""
        [[ -z "$no_setup" ]] && { _gwt_run_setup "$MAIN_ROOT" "$REPO" "$DIR" "$branch" "" || setup_rc=$? }
        cd "$DIR" || { print -r -- "error: failed to cd to $DIR" >&2; return 13; }
        return $setup_rc
      fi

      # Else: create new branch from start_point (or HEAD if omitted)
      git worktree add -b "$branch" "$DIR" ${start_point:+"$start_point"} >/dev/null || { print -r -- "error: git worktree add failed" >&2; return 14; }
      _gwt_carry_over "$MAIN_ROOT" "$DIR" "$REPO" create "" ""
      [[ -z "$no_setup" ]] && { _gwt_run_setup "$MAIN_ROOT" "$REPO" "$DIR" "$branch" "" || setup_rc=$? }
      cd "$DIR" || { print -r -- "error: failed to cd to $DIR" >&2; return 15; }
      return $setup_rc
      ;;

    checkout|co)
      [[ -z "$branch" ]] && { print -r -- "$usage" >&2; return 25; }

      git worktree prune >/dev/null 2>&1 || true

      if [[ "$(_gwt_current_branch)" == "$branch" ]]; then
        print -r -- "note: already on '$branch'" >&2
        return 0
      fi

      # A worktree holding the branch is what blocks the checkout; -f drops it, then we switch.
      local holders_out
      holders_out="$(_gwt_checked_out_paths "$branch")"
      if [[ -n "$holders_out" ]]; then
        if [[ -z "$force" ]]; then
          print -r -- "error: '$branch' is already checked out at:" >&2
          print -r -- "$holders_out" >&2
          print -r -- "hint: 'gwt go $branch' to cd there, or 'gwt checkout -f $branch' to remove it and check out here" >&2
          return 31
        fi

        local here_real wt wt_real dirty_out rm_err parent
        here_real="$(pwd -P)"

        for wt in ${(f)holders_out}; do
          if [[ "$wt" == "$MAIN_ROOT" ]]; then
            print -r -- "error: refusing: '$branch' is checked out in the main repo $MAIN_ROOT" >&2
            return 26
          fi

          if [[ -d "$wt" ]]; then
            wt_real="$(cd "$wt" && pwd -P)"
            if [[ "$here_real/" == "$wt_real/"* ]]; then
              print -r -- "error: refusing: you're inside $wt_real (cd out first)" >&2
              return 27
            fi
            dirty_out="$(git -C "$wt" status --porcelain 2>/dev/null)"
            [[ -n "$dirty_out" ]] && print -r -- "⚠️  $wt has ${#${(f)dirty_out}} uncommitted change(s); they will be lost" >&2
          fi

          print -r -- "🗑️  removing worktree $wt" >&2
          if ! rm_err="$(git worktree remove --force "$wt" 2>&1)"; then
            # A locked worktree needs a second --force; anything else is a real failure.
            if git worktree remove --force --force "$wt" >/dev/null 2>&1; then
              print -r -- "note: $wt was locked; removed anyway" >&2
            else
              print -r -- "error: could not remove $wt: $rm_err" >&2
              return 28
            fi
          fi

          parent="${wt:h}"
          while [[ "$parent" == "$BASE/$REPO/"* ]]; do
            rmdir "$parent" 2>/dev/null || break
            parent="${parent:h}"
          done
        done

        git worktree prune >/dev/null 2>&1 || true
      fi

      # -f applies to the worktree, never to your local changes: plain checkout from here on.
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout "$branch" || return 30
        return 0
      fi

      if ! git show-ref --verify --quiet "refs/remotes/$REMOTE/$branch"; then
        git fetch --prune "$REMOTE" >/dev/null || print -r -- "note: git fetch failed; using local refs only" >&2
      fi

      if git show-ref --verify --quiet "refs/remotes/$REMOTE/$branch"; then
        git checkout -b "$branch" --track "$REMOTE/$branch" || return 30
        return 0
      fi

      print -r -- "error: no such branch: '$branch' (not local, not on $REMOTE)" >&2
      return 29
      ;;

    rm)
      [[ -z "$branch" ]] && { print -r -- "$usage" >&2; return 16; }

      git worktree prune >/dev/null 2>&1 || true

      # Ask git where the branch lives; only guess the conventional path if it's unregistered.
      local target
      target="$(_gwt_checked_out_paths "$branch")"
      target="${target%%$'\n'*}"
      [[ -n "$target" ]] || target="$DIR"

      if [[ "$target" == "$MAIN_ROOT" ]]; then
        print -r -- "error: refusing: '$branch' is checked out in the main repo $MAIN_ROOT" >&2
        return 23
      fi

      # 🔒 Refuse if you're inside that worktree dir
      local pwd_real dir_real
      pwd_real="$(pwd -P)"
      if [[ -d "$target" ]]; then
        dir_real="$(cd "$target" && pwd -P)"
        if [[ "$pwd_real/" == "$dir_real/"* ]]; then
          print -r -- "error: refusing: you're inside $dir_real (cd out first)" >&2
          return 17
        fi
      fi

      # 🔒 Refuse deleting current branch in *this* worktree
      local cb
      cb="$(_gwt_current_branch)"
      if [[ "$cb" == "$branch" ]]; then
        print -r -- "error: refusing: '$branch' is your current branch here (checkout something else first)" >&2
        return 18
      fi

      [[ -d "$target" ]] || { print -r -- "error: worktree directory not found: $target" >&2; return 19; }

      _gwt_server_release "$REPO" "$target"
      _gwt_run_teardown "$MAIN_ROOT" "$REPO" "$target" "$branch"

      git worktree remove "$target" >/dev/null || { print -r -- "error: git worktree remove failed" >&2; return 20; }

      # Slashed branch names nest dirs; drop parents left empty, never $BASE/$REPO itself
      local parent="${target:h}"
      while [[ "$parent" == "$BASE/$REPO/"* ]]; do
        rmdir "$parent" 2>/dev/null || break
        parent="${parent:h}"
      done

      # Delete branch if merged (safe delete)
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        if ! git branch -d "$branch" >/dev/null 2>&1; then
          print -r -- "note: branch '$branch' not fully merged; not deleting (use: git branch -D $branch)" >&2
        fi
      fi

      # 🧹 prune stale worktrees after removal
      git worktree prune >/dev/null 2>&1 || true
      return 0
      ;;

    *)
      print -r -- "$usage" >&2
      return 21
      ;;
  esac
}
