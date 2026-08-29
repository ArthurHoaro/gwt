# gwt — git worktree helper. Entry point: source this from your zshrc.

typeset -g _GWT_ROOT="${${(%):-%x}:A:h}"

for _gwt_lib in "$_GWT_ROOT"/lib/*.zsh(N); do
  source "$_gwt_lib"
done
unset _gwt_lib

fpath=("$_GWT_ROOT/completions" $fpath)

# compinit has usually already run by the time this is sourced, so register by hand
# rather than relying on fpath being scanned.
if (( $+functions[compdef] )); then
  autoload -Uz _gwt
  compdef _gwt gwt
fi
