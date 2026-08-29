# The wizard behind 'gwt init'. Detection only supplies defaults; every answer is
# editable and nothing is written until the rendered file has been confirmed.

# Prompt on stderr rather than through read's own ?prompt form, which zsh suppresses
# when stdin is not a terminal — the transcript should read the same either way.
function _gwt_ask {
  local __var="$1" __prompt="$2" __default="$3" __reply=""
  print -rn -- "$__prompt${__default:+ [$__default]}: " >&2
  read -r __reply || { print -r -- "" >&2; return 1 }
  [[ -n "$__reply" ]] || __reply="$__default"
  : ${(P)__var::=$__reply}
  return 0
}

function _gwt_confirm {
  local prompt="$1" default="$2" hint reply=""
  [[ "$default" == y ]] && hint="Y/n" || hint="y/N"
  print -rn -- "$prompt [$hint] " >&2
  read -r reply || { print -r -- "" >&2; return 1 }
  [[ -n "$reply" ]] || reply="$default"
  [[ "$reply" == [yY]* ]]
}

function _gwt_pkg_script {
  local root="$1" name="$2"
  [[ -f "$root/package.json" ]] || return 1
  if (( $+commands[jq] )); then
    jq -r --arg n "$name" '.scripts[$n] // empty' "$root/package.json" 2>/dev/null
    return 0
  fi
  sed -n '/"scripts"[[:space:]]*:/,/}/p' "$root/package.json" 2>/dev/null \
    | sed -n "s/.*\"$name\"[[:space:]]*:[[:space:]]*\"\(.*\)\"[,[:space:]]*\$/\1/p" \
    | head -1
}

function _gwt_script_port {
  print -r -- "$1" | sed -n \
    -e 's/.*--port[= ]\{1,\}\([0-9]\{2,5\}\).*/\1/p' \
    -e 's/.*-p[= ]\{1,\}\([0-9]\{2,5\}\).*/\1/p' \
    -e 's/.*PORT=\([0-9]\{2,5\}\).*/\1/p' \
    | head -1
}

function _gwt_framework_port {
  case "$1" in
    *vite*)                   print -r -- 5173 ;;
    *astro*)                  print -r -- 4321 ;;
    *next*|*rails*|*nuxt*)    print -r -- 3000 ;;
    *manage.py*|*artisan*)    print -r -- 8000 ;;
    *)                        return 1 ;;
  esac
}

