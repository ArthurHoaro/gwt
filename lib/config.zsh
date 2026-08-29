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

# Prints the .gwtrc to source. Returns 1 when there is none, 2 when the repo-root one
# is refused. Sourcing is arbitrary code execution, so a tracked .gwtrc — one that
# could arrive with a git pull — is never sourced, no matter what it contains.
function _gwt_config_file {
  local main_root="$1" repo="$2" cfg="$main_root/.gwtrc" c
  if [[ -f "$cfg" ]]; then
    if git -C "$main_root" ls-files --error-unmatch -- .gwtrc >/dev/null 2>&1; then
      print -ru2 -- "error: refusing to source $cfg: git tracks it"
      print -ru2 -- "hint: .gwtrc runs as zsh, so a tracked one executes code from every pull."
      print -ru2 -- "      git rm --cached .gwtrc  (it is already in .git/info/exclude)"
      return 2
    fi
    print -r -- "$cfg"
    return 0
  fi
  local base="${XDG_CONFIG_HOME:-$HOME/.config}/gwt"
  for c in "$base/$repo/rc" "$base/rc"; do
    [[ -f "$c" ]] && { print -r -- "$c"; return 0 }
  done
  return 1
}
