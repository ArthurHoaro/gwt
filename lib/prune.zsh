# Bulk removal of worktrees whose branch is finished: merged into the default branch,
# or tracking an upstream that no longer exists.

function _gwt_default_branch {
  local ref b
  ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
    && { print -r -- "${ref#origin/}"; return 0 }
  for b in main master; do
    git show-ref --verify --quiet "refs/remotes/origin/$b" && { print -r -- "$b"; return 0 }
    git show-ref --verify --quiet "refs/heads/$b" && { print -r -- "$b"; return 0 }
  done
  return 1
}

# branch<TAB>path<TAB>reason
function _gwt_prune_candidates {
  local main_root="$1" default="$2" base
  if git show-ref --verify --quiet "refs/remotes/origin/$default"; then
    base="origin/$default"
  else
    base="$default"
  fi

  local -A gone
  local br tr
  while IFS='|' read -r br tr; do
    [[ "$tr" == gone ]] && gone[$br]=1
  done < <(git for-each-ref --format='%(refname:short)|%(upstream:track,nobracket)' refs/heads)

  local wt b reason
  git worktree list --porcelain | awk '
    /^worktree /{wt=substr($0,10)}
    /^branch /{print wt "\t" substr($0,19); wt=""}
  ' | while IFS=$'\t' read -r wt b; do
    [[ -n "$wt" && -n "$b" ]] || continue
    [[ "$wt" == "$main_root" ]] && continue
    [[ "$b" == "$default" ]] && continue
    reason=""
    if [[ -n "${gone[$b]}" ]]; then
      reason="gone on origin"
    elif git merge-base --is-ancestor "refs/heads/$b" "$base" 2>/dev/null; then
      reason="merged into $base"
    fi
    [[ -n "$reason" ]] && printf '%s\t%s\t%s\n' "$b" "$wt" "$reason"
  done
}
