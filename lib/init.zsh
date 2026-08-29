# The wizard behind 'gwt init'. Detection only supplies defaults; every answer is
# editable and nothing is written until the rendered file has been confirmed.

typeset -gA _GWT_FMT

function _gwt_fmt_init {
  _GWT_FMT=( reset '' bold '' title '' label '' hint '' ok '' warn '' err '' rule '' )
  [[ -t 2 && -z "$NO_COLOR" && "$TERM" != dumb ]] || return 0
  _GWT_FMT=(
    reset $'\e[0m'   bold  $'\e[1m'     title $'\e[1;36m'  label $'\e[36m'
    hint  $'\e[2m'   ok    $'\e[1;32m'  warn  $'\e[33m'    err   $'\e[31m'
    rule  $'\e[2;36m'
  )
}

function _gwt_fmt_width {
  local w=${COLUMNS:-76}
  (( w > 78 )) && w=78
  (( w < 56 )) && w=56
  print -r -- $w
}

function _gwt_trim {
  setopt local_options extended_glob
  local s="$1"
  print -r -- "${${s##[[:space:]]#}%%[[:space:]]#}"
}

function _gwt_section {
  local title="$1" width=$(_gwt_fmt_width) len
  shift
  len=$(( width - ${#title} - 3 ))
  (( len < 3 )) && len=3
  print -r -- "" >&2
  print -r -- "  ${_GWT_FMT[title]}${title}${_GWT_FMT[reset]} ${_GWT_FMT[rule]}${(l:$len::─:)}${_GWT_FMT[reset]}" >&2
  local note
  for note in "$@"; do
    print -r -- "  ${_GWT_FMT[hint]}${note}${_GWT_FMT[reset]}" >&2
  done
  print -r -- "" >&2
}

function _gwt_note { print -r -- "  ${_GWT_FMT[hint]}$1${_GWT_FMT[reset]}" >&2 }
function _gwt_warn { print -r -- "  ${_GWT_FMT[warn]}!${_GWT_FMT[reset]} $1" >&2 }

# Pre-fills the default as editable text when there is a terminal to edit it on, and
# falls back to a bracketed hint when there is not: answers piped in from a script
# must still be able to see what they are accepting.
function _gwt_ask {
  local __var="$1" __label="$2" __default="$3" __indent="${4:-2}" __reply=""
  local __pad="${(l:$__indent:)}" __gap=$(( 20 - __indent ))
  (( __gap < 4 )) && __gap=4

  if [[ -t 0 ]] && [[ -o zle ]]; then
    __reply="$__default"
    vared -p "${__pad}${_GWT_FMT[label]}${(r:$__gap:)__label}${_GWT_FMT[reset]}${_GWT_FMT[bold]}❯${_GWT_FMT[reset]} " __reply \
      || { print -r -- "" >&2; return 1 }
  else
    print -rn -- "${__pad}${_GWT_FMT[label]}${(r:$__gap:)__label}${_GWT_FMT[reset]}" >&2
    [[ -n "$__default" ]] && print -rn -- "${_GWT_FMT[hint]}[$__default]${_GWT_FMT[reset]} " >&2
    print -rn -- "${_GWT_FMT[bold]}❯${_GWT_FMT[reset]} " >&2
    read -r __reply || { print -r -- "" >&2; return 1 }
    [[ -n "$__reply" ]] || __reply="$__default"
  fi

  __reply="$(_gwt_trim "$__reply")"
  # Blank means "keep the default", so clearing one needs a character of its own.
  [[ "$__reply" == - ]] && __reply=""
  : ${(P)__var::=$__reply}
  return 0
}

function _gwt_confirm {
  local prompt="$1" default="$2" hint reply=""
  [[ "$default" == y ]] && hint="Y/n" || hint="y/N"
  print -rn -- "  ${_GWT_FMT[bold]}${prompt}${_GWT_FMT[reset]} ${_GWT_FMT[hint]}[$hint]${_GWT_FMT[reset]} ${_GWT_FMT[bold]}❯${_GWT_FMT[reset]} " >&2
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

# name<TAB>conventional port, from whatever the dev script actually invokes.
function _gwt_framework {
  case "$1" in
    *next*)      print -r -- $'next\t3000' ;;
    *nuxt*)      print -r -- $'nuxt\t3000' ;;
    *remix*)     print -r -- $'remix\t3000' ;;
    *vite*)      print -r -- $'vite\t5173' ;;
    *astro*)     print -r -- $'astro\t4321' ;;
    *rails*)     print -r -- $'rails\t3000' ;;
    *manage.py*) print -r -- $'django\t8000' ;;
    *artisan*)   print -r -- $'laravel\t8000' ;;
    *) return 1 ;;
  esac
}

