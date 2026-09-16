# Singleton dev server: one per repo, retargetable at any worktree. systemd owns it
# on Linux and launchd owns it on macOS.

function _gwt_systemctl { systemctl --user "$@" }
function _gwt_journalctl { journalctl --user "$@" }
function _gwt_launchctl { launchctl "$@" }
function _gwt_open_url {
  if [[ "$OSTYPE" == darwin* ]]; then
    (( $+commands[open] )) || return 1
    open "$1" >/dev/null 2>&1
  else
    (( $+commands[xdg-open] )) || return 1
    xdg-open "$1" >/dev/null 2>&1
  fi
}

function _gwt_state_home { print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/gwt" }
function _gwt_server_launcher { print -r -- "${GWT_BIN_DIR:-$HOME/.local/bin}/gwt-serve-run" }
function _gwt_server_unit { print -r -- "gwt-server@$1.service" }
function _gwt_launchd_label { print -r -- "com.github.arthurhoaro.gwt.${1//[^A-Za-z0-9.-]/-}" }
function _gwt_launchd_plist { print -r -- "$HOME/Library/LaunchAgents/$(_gwt_launchd_label "$1").plist" }

function _gwt_supervisor {
  [[ "$OSTYPE" == darwin* ]] && print -r -- launchd || print -r -- systemd
}

function _gwt_xml_escape {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  print -r -- "$value"
}

function _gwt_launchd_write_plist {
  local repo="$1" plist label state launcher
  plist="$(_gwt_launchd_plist "$repo")"
  label="$(_gwt_launchd_label "$repo")"
  state="$(_gwt_state_home)/$repo"
  launcher="$(_gwt_server_launcher)"
  mkdir -p "${plist:h}" "$state" || return 1
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(_gwt_xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(_gwt_xml_escape "$launcher")</string>
    <string>$(_gwt_xml_escape "$repo")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$(_gwt_xml_escape "$HOME")</string>
    <key>PATH</key>
    <string>$(_gwt_xml_escape "$PATH")</string>
    <key>XDG_CONFIG_HOME</key>
    <string>$(_gwt_xml_escape "${XDG_CONFIG_HOME:-$HOME/.config}")</string>
    <key>XDG_STATE_HOME</key>
    <string>$(_gwt_xml_escape "${XDG_STATE_HOME:-$HOME/.local/state}")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>3</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$(_gwt_xml_escape "$state/server.log")</string>
  <key>StandardErrorPath</key>
  <string>$(_gwt_xml_escape "$state/server.log")</string>
</dict>
</plist>
EOF
}

function _gwt_service_installed {
  local repo="$1"
  if [[ "$(_gwt_supervisor)" == launchd ]]; then
    [[ -x "$(_gwt_server_launcher)" ]]
  else
    _gwt_systemctl cat "gwt-server@.service" >/dev/null 2>&1
  fi
}

function _gwt_service_restart {
  local repo="$1" unit="$2"
  if [[ "$(_gwt_supervisor)" == launchd ]]; then
    local plist="$(_gwt_launchd_plist "$repo")" service="gui/$UID/$(_gwt_launchd_label "$repo")"
    _gwt_launchd_write_plist "$repo" || return 1
    _gwt_launchctl bootout "$service" >/dev/null 2>&1 || true
    _gwt_launchctl bootstrap "gui/$UID" "$plist"
  else
    _gwt_systemctl restart "$unit"
  fi
}

function _gwt_service_stop {
  local repo="$1" unit="$2"
  if [[ "$(_gwt_supervisor)" == launchd ]]; then
    local service="gui/$UID/$(_gwt_launchd_label "$repo")"
    _gwt_launchctl bootout "$service" 2>/dev/null || {
      _gwt_launchctl print "$service" >/dev/null 2>&1 && return 1
      return 0
    }
  else
    _gwt_systemctl stop "$unit"
  fi
}

function _gwt_service_pid {
  local repo="$1"
  [[ "$(_gwt_supervisor)" == launchd ]] || return 1
  _gwt_launchctl print "gui/$UID/$(_gwt_launchd_label "$repo")" 2>/dev/null \
    | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*$/\1/p' | head -1
}

function _gwt_service_status {
  local repo="$1" unit="$2"
  if [[ "$(_gwt_supervisor)" == launchd ]]; then
    local out state pid
    out="$(_gwt_launchctl print "gui/$UID/$(_gwt_launchd_label "$repo")" 2>/dev/null)" || {
      print -r -- $'not loaded\t\t'
      return 0
    }
    state="$(print -r -- "$out" | sed -n 's/^[[:space:]]*state = //p' | head -1)"
    pid="$(print -r -- "$out" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*$/\1/p' | head -1)"
    print -r -- "${state:-unknown}"$'\t'"$pid"$'\t'
  else
    local state sub_state since
    state="$(_gwt_systemctl show -p ActiveState --value "$unit" 2>/dev/null)"
    sub_state="$(_gwt_systemctl show -p SubState --value "$unit" 2>/dev/null)"
    since="$(_gwt_systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)"
    print -r -- "${state:-unknown}/${sub_state:-unknown}"$'\t\t'"$since"
  fi
}

function _gwt_service_logs {
  local repo="$1" unit="$2" follow="$3"
  if [[ "$(_gwt_supervisor)" == launchd ]]; then
    local log="$(_gwt_state_home)/$repo/server.log"
    [[ -e "$log" ]] || : > "$log"
    tail -n 200 ${follow:+-f} "$log"
  else
    local -a jargs=( -a --no-hostname -o short-iso -u "$unit" -n 200 ${follow:+-f} )
    local dim=""
    [[ -t 1 ]] && dim=1
    if [[ -z "$follow" && -n "$dim" ]] && (( $+commands[less] )); then
      _gwt_journalctl "${jargs[@]}" | _gwt_logs_trim "$dim" | less "-${SYSTEMD_LESS:-FRSXMK}"
    else
      _gwt_journalctl "${jargs[@]}" | _gwt_logs_trim "$dim"
    fi
    return ${pipestatus[1]}
  fi
}

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
  [[ -n "$port" ]] || return 1
  if [[ "$OSTYPE" == darwin* ]]; then
    (( $+commands[lsof] )) || return 1
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1
  elif (( $+commands[ss] )); then
    ss -lptnH "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
  elif (( $+commands[lsof] )); then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1
  else
    return 1
  fi
}

function _gwt_pid_cmdline {
  if [[ "$OSTYPE" == darwin* ]]; then
    ps -p "$1" -o command= 2>/dev/null
  else
    tr '\0' ' ' < /proc/$1/cmdline 2>/dev/null
  fi
}

# systemd puts every process of a unit in its cgroup, which is what makes "is this
# listener one of ours" answerable at all: next dev's children are in there too.
function _gwt_pid_is_ours {
  local pid="$1" unit="$2" repo="$3"
  if [[ "$(_gwt_supervisor)" == launchd ]]; then
    local owner="$(_gwt_service_pid "$repo")" parent
    [[ -n "$owner" ]] || return 1
    while [[ "$pid" == <-> && "$pid" != 0 ]]; do
      [[ "$pid" == "$owner" ]] && return 0
      parent="$(ps -p "$pid" -o ppid= 2>/dev/null)"
      pid="${parent//[[:space:]]/}"
    done
    return 1
  fi
  [[ -r /proc/$pid/cgroup ]] && grep -qF -- "$unit" /proc/$pid/cgroup
}

# journalctl prints "timestamp hostname launcher[pid]:" ahead of every line, all of it
# identical down a log already filtered to one unit. Only the clock survives. Reads
# short-iso, not short, because the month name in short output is locale-dependent.
function _gwt_logs_trim {
  local pre="" post=""
  [[ -n "$1" ]] && { pre=$'\e[2m'; post=$'\e[22m' }
  sed -E "s/^[0-9-]+T([0-9]{2}:[0-9]{2}:[0-9]{2})[^ ]* [^ ]+: /$pre\1$post /"
}

function _gwt_serve {
  local sub="$1" main_root="$2" repo="$3" follow="$4"
  local unit="$(_gwt_server_unit "$repo")"

  case "$sub" in
    ""|start|restart)
      _gwt_service_installed "$repo" || {
        print -ru2 -- "error: the gwt server launcher is not installed; run install.sh in the gwt repo"
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
      if [[ -n "$holder" ]] && ! _gwt_pid_is_ours "$holder" "$unit" "$repo"; then
        print -ru2 -- "error: port $port is held by pid $holder, which is not this repo's server:"
        print -ru2 -- "  $(_gwt_pid_cmdline "$holder")"
        return 62
      fi

      _gwt_server_set_target "$repo" "$tree" || return 63
      _gwt_service_restart "$repo" "$unit" || return 63
      print -ru2 -- "▶ $repo server → ${tree:t}${port:+ (port $port)}"
      return 0
      ;;

    stop)
      _gwt_service_stop "$repo" "$unit" || return 63
      print -ru2 -- "■ $repo server stopped"
      return 0
      ;;

    status)
      local tree service_status state service_pid since port holder
      tree="$(_gwt_server_target "$repo")"
      service_status="$(_gwt_service_status "$repo" "$unit")"
      state="${service_status%%$'\t'*}"
      service_status="${service_status#*$'\t'}"
      service_pid="${service_status%%$'\t'*}"
      since="${service_status#*$'\t'}"
      port="$(_gwt_config_value "$main_root" "$repo" GWT_SERVER_PORT)"

      print -r -- "repo:   $repo"
      print -r -- "service: $unit (${state:-unknown})${service_pid:+ pid $service_pid}${since:+ since $since}"
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
          _gwt_pid_is_ours "$holder" "$unit" "$repo" \
            && print -r -- "port:   $port — listening (pid $holder, ours)" \
            || print -r -- "port:   $port — held by pid $holder, NOT ours: $(_gwt_pid_cmdline "$holder")"
        else
          print -r -- "port:   $port — nothing listening"
        fi
      fi
      return 0
      ;;

    logs)
      _gwt_service_logs "$repo" "$unit" "$follow"
      return $?
      ;;

    open)
      local port
      port="$(_gwt_config_value "$main_root" "$repo" GWT_SERVER_PORT)"
      [[ -n "$port" ]] || { print -ru2 -- "error: no GWT_SERVER_PORT in this repo's .gwtrc"; return 60 }
      _gwt_open_url "http://localhost:$port" || {
        print -ru2 -- "error: could not open the browser"
        return 63
      }
      ;;

    *)
      print -ru2 -- "error: unknown 'gwt serve' subcommand: $sub"
      return 64
      ;;
  esac
}

# Called before a worktree is removed. Never touches the supervisor unless this repo
# actually has a server pointed at the tree in question.
function _gwt_server_release {
  local repo="$1" tree="$2" current
  current="$(_gwt_server_target "$repo")" || return 0
  [[ "$current" == "$tree" ]] || return 0
  print -ru2 -- "■ stopping $repo server: it targets the worktree being removed"
  _gwt_service_stop "$repo" "$(_gwt_server_unit "$repo")" 2>/dev/null
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
