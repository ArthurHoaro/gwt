# Carry-over: copy gitignored files from the main repo into a fresh worktree
# so things like .env, local config, etc. are usable right away.
# Skips heavy/regenerable dirs (node_modules, build output, caches).
function _gwt_copy_ignored_files {
  local src="$1" dst="$2"
  [[ -d "$src" && -d "$dst" ]] || return 0

  local -a items
  items=( ${(f)"$(git -C "$src" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)"} )
  (( ${#items} )) || return 0

  local skip_re='(^|/)(node_modules|\.next|\.nuxt|dist|build|out|coverage|\.turbo|\.cache|\.parcel-cache|\.venv|venv|__pycache__|target|\.gradle|\.idea|\.vscode/\.history)(/|$)'
  local item clean parent count=0
  for item in "${items[@]}"; do
    [[ "$item" =~ $skip_re ]] && continue
    clean="${item%/}"
    [[ -e "$src/$clean" ]] || continue
    [[ -e "$dst/$clean" ]] && continue  # don't clobber existing
    parent="$(dirname "$clean")"
    mkdir -p "$dst/$parent" 2>/dev/null
    cp -a "$src/$clean" "$dst/$clean" 2>/dev/null && (( count++ ))
  done
  (( count )) && print -r -- "📋 copied $count gitignored path(s) from $src" >&2
  return 0
}
