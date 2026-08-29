#!/usr/bin/env zsh
# Installs the launcher and the systemd user unit. Idempotent; safe to re-run.
# --uninstall removes both (server state and .gwtrc files are left alone).

emulate -L zsh
setopt err_return

here="${${(%):-%x}:A:h}"
bin_dir="$HOME/.local/bin"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_name="gwt-server@.service"
link="$bin_dir/gwt-serve-run"
unit="$unit_dir/$unit_name"

say() { print -r -- "  $*" }

if [[ "$1" == --uninstall ]]; then
  print -r -- "Uninstalling gwt:"
  [[ -L "$link" ]] && { rm -f "$link"; say "removed $link" } || say "no launcher at $link"
  [[ -f "$unit" ]] && { rm -f "$unit"; say "removed $unit" } || say "no unit at $unit"
  systemctl --user daemon-reload 2>/dev/null && say "daemon-reload"
  say "left alone: ~/.local/state/gwt, your .gwtrc and .worktreeinclude files"
  say "remove the source line from your zshrc by hand if you are done with gwt"
  exit 0
fi

print -r -- "Installing gwt from $here:"

mkdir -p "$bin_dir" "$unit_dir"

if [[ -e "$link" && ! -L "$link" ]]; then
  print -ru2 -- "error: $link exists and is not a symlink; move it aside first"
  exit 1
fi
ln -sfn "$here/libexec/gwt-serve-run" "$link"
say "launcher: $link -> $here/libexec/gwt-serve-run"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "note: $bin_dir is not on your PATH; the unit uses an absolute path, so this only affects you" ;;
esac

# The unit needs a PATH that resolves node: systemd starts with almost nothing, and
# zsh does not read .zshrc for a non-interactive shell. Bake in the PATH we were
# invoked with, the same way openclaw-gateway.service does on this machine.
tmp="$(mktemp)"
sed "s|@GWT_PATH@|$PATH|" "$here/systemd/$unit_name" > "$tmp"
if [[ -f "$unit" ]] && ! cmp -s "$tmp" "$unit"; then
  say "updating $unit (previous version backed up as $unit.bak)"
  cp "$unit" "$unit.bak"
fi
mv "$tmp" "$unit"
chmod 644 "$unit"
say "unit: $unit"

systemctl --user daemon-reload
say "daemon-reload"

plugin="$here/gwt.plugin.zsh"
if grep -qF "$plugin" "${ZDOTDIR:-$HOME}/.zshrc" 2>/dev/null; then
  say "zshrc: already sources the plugin"
else
  print -r -- ""
  print -r -- "Add this to your zshrc:"
  print -r -- "  [ -f $plugin ] && source $plugin"
fi

print -r -- ""
print -r -- "Per repo, create an untracked .gwtrc:"
print -r -- "  GWT_SERVER='npm run dev'"
print -r -- "  GWT_SERVER_PORT=9000"
print -r -- "Then 'gwt serve' inside any worktree of that repo."