function _gwt_script_port {
  print -r -- "$1" | sed -n \
    -e 's/.*--port[= ]\{1,\}\([0-9]\{2,5\}\).*/\1/p' \
    -e 's/.*-p[= ]\{1,\}\([0-9]\{2,5\}\).*/\1/p' \
    -e 's/.*PORT=\([0-9]\{2,5\}\).*/\1/p' \
    | head -1
}

# Prints key<TAB>value for stack, server and port, plus one
# step<TAB>name<TAB>command<TAB>watch-list row per step worth proposing.
# An unrecognised repo yields empty values, which just means every prompt starts blank.
function _gwt_detect_stack {
  local root="$1" pm="" deps="" server="" script="" port="" stack=""
  local manifest="" lock="" fw="" node_cmd="" s
  local -a watch rows

  if [[ -f "$root/package.json" ]]; then
    manifest=package.json
    if   [[ -f "$root/pnpm-lock.yaml" ]]; then pm=pnpm; lock=pnpm-lock.yaml
    elif [[ -f "$root/yarn.lock" ]];      then pm=yarn; lock=yarn.lock
    elif [[ -f "$root/bun.lock" ]];       then pm=bun;  lock=bun.lock
    elif [[ -f "$root/bun.lockb" ]];      then pm=bun;  lock=bun.lockb
    else pm=npm; lock=package-lock.json
    fi
    deps="$pm install"
    stack="node · $pm"
    # Both, not just the lockfile: a dependency edit lands in package.json first,
    # and installing is what regenerates the lockfile to match it.
    watch=(package.json)
    [[ -f "$root/$lock" ]] && watch+=("$lock")
    [[ -f "$root/.nvmrc" || -f "$root/.node-version" ]] && node_cmd="nvm use"
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
      fw="$(_gwt_framework "$script")"
      [[ -n "$fw" ]] && { stack+=" · ${fw%%$'\t'*}"; [[ -n "$port" ]] || port="${fw##*$'\t'}" }
    fi
  elif [[ -f "$root/Cargo.toml" ]]; then
    stack=rust; manifest=Cargo.toml; lock=Cargo.lock; deps="cargo fetch"; server="cargo run"
  elif [[ -f "$root/go.mod" ]]; then
    stack=go; manifest=go.mod; lock=go.sum; deps="go mod download"
  elif [[ -f "$root/composer.json" ]]; then
    stack=php; manifest=composer.json; lock=composer.lock; deps="composer install"
    [[ -f "$root/artisan" ]] && { stack="php · laravel"; server="php artisan serve"; port=8000 }
  elif [[ -f "$root/Gemfile" ]]; then
    stack=ruby; manifest=Gemfile; lock=Gemfile.lock; deps="bundle install"
    [[ -f "$root/bin/rails" ]] && { stack="ruby · rails"; server="bin/rails server"; port=3000 }
  elif [[ -f "$root/uv.lock" ]]; then
    stack="python · uv"; manifest=pyproject.toml; lock=uv.lock; deps="uv sync"
  elif [[ -f "$root/poetry.lock" ]]; then
    stack="python · poetry"; manifest=pyproject.toml; lock=poetry.lock; deps="poetry install"
  elif [[ -f "$root/Pipfile" ]]; then
    stack="python · pipenv"; manifest=Pipfile; lock=Pipfile.lock; deps="pipenv install"
  elif [[ -f "$root/requirements.txt" ]]; then
    stack="python · pip"; manifest=requirements.txt; deps="pip install -r requirements.txt"
    [[ -f "$root/manage.py" ]] && { stack="python · django"; server="python manage.py runserver"; port=8000 }
  fi

  if (( ! ${#watch} )); then
    if [[ -n "$lock" && -f "$root/$lock" ]]; then
      watch=("$lock")
    elif [[ -n "$manifest" && -f "$root/$manifest" ]]; then
      watch=("$manifest")
    fi
  fi

  # Deliberately unwatched: it costs nothing to repeat, and it is a change to the
  # shell the later steps run in, so skipping it would leave them on the wrong node.
  [[ -n "$node_cmd" ]] && rows+=( "node"$'\t'"$node_cmd"$'\t' )
  [[ -n "$deps" ]] && rows+=( "deps"$'\t'"$deps"$'\t'"${watch[*]}" )

  printf '%s\t%s\n' stack "$stack" server "$server" port "$port"
  for s in "${rows[@]}"; do print -r -- "step"$'\t'"$s"; done
}

# A soft note only: version managers and direnv routinely put a project's tools on
# PATH inside the worktree and nowhere else.
function _gwt_missing_bin {
  local root="$1" cmd="$2" w bin=""
  for w in ${(z)cmd}; do
    [[ "$w" == *=* ]] && continue
    bin="$w"; break
  done
  [[ -n "$bin" ]] || return 1
  if [[ "$bin" == */* ]]; then
    [[ -x "$bin" || -x "$root/$bin" ]] && return 1
  else
    (( $+commands[$bin] || $+builtins[$bin] || $+functions[$bin] || $+aliases[$bin] )) && return 1
  fi
  print -r -- "$bin"
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

function _gwt_init_preview {
  local target="$1" body="$2" width=$(_gwt_fmt_width)
  local label="${${target:h}:t}/${target:t}" line len
  len=$(( width - ${#label} - 6 ))
  (( len < 3 )) && len=3

  print -r -- "" >&2
  print -r -- "  ${_GWT_FMT[rule]}┌─${_GWT_FMT[reset]} ${_GWT_FMT[bold]}${label}${_GWT_FMT[reset]} ${_GWT_FMT[rule]}${(l:$len::─:)}${_GWT_FMT[reset]}" >&2
  for line in "${(@f)body}"; do
    if [[ -z "$line" ]]; then
      print -r -- "  ${_GWT_FMT[rule]}│${_GWT_FMT[reset]}" >&2
    elif [[ "${line## }" == '#'* ]]; then
      print -r -- "  ${_GWT_FMT[rule]}│${_GWT_FMT[reset]} ${_GWT_FMT[hint]}${line}${_GWT_FMT[reset]}" >&2
    else
      print -r -- "  ${_GWT_FMT[rule]}│${_GWT_FMT[reset]} ${line}" >&2
    fi
  done
  print -r -- "  ${_GWT_FMT[rule]}└${(l:$(( width - 3 ))::─:)}${_GWT_FMT[reset]}" >&2
  print -r -- "" >&2
}

function _gwt_init {
  local main_root="$1" repo="$2" force="$3"
  local target="$main_root/.gwtrc"

  _gwt_fmt_init

  if git -C "$main_root" ls-files --error-unmatch -- .gwtrc >/dev/null 2>&1; then
    print -r -- "${_GWT_FMT[err]}error:${_GWT_FMT[reset]} git tracks $target" >&2
    print -r -- "  .gwtrc runs as zsh, so gwt never sources a tracked one." >&2
    print -r -- "  git rm --cached .gwtrc, then run 'gwt init' again" >&2
    return 81
  fi

  if [[ -e "$target" && -z "$force" ]]; then
    print -r -- "${_GWT_FMT[err]}error:${_GWT_FMT[reset]} $target already exists" >&2
    print -r -- "  'gwt init --force' rewrites it" >&2
    return 80
  fi

  local -A det
  local -a proposed
  local line key
  for line in ${(f)"$(_gwt_detect_stack "$main_root")"}; do
    key="${line%%$'\t'*}"
    if [[ "$key" == step ]]; then
      proposed+=( "${line#*$'\t'}" )
    else
      det[$key]="${line#*$'\t'}"
    fi
  done
  (( ${#proposed} )) || proposed=( "deps"$'\t'$'\t' )

  local width=$(_gwt_fmt_width)
  print -r -- "" >&2
  print -r -- "  ${_GWT_FMT[title]}gwt init${_GWT_FMT[reset]} ${_GWT_FMT[hint]}·${_GWT_FMT[reset]} ${_GWT_FMT[bold]}${repo}${_GWT_FMT[reset]}" >&2
  _gwt_note "${target/#$HOME/~}"
  [[ -n "${det[stack]}" ]] && _gwt_note "detected ${det[stack]}"
  if [[ -t 0 ]] && [[ -o zle ]]; then
    _gwt_note "edit in place · Enter accepts · '-' clears · Ctrl-D cancels"
  else
    _gwt_note "Enter accepts the bracketed value · '-' clears · Ctrl-D cancels"
  fi

  local shadowed
  shadowed="$(_gwt_config_file "$main_root" "$repo" 2>/dev/null)"
  [[ -n "$shadowed" && "$shadowed" != "$target" ]] \
    && _gwt_warn "$shadowed applies today; a repo .gwtrc takes precedence over it"

  _gwt_section "Setup steps" \
    "Run when a worktree is created, and again on 'gwt setup'." \
    "A step that watches files is skipped while those files are unchanged."

  local -a steps
  local missing row pname pcmd pwatch
  local name cmd watched
  for row in "${proposed[@]}"; do
    pname="${row%%$'\t'*}"
    pcmd="${${row#*$'\t'}%%$'\t'*}"
    pwatch="${row##*$'\t'}"
    _gwt_ask cmd "$pname command" "$pcmd" || return 82
    [[ -n "$cmd" ]] || continue
    _gwt_ask watched "re-run when" "$pwatch" || return 82
    steps+=( "$pname"$'\t'"$watched"$'\t'"$cmd" )
    missing="$(_gwt_missing_bin "$main_root" "$cmd")" \
      && _gwt_warn "${_GWT_FMT[bold]}$missing${_GWT_FMT[reset]} is not on your PATH right now"
  done

  while :; do
    _gwt_ask name "step $(( ${#steps} + 1 )) name" "" || return 82
    [[ -n "$name" ]] || break
    if [[ "$name" == */* ]]; then
      _gwt_warn "a step name cannot contain '/'"
      continue
    fi
    _gwt_ask cmd "command" "" 4 || return 82
    [[ -n "$cmd" ]] || { _gwt_warn "no command; dropping '$name'"; continue }
    _gwt_ask watched "re-run when" "" 4 || return 82
    steps+=( "$name"$'\t'"$watched"$'\t'"$cmd" )
  done

  _gwt_section "Dev server" \
    "'gwt serve' runs this in one worktree at a time."

  local server="" port=""
  _gwt_ask server "command" "${det[server]}" || return 82
  if [[ -n "$server" ]]; then
    missing="$(_gwt_missing_bin "$main_root" "$server")" \
      && _gwt_warn "${_GWT_FMT[bold]}$missing${_GWT_FMT[reset]} is not on your PATH right now"
    while :; do
      _gwt_ask port "port" "${det[port]}" || return 82
      [[ -z "$port" || "$port" == <-> ]] && break
      _gwt_warn "a port must be a number"
      det[port]=""
    done
  fi

  local body
  body="$(_gwt_init_render "$repo" "$server" "$port" "${steps[@]}")"
  _gwt_init_preview "$target" "$body"

  _gwt_confirm "Write it?" y || {
    print -r -- "  ${_GWT_FMT[hint]}cancelled; nothing written${_GWT_FMT[reset]}" >&2
    return 82
  }

  print -r -- "$body" > "$target" || {
    print -r -- "${_GWT_FMT[err]}error:${_GWT_FMT[reset]} could not write $target" >&2
    return 83
  }
  _gwt_register_excludes "$main_root"

  print -r -- "" >&2
  print -r -- "  ${_GWT_FMT[ok]}✓${_GWT_FMT[reset]} wrote ${_GWT_FMT[bold]}${${target:h}:t}/${target:t}${_GWT_FMT[reset]}" >&2
  print -r -- "" >&2
  (( ${#steps} )) && _gwt_note "$(printf '%-14s%s' 'gwt setup' 'run the steps in this worktree')"
  [[ -n "$server" ]] && _gwt_note "$(printf '%-14s%s' 'gwt serve' 'point the dev server here')"
  _gwt_note "$(printf '%-14s%s' 'gwt_teardown' "add one to the same file to run just before 'gwt rm'")"
  print -r -- "" >&2
  return 0
}