# Prints key<TAB>value for deps, watch, server and port. An unrecognised repo yields
# empty values, which just means every prompt starts blank.
function _gwt_detect_stack {
  local root="$1" pm="" deps="" server="" script="" port="" manifest="" lock="" s
  local -a watch extra

  if [[ -f "$root/package.json" ]]; then
    manifest=package.json
    if   [[ -f "$root/pnpm-lock.yaml" ]]; then pm=pnpm; lock=pnpm-lock.yaml
    elif [[ -f "$root/yarn.lock" ]];      then pm=yarn; lock=yarn.lock
    elif [[ -f "$root/bun.lock" ]];       then pm=bun;  lock=bun.lock
    elif [[ -f "$root/bun.lockb" ]];      then pm=bun;  lock=bun.lockb
    else pm=npm; lock=package-lock.json
    fi
    deps="$pm install"
    extra=(.nvmrc .node-version)
    for s in dev start; do
      script="$(_gwt_pkg_script "$root" "$s")"
      [[ -n "$script" ]] && break
    done
    if [[ -n "$script" ]]; then
      case "$pm" in
        npm|bun) server="$pm run $s" ;;
        *)       server="$pm $s" ;;
      esac
      port="$(_gwt_script_port "$script")"
      [[ -n "$port" ]] || port="$(_gwt_framework_port "$script")"
    fi
  elif [[ -f "$root/Cargo.toml" ]]; then
    manifest=Cargo.toml; lock=Cargo.lock; deps="cargo fetch"; server="cargo run"
  elif [[ -f "$root/go.mod" ]]; then
    manifest=go.mod; lock=go.sum; deps="go mod download"
  elif [[ -f "$root/composer.json" ]]; then
    manifest=composer.json; lock=composer.lock; deps="composer install"
  elif [[ -f "$root/Gemfile" ]]; then
    manifest=Gemfile; lock=Gemfile.lock; deps="bundle install"
    [[ -f "$root/bin/rails" ]] && { server="bin/rails server"; port=3000 }
  elif [[ -f "$root/uv.lock" ]]; then
    manifest=pyproject.toml; lock=uv.lock; deps="uv sync"
  elif [[ -f "$root/poetry.lock" ]]; then
    manifest=pyproject.toml; lock=poetry.lock; deps="poetry install"
  elif [[ -f "$root/Pipfile" ]]; then
    manifest=Pipfile; lock=Pipfile.lock; deps="pipenv install"
  elif [[ -f "$root/requirements.txt" ]]; then
    manifest=requirements.txt; lock=""; deps="pip install -r requirements.txt"
    [[ -f "$root/manage.py" ]] && { server="python manage.py runserver"; port=8000 }
  fi

  [[ -n "$lock" && -f "$root/$lock" ]] && watch=("$lock")
  (( ${#watch} )) || { [[ -n "$manifest" && -f "$root/$manifest" ]] && watch=("$manifest") }
  for s in "${extra[@]}"; do
    [[ -f "$root/$s" ]] && watch+=("$s")
  done

  printf '%s\t%s\n' deps "$deps" watch "${watch[*]}" server "$server" port "$port"
}

# A command with shell syntax in it cannot be dropped after `--` as bare words, so
# hand those to zsh -c instead of silently mangling the step.
function _gwt_init_step_cmd {
  local cmd="$1"
  if [[ "$cmd" == *[\&\|\;\<\>\$\`\'\"]* ]]; then
    print -r -- "zsh -c ${(qq)cmd}"
  else
    print -r -- "$cmd"
  fi
}

# steps are name<TAB>watch-list<TAB>command rows.
function _gwt_init_render {
  local repo="$1" server="$2" port="$3"
  shift 3
  local -a lines
  lines=(
    "# gwt config for $repo — sourced as zsh by 'gwt add' and 'gwt setup'."
    "# Keep it untracked: gwt refuses to source a .gwtrc that git tracks."
    ""
  )

  if [[ -n "$server" ]]; then
    lines+=( "GWT_SERVER=${(qq)server}" )
    [[ -n "$port" ]] && lines+=( "GWT_SERVER_PORT=$port" )
    lines+=( "" )
  fi

  if (( $# )); then
    lines+=( "gwt_setup() {" )
    local step name watched cmd f
    local -a watch_args
    for step in "$@"; do
      name="${step%%$'\t'*}"
      watched="${${step#*$'\t'}%%$'\t'*}"
      cmd="${step##*$'\t'}"
      watch_args=()
      for f in ${=watched}; do watch_args+=( --watch "$f" ); done
      lines+=( "  gwt_step $name ${watch_args:+${watch_args[*]} }-- $(_gwt_init_step_cmd "$cmd")" )
    done
    lines+=( "}" )
  else
    lines+=(
      "# gwt_setup() {"
      "#   gwt_step deps --watch package-lock.json -- npm install"
      "# }"
    )
  fi

  print -rl -- "${lines[@]}"
}

function _gwt_init {
  local main_root="$1" repo="$2" force="$3"
  local target="$main_root/.gwtrc"

  if git -C "$main_root" ls-files --error-unmatch -- .gwtrc >/dev/null 2>&1; then
    print -r -- "error: git tracks $target" >&2
    print -r -- "hint: .gwtrc runs as zsh, so gwt never sources a tracked one." >&2
    print -r -- "      git rm --cached .gwtrc, then run 'gwt init' again" >&2
    return 81
  fi

  if [[ -e "$target" && -z "$force" ]]; then
    print -r -- "error: $target already exists" >&2
    print -r -- "hint: 'gwt init --force' rewrites it" >&2
    return 80
  fi

  local shadowed
  shadowed="$(_gwt_config_file "$main_root" "$repo" 2>/dev/null)"
  [[ -n "$shadowed" && "$shadowed" != "$target" ]] \
    && print -r -- "note: $shadowed applies today; a repo .gwtrc takes precedence over it" >&2

  local -A det
  local line
  for line in ${(f)"$(_gwt_detect_stack "$main_root")"}; do
    det[${line%%$'\t'*}]="${line#*$'\t'}"
  done

  print -r -- "gwt init — $target" >&2
  print -r -- "Enter accepts the default in brackets; Ctrl-D cancels." >&2
  print -r -- "" >&2

  local -a steps
  local deps_cmd="" deps_watch=""
  _gwt_ask deps_cmd "install/deps command (blank for none)" "${det[deps]}" || return 82
  if [[ -n "$deps_cmd" ]]; then
    _gwt_ask deps_watch "  files that should re-run it (blank: run every time)" "${det[watch]}" || return 82
    steps+=( "deps"$'\t'"$deps_watch"$'\t'"$deps_cmd" )
  fi

  local name cmd watched
  while :; do
    _gwt_ask name "another setup step — name (blank to finish)" "" || return 82
    [[ -n "$name" ]] || break
    if [[ "$name" == */* ]]; then
      print -r -- "  a step name cannot contain '/'" >&2
      continue
    fi
    _gwt_ask cmd "  $name — command" "" || return 82
    [[ -n "$cmd" ]] || { print -r -- "  no command; dropping '$name'" >&2; continue }
    _gwt_ask watched "  $name — files that should re-run it (blank: run every time)" "" || return 82
    steps+=( "$name"$'\t'"$watched"$'\t'"$cmd" )
  done

  local server="" port=""
  _gwt_ask server "dev server command (blank for none)" "${det[server]}" || return 82
  if [[ -n "$server" ]]; then
    while :; do
      _gwt_ask port "  port it listens on (blank for none)" "${det[port]}" || return 82
      [[ -z "$port" || "$port" == <-> ]] && break
      print -r -- "  a port must be a number" >&2
      det[port]=""
    done
  fi

  local body
  body="$(_gwt_init_render "$repo" "$server" "$port" "${steps[@]}")"

  print -r -- "" >&2
  print -r -- "── $target" >&2
  print -r -- "$body" >&2
  print -r -- "──" >&2

  _gwt_confirm "write it?" y || { print -r -- "cancelled; nothing written" >&2; return 82 }

  print -r -- "$body" > "$target" || { print -r -- "error: could not write $target" >&2; return 83 }
  _gwt_register_excludes "$main_root"

  print -r -- "wrote $target" >&2
  print -r -- "next: 'gwt setup' runs it in this worktree${server:+; 'gwt serve' points the dev server here}" >&2
  print -r -- "      add a gwt_teardown() to the same file to run something just before 'gwt rm'" >&2
  return 0
}
