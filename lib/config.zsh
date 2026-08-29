# Resolution order: repo root, then per-repo user config. Failure means no file, and
# carry-over falls back to the built-in ignore rules.
function _gwt_include_file {
  local main_root="$1" repo="$2" c
  for c in "$main_root/.worktreeinclude" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/gwt/$repo/worktreeinclude"; do
    [[ -f "$c" ]] && { print -r -- "$c"; return 0 }
  done
  return 1
}

# gwt's dotfiles are personal and must not arrive via git pull. info/exclude lives in
# the common git dir, so registering once covers every worktree of the repo.
function _gwt_register_excludes {
  local main_root="$1" ex name
  ex="$(git -C "$main_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  ex="$ex/info/exclude"
  [[ -d "${ex:h}" ]] || mkdir -p "${ex:h}" 2>/dev/null || return 0
  for name in /.worktreeinclude /.gwtrc; do
    grep -qxF -- "$name" "$ex" 2>/dev/null || print -r -- "$name" >> "$ex" 2>/dev/null
  done
  return 0
}
