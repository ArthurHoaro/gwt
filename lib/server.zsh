# Singleton dev server: one per repo, retargetable at any worktree, owned by systemd.
# systemctl and journalctl go through these two wrappers so tests can replace them.

function _gwt_systemctl { systemctl --user "$@" }
function _gwt_journalctl { journalctl --user "$@" }

function _gwt_state_home { print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/gwt" }
function _gwt_server_unit { print -r -- "gwt-server@$1.service" }

function _gwt_server_target {
  local f="$(_gwt_state_home)/$1/target"
  [[ -r "$f" ]] || return 1
  local t="$(<$f)"
  [[ -n "$t" ]] && print -r -- "$t"
}

function _gwt_server_set_target {
  local d="$(_gwt_state_home)/$1"
  mkdir -p "$d" || return 1
  print -r -- "$2" > "$d/target"
}

function _gwt_port_holder {
  local port="$1"
  [[ -n "$port" ]] && (( $+commands[ss] )) || return 1
  ss -lptnH "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
}

function _gwt_pid_cmdline { tr '\0' ' ' < /proc/$1/cmdline 2>/dev/null }

# systemd puts every process of a unit in its cgroup, which is what makes "is this
# listener one of ours" answerable at all: next dev's children are in there too.
function _gwt_pid_is_ours {
  [[ -r /proc/$1/cgroup ]] && grep -qF -- "$2" /proc/$1/cgroup
}

function _gwt_unit_installed { _gwt_systemctl cat "gwt-server@.service" >/dev/null 2>&1 }

# journalctl prints "timestamp hostname launcher[pid]:" ahead of every line, all of it
# identical down a log already filtered to one unit. Only the clock survives. Reads
# short-iso, not short, because the month name in short output is locale-dependent.
function _gwt_logs_trim {
  local pre="" post=""
  [[ -n "$1" ]] && { pre=$'\e[2m'; post=$'\e[22m' }
  sed -uE "s/^[0-9-]+T([0-9]{2}:[0-9]{2}:[0-9]{2})[^ ]* [^ ]+: /$pre\1$post /"
}

function _gwt_serve {
  local sub="$1" main_root="$2" repo="$3" follow="$4"
  local unit="$(_gwt_server_unit "$repo")"

  case "$sub" in
    ""|start|restart)
      _gwt_unit_installed || {
        print -ru2 -- "error: $unit is not installed; run install.sh in the gwt repo"
        return 65
      }

      local tree
      if [[ "$sub" == restart ]]; then
        tree="$(_gwt_server_target "$repo")" || {
          print -ru2 -- "error: no server target set for '$repo'; run 'gwt serve' in a worktree"
          return 66
        }
      else
        tree="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)"
        [[ -n "$tree" ]] || { print -ru2 -- "error: not inside a worktree"; return 61 }
      fi

      local cmd port
      cmd="$(_gwt_config_value "$main_root" "$repo" GWT_SERVER)" || return 50
      [[ -n "$cmd" ]] || {
        print -ru2 -- "error: no GWT_SERVER in this repo's .gwtrc"
        return 60
      }
      port="$(_gwt_config_value "$main_root" "$repo" GWT_SERVER_PORT)"

      # The exact failure that causes tab-hunting: something else already owns the
      # port, so refuse and name it rather than let systemd restart-loop.
      local holder
      holder="$(_gwt_port_holder "$port")"
      if [[ -n "$holder" ]] && ! _gwt_pid_is_ours "$holder" "$unit"; then
        print -ru2 -- "error: port $port is held by pid $holder, which is not this repo's server:"
        print -ru2 -- "  $(_gwt_pid_cmdline "$holder")"
        return 62
      fi

      _gwt_server_set_target "$repo" "$tree" || return 63
      _gwt_systemctl restart "$unit" || return 63
      print -ru2 -- "▶ $repo server → ${tree:t}${port:+ (port $port)}"
      return 0
      ;;

    stop)
      _gwt_systemctl stop "$(_gwt_server_unit "$repo")" || return 63
      print -ru2 -- "■ $repo server stopped"
      return 0
      ;;

    status)
      local tree state sub_state since port holder
      tree="$(_gwt_server_target "$repo")"
      state="$(_gwt_systemctl show -p ActiveState --value "$unit" 2>/dev/null)"
      sub_state="$(_gwt_systemctl show -p SubState --value "$unit" 2>/dev/null)"
      since="$(_gwt_systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)"
      port="$(_gwt_config_value "$main_root" "$repo" GWT_SERVER_PORT)"

      print -r -- "repo:   $repo"
      print -r -- "unit:   $unit (${state:-unknown}/${sub_state:-unknown})${since:+ since $since}"
      if [[ -n "$tree" ]]; then
        local tb
        tb="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null)"
        print -r -- "target: $tree${tb:+ [$tb]}"
        [[ -d "$tree" ]] || print -r -- "        ⚠ that directory no longer exists"
      else
        print -r -- "target: none set"
      fi
      if [[ -n "$port" ]]; then
        holder="$(_gwt_port_holder "$port")"
        if [[ -n "$holder" ]]; then
          _gwt_pid_is_ours "$holder" "$unit" \
            && print -r -- "port:   $port — listening (pid $holder, ours)" \
            || print -r -- "port:   $port — held by pid $holder, NOT ours: $(_gwt_pid_cmdline "$holder")"
        else
          print -r -- "port:   $port — nothing listening"
        fi
      fi
      return 0
      ;;

    logs)
      # -a: without it journalctl drops the server's color escapes as unprintable.
      local -a jargs=( -a --no-hostname -o short-iso -u "$unit" -n 200 ${follow:+-f} )
      local dim=""
      [[ -t 1 ]] && dim=1
      if [[ -z "$follow" && -n "$dim" ]] && (( $+commands[less] )); then
        # journalctl only runs its own pager when it owns stdout, and the trim takes
        # that away. Same less options it would have used.
        _gwt_journalctl "${jargs[@]}" | _gwt_logs_trim "$dim" | less "-${SYSTEMD_LESS:-FRSXMK}"
      else
        _gwt_journalctl "${jargs[@]}" | _gwt_logs_trim "$dim"
      fi
      return ${pipestatus[1]}
      ;;

    open)
      local port
      port="$(_gwt_config_value "$main_root" "$repo" GWT_SERVER_PORT)"
      [[ -n "$port" ]] || { print -ru2 -- "error: no GWT_SERVER_PORT in this repo's .gwtrc"; return 60 }
      (( $+commands[xdg-open] )) || { print -ru2 -- "error: xdg-open not found"; return 63 }
      xdg-open "http://localhost:$port" >/dev/null 2>&1
      return 0
      ;;

    *)
      print -ru2 -- "error: unknown 'gwt serve' subcommand: $sub"
      return 64
      ;;
  esac
}

# Called before a worktree is removed. Never touches systemd unless this repo
# actually has a server pointed at the tree in question.
function _gwt_server_release {
  local repo="$1" tree="$2" current
  current="$(_gwt_server_target "$repo")" || return 0
  [[ "$current" == "$tree" ]] || return 0
  print -ru2 -- "■ stopping $repo server: it targets the worktree being removed"
  _gwt_systemctl stop "$(_gwt_server_unit "$repo")" 2>/dev/null
  rm -f "$(_gwt_state_home)/$repo/target"
  return 0
}

# Opt-in: GWT_SERVER_HINT=1 before sourcing the plugin. Off by default because this
# runs on every cd, and it costs a git call each time.
function _gwt_server_hint {
  local root repo served
  root="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$root" ]] || return 0
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  repo="${${common:h}:t}"
  served="$(_gwt_server_target "$repo" 2>/dev/null)" || return 0
  [[ -n "$served" && "$served" != "$root" ]] || return 0
  print -ru2 -- "note: dev server is on ${served:t} — 'gwt serve' to move it here"
}
