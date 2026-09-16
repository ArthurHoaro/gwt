#!/usr/bin/env zsh
# Installs the dev-server launcher and the host's user-service integration.
# Idempotent; safe to re-run. --uninstall leaves state and repo config alone.

emulate -L zsh
setopt err_return

here="${${(%):-%x}:A:h}"
bin_dir="${GWT_BIN_DIR:-$HOME/.local/bin}"
unit_name="gwt-server@.service"
link="$bin_dir/gwt-serve-run"

say() { print -r -- "  $*" }
escape_sed_replacement() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  value="${value//|/\\|}"
  print -r -- "$value"
}

if [[ "$1" == --uninstall ]]; then
  print -r -- "Uninstalling gwt:"
  [[ -L "$link" ]] && { rm -f "$link"; say "removed $link" } || say "no launcher at $link"
  if [[ "$OSTYPE" == darwin* ]]; then
    plist_dir="$HOME/Library/LaunchAgents"
    for plist in "$plist_dir"/com.github.arthurhoaro.gwt.*.plist(N); do
      label="${plist:t:r}"
      launchctl bootout "gui/$UID/$label" >/dev/null 2>&1 || true
      rm -f "$plist"
      say "removed $plist"
    done
  else
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    unit="$unit_dir/$unit_name"
    [[ -f "$unit" ]] && { rm -f "$unit"; say "removed $unit" } || say "no unit at $unit"
    systemctl --user daemon-reload 2>/dev/null && say "daemon-reload"
  fi
  say "left alone: ~/.local/state/gwt, your .gwtrc and .worktreeinclude files"
  say "remove the source line from your zshrc by hand if you are done with gwt"
  exit 0
fi

print -r -- "Installing gwt from $here:"

mkdir -p "$bin_dir"

if [[ -e "$link" && ! -L "$link" ]]; then
  print -ru2 -- "error: $link exists and is not a symlink; move it aside first"
  exit 1
fi
ln -sfn "$here/libexec/gwt-serve-run" "$link"
say "launcher: $link -> $here/libexec/gwt-serve-run"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "note: $bin_dir is not on your PATH; the service uses an absolute path, so this only affects you" ;;
esac

if [[ "$OSTYPE" == darwin* ]]; then
  say "service manager: launchd (a per-repo agent is created by 'gwt serve')"
else
  (( $+commands[systemctl] )) || {
    print -ru2 -- "error: systemctl not found; Linux dev-server supervision requires systemd"
    exit 1
  }
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  unit="$unit_dir/$unit_name"
  mkdir -p "$unit_dir"

  # A user service starts with a minimal PATH and zsh does not read .zshrc for a
  # non-interactive shell, so preserve the install shell's PATH.
  escaped_path="$(escape_sed_replacement "$PATH")"
  escaped_launcher="$(escape_sed_replacement "$link")"
  escaped_config="$(escape_sed_replacement "${XDG_CONFIG_HOME:-$HOME/.config}")"
  escaped_state="$(escape_sed_replacement "${XDG_STATE_HOME:-$HOME/.local/state}")"
  tmp="$(mktemp)"
  sed \
    -e "s|@GWT_PATH@|$escaped_path|" \
    -e "s|@GWT_SERVE_RUN@|$escaped_launcher|" \
    -e "s|@GWT_CONFIG_HOME@|$escaped_config|" \
    -e "s|@GWT_STATE_HOME@|$escaped_state|" \
    "$here/systemd/$unit_name" > "$tmp"
  if [[ -f "$unit" ]] && ! cmp -s "$tmp" "$unit"; then
    say "updating $unit (previous version backed up as $unit.bak)"
    cp "$unit" "$unit.bak"
  fi
  mv "$tmp" "$unit"
  chmod 644 "$unit"
  say "unit: $unit"

  systemctl --user daemon-reload
  say "daemon-reload"
fi

plugin="$here/gwt.plugin.zsh"
if grep -qF "$plugin" "${ZDOTDIR:-$HOME}/.zshrc" 2>/dev/null; then
  say "zshrc: already sources the plugin"
else
  print -r -- ""
  print -r -- "Add this to your zshrc:"
  print -r -- "  [ -f ${(q)plugin} ] && source ${(q)plugin}"
fi

print -r -- ""
print -r -- "Per repo, create an untracked .gwtrc:"
print -r -- "  GWT_SERVER='npm run dev'"
print -r -- "  GWT_SERVER_PORT=9000"
print -r -- "Then 'gwt serve' inside any worktree of that repo."
