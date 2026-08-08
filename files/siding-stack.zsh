# siding — the dev stack half: pointing a repo's docker-compose stack at a
# worktree, and running two stacks of one repo at once.
#
# Split out of siding-wt.zsh because it is self-contained and was half the
# file. Sourced by it; not meant to be sourced directly.

# ─────────────────────────────────────────────────────────────────────────────
# Dev stack — make the console test the code Claude is editing
#
# Every compose file here bind-mounts the repo directory into the container
# (`.:/rails`), so a console opened against the running stack tests the MAIN
# CHECKOUT, not the worktree. Splitting your terminal does not fix that; it only
# puts the wrong console closer to you. wsup re-points a repo's stack at a tree.
#
# Two things make this work, both learned the hard way:
#
# 1. A fixed compose project name per repo. These compose files hardcode
#    container_name, so two stacks of one repo can never coexist — and starting
#    from a worktree directory would otherwise pick up that directory's name as
#    the project, leaving `down` unable to find the containers it had to remove.
#    Result: "container name /servicea_redis is already in use".
#
# 2. A generated override that mounts the parent repo's .git. In a worktree,
#    .git is a FILE containing `gitdir: /abs/host/path/.git/worktrees/<name>` —
#    a host path with no counterpart inside the container. Any git command there
#    dies with `fatal: not a git repository: (null)`, exit 128, which is exactly
#    how the app container died. It matters because these Gemfiles carry
#    git-sourced gems (shared-gem) and the entrypoint runs git before bundle.
#    Mounting <repo>/.git at its own absolute path makes the pointer resolve.
#
# CAVEAT: the stack keeps its usual database name and volume, so migrations run
# from a task branch mutate the shared dev database. Fine for trees cut from
# origin/main; be deliberate when a branch adds destructive migrations.
# ─────────────────────────────────────────────────────────────────────────────

_ws_compose_file() {
  local p=$1 f
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f "$p/$f" ]] && { print -r -- "$p/$f"; return 0; }
  done
  return 1
}

# The service that owns the source bind-mount — the one a console belongs in.
# Detected, never assumed: `app` in tms, `web` in gms/wms/ems/harmony/ams,
# `frontend` in the frontend repo, and a new repo will invent its own.
_ws_app_svc() {
  local f; f=$(_ws_compose_file "$1") || return 1
  awk '
    /^services:[[:space:]]*$/ { ins=1; next }
    ins && /^[^[:space:]]/    { ins=0 }
    ins && /^  [a-zA-Z0-9_.-]+:[[:space:]]*$/ {
      cur=$0; gsub(/[[:space:]:]/,"",cur); has_build=0
    }
    ins && /^[[:space:]]+build:/ { has_build=1 }
    ins && /^[[:space:]]+-[[:space:]]+\.(\/[^:]*)?:\/(rails|app|srv|usr\/src)/ {
      if (has_build) { print cur; exit }
      if (fallback=="") fallback=cur
    }
    END { if (fallback!="") print fallback }
  ' "$f"
}

_ws_statedir() { print -r -- "$HOME/.siding-stacks"; }
_ws_project()  { print -r -- "${${1:t}:l}"; }

_ws_stack_owner() {
  local s="$(_ws_statedir)/$1"
  [[ -f "$s" ]] && print -r -- "$(<"$s")"
}

# Resolve <task|main> <repo-path> to a directory. "main" means the main checkout.
_ws_dir_for() {
  if [[ "$1" == "main" ]]; then print -r -- "$2"
  else print -r -- "$(_ws_wtbase)/${1}--${2:t}"; fi
}

# Worktrees do not contain gitignored local config, because git never tracked
# it. Copy rather than symlink: master.key is read from inside the container,
# where a symlink to a host path would dangle.
_ws_seed_local() {
  local src=$1 dst=$2 f rel
  for f in "$src"/.env "$src"/.env.*(N) "$src"/config/master.key; do
    [[ -f "$f" ]] || continue
    case "${f:t}" in *.example|*.sample|*.template) continue ;; esac
    rel="${f#$src/}"
    [[ -e "$dst/$rel" ]] && continue
    mkdir -p "$dst/${rel:h}" 2>/dev/null
    cp "$f" "$dst/$rel" && print -r -- "  seeded $rel"
  done
}

# Run docker compose for a repo against a given tree, with the fixed project
# name and the gitdir override when one is in play.
_ws_dc() {
  local p=$1 dir=$2; shift 2
  local cf; cf=$(_ws_compose_file "$dir") || { print -u2 "no compose file in $dir"; return 1; }
  local ov="$(_ws_statedir)/${p:t}.override.yml"
  local -a f; f=(-f "$cf")
  [[ -f "$ov" ]] && f+=(-f "$ov")
  (cd "$dir" && docker compose -p "$(_ws_project "$p")" "${f[@]}" "$@")
}

# wsup <task|main> <repo> — point this repo's dev stack at that tree.
wsup() {
  local task=$1 repo=$2
  if [[ -z "$task" || -z "$repo" ]]; then
    print -u2 "usage: wsup <task|main> <repo>"; return 1
  fi
  local p; p=$(_ws_repo "$repo") || { print -u2 "wsup: unknown repo '$repo'"; return 1; }
  _ws_compose_file "$p" >/dev/null || { print -u2 "wsup: $repo has no compose file"; return 1; }
  local dir; dir=$(_ws_dir_for "$task" "$p")
  [[ -d "$dir" ]] || { print -u2 "wsup: no tree at $dir"; return 1; }

  local ov="$(_ws_statedir)/${p:t}.override.yml"
  mkdir -p "$(_ws_statedir)"

  local owner; owner=$(_ws_stack_owner "${p:t}"); : ${owner:=$p}
  if [[ -d "$owner" ]]; then
    print -r -- "stopping ${p:t} stack (serving ${owner:t}) ..."
    _ws_dc "$p" "$owner" down --remove-orphans 2>&1 | tail -2
  fi

  # Build the override BEFORE bringing the new tree up.
  if [[ "$dir" == "$p" ]]; then
    rm -f "$ov"
  else
    local svc; svc=$(_ws_app_svc "$p")
    if [[ -z "$svc" ]]; then
      print -u2 "wsup: ${p:t} has no source bind-mount — its code is baked into"
      print -u2 "      the image, so a worktree cannot be served without a rebuild."
      return 1
    fi
    _ws_seed_local "$p" "$dir"
    cat > "$ov" <<EOF
# generated by wsup — do not edit
services:
  ${svc}:
    volumes:
      - ${p}/.git:${p}/.git
EOF
  fi

  print -r -- "starting ${p:t} stack from ${dir:t} ..."
  _ws_dc "$p" "$dir" up -d 2>&1 | tail -3
  print -r -- "$dir" > "$(_ws_statedir)/${p:t}"
  print -r -- "→ ${p:t} stack now serves ${dir:t}"
}

# wsdown <repo> — stop whichever tree currently owns the stack.
wsdown() {
  local repo=$1
  [[ -z "$repo" ]] && { print -u2 "usage: wsdown <repo>"; return 1; }
  local p; p=$(_ws_repo "$repo") || { print -u2 "wsdown: unknown repo '$repo'"; return 1; }
  local owner; owner=$(_ws_stack_owner "${p:t}"); : ${owner:=$p}
  _ws_dc "$p" "$owner" down --remove-orphans 2>&1 | tail -2
  rm -f "$(_ws_statedir)/${p:t}" "$(_ws_statedir)/${p:t}.override.yml"
  print -r -- "→ ${p:t} stack down"
}

# wsstack — which tree each repo's stack is serving.
wsstack() {
  local p owner
  printf "%-20s %s\n" REPO "STACK SERVING"
  for p in ""/*(/N) ""/apps/*(/N) ""/gems/*(/N); do
    _ws_compose_file "$p" >/dev/null || continue
    owner=$(_ws_stack_owner "${p:t}")
    if [[ -z "$owner" ]];       then printf "%-20s %s\n" "${p:t}" "-"
    elif [[ "$owner" == "$p" ]]; then printf "%-20s %s\n" "${p:t}" "main checkout"
    else                              printf "%-20s %s\n" "${p:t}" "${owner:t}"; fi
  done
  local f proj dir first=1
  for f in "$(_ws_statedir)"/iso-*(N); do
    (( first )) && { print -r -- ""; printf "%-20s %s\n" ISOLATED "SERVING"; first=0 }
    proj=${${f:t}#iso-}
    dir=$(cat "$f" 2>/dev/null)
    printf "%-20s %s\n" "$proj" "${dir:t}"
  done
}

# wsconsole <task|main> <repo> [rails-subcommand] — console in the container
# serving that tree, or locally when the repo has no compose file.
wsconsole() {
  local task=$1 repo=$2
  if [[ -z "$task" || -z "$repo" ]]; then
    print -u2 "usage: wsconsole <task|main> <repo> [rails-subcommand]"; return 1
  fi
  shift 2
  # An array, never a joined string: `wsconsole … runner 'puts "a b"'` must
  # survive as one argument, and word-splitting a scalar shreds the quoted Ruby.
  local -a cmd; cmd=("$@"); (( ${#cmd} )) || cmd=(console)
  # An interactive console needs the TTY; a scripted one-liner has none.
  local -a tflag; [[ -t 0 ]] || tflag=(-T)

  local p; p=$(_ws_repo "$repo") || { print -u2 "wsconsole: unknown repo '$repo'"; return 1; }
  local dir; dir=$(_ws_dir_for "$task" "$p")
  [[ -d "$dir" ]] || { print -u2 "wsconsole: no tree at $dir"; return 1; }

  if ! _ws_compose_file "$p" >/dev/null; then
    if [[ ! -x "$dir/bin/rails" ]]; then
      print -u2 "wsconsole: ${p:t} has no compose file and no bin/rails — not a"
      print -u2 "           containerised Rails app. Open a shell there instead:"
      print -u2 "           cd $dir"
      return 1
    fi
    (cd "$dir" && bin/rails "${cmd[@]}"); return
  fi
  local svc; svc=$(_ws_app_svc "$p")
  [[ -z "$svc" ]] && { print -u2 "wsconsole: no app service in ${p:t} compose"; return 1; }

  local owner; owner=$(_ws_stack_owner "${p:t}"); : ${owner:=$p}
  if [[ "$owner" != "$dir" ]]; then
    print -u2 "wsconsole: ${p:t} stack is serving ${owner:t}, not ${dir:t}."
    print -u2 "           run:  wsup $task $repo"
    return 1
  fi
  _ws_dc "$p" "$dir" exec "${tflag[@]}" "$svc" bin/rails "${cmd[@]}"
}

# wslogs <repo> — follow the app service logs of whatever the stack serves.
wslogs() {
  local repo=$1
  [[ -z "$repo" ]] && { print -u2 "usage: wslogs <repo>"; return 1; }
  local p; p=$(_ws_repo "$repo") || return 1
  local owner; owner=$(_ws_stack_owner "${p:t}"); : ${owner:=$p}
  local svc; svc=$(_ws_app_svc "$p")
  _ws_dc "$p" "$owner" logs -f ${svc:+$svc}
}

# wstask <task> <repo> — the whole workspace for one task, in one command.
# Creates the worktree if absent, then a tmux session of three panes all rooted
# in it: Claude left, a shell for the console top right, logs bottom right.
# Detach with Ctrl-a d; run wstask again to reattach with everything still live.
wstask() {
  local task=$1 repo=$2
  if [[ -z "$task" || -z "$repo" ]]; then
    print -u2 "usage: wstask <task> <repo>"; return 1
  fi
  local p; p=$(_ws_repo "$repo") || { print -u2 "wstask: unknown repo '$repo'"; return 1; }
  local dir="$(_ws_wtbase)/${task}--${p:t}"
  [[ -d "$dir" ]] || wsnew "$task" "$repo" >/dev/null || return 1

  local sess="${task}--${p:t}"; sess=${sess//./_}
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    tmux new-session -d -s "$sess" -c "$dir" -n "${p:t}"
    tmux send-keys  -t "$sess:1.1" "claude" C-m
    tmux split-window -h -l 42% -c "$dir" -t "$sess:1"
    tmux split-window -v -l 45% -c "$dir" -t "$sess:1.2"
    tmux send-keys  -t "$sess:1.3" "wsup $task $repo && wslogs $repo" C-m
    tmux select-pane -t "$sess:1.2"
  fi
  if [[ -n "$TMUX" ]]; then tmux switch-client -t "$sess"
  else tmux attach-session -t "$sess"; fi
}

# pick — the repo picker, typed rather than bound. A keybinding that some layer
# between the keyboard and tmux swallows leaves no way in; a command always
# works. Same picker the popup runs.
pick() { "$HOME/.siding-pick.zsh"; }

# ghtheme [name] — swap the Ghostty theme. No argument lists them; with a name
# it rewrites the one line in ~/.config/ghostty/config. Reload with ⌘⇧, in
# Ghostty (or just reopen it) to see the change.
ghtheme() {
  local cfg="$HOME/.config/ghostty/config"
  local bin; bin=$(_siding_ghostty) || { print -u2 "ghtheme: Ghostty not found — themes are a Ghostty feature"; return 1 }
  if [[ -z "$1" ]]; then
    print -r -- "current: $(grep '^theme = ' "$cfg" | sed 's/theme = //')"
    print -r -- "usage: ghtheme <name>   (fuzzy match; try: ghtheme green)"
    print -r -- ""
    "$bin" +list-themes 2>/dev/null | sed 's/ (resources)//' | grep -iE "green|matrix|cyber|neon|gruvbox|dracula|tokyo" | head -20
    return 0
  fi
  local match
  match=$("$bin" +list-themes 2>/dev/null | sed 's/ (resources)//' | grep -ix "$1" | head -1)
  [[ -z "$match" ]] && match=$("$bin" +list-themes 2>/dev/null | sed 's/ (resources)//' | grep -i "$1" | head -1)
  [[ -z "$match" ]] && { print -u2 "ghtheme: no theme matching '$1'"; return 1 }
  if grep -q '^theme = ' "$cfg"; then
    perl -pi -e "s/^theme = .*/theme = $match/" "$cfg"
  else
    print -r -- "theme = $match" >> "$cfg"
  fi
  print -r -- "theme → $match   (reload Ghostty with ⌘⇧, or reopen it)"
}

# ws — attach to (or create) the myworkspace workspace session. Use after ⌥d has
# dropped you to a plain shell.
ws() { tmux new-session -A -s "${WS_NAME:-myworkspace}" -n home -c "$WS_ROOT" "$HOME/.siding-home.zsh"; }

# wsdir [dir] [name] — the same idea for anything outside the workspace, e.g. a
# personal project. Its own tmux session, so it persists across closing Ghostty
# and stays entirely separate from the myworkspace windows. ⌥s switches between.
wsdir() {
  local dir=${1:-$PWD} name=$2
  dir=${dir:A}
  [[ -d "$dir" ]] || { print -u2 "wsdir: no such directory: $dir"; return 1 }
  : ${name:=${dir:t}}
  name=${name//[.:]/_}
  tmux new-session -A -s "$name" -c "$dir"
}


# wsdoctor — check the setup on this machine. Run it first whenever something
# behaves oddly, and after installing on a new Mac.
wsdoctor() {
  local ok=0 warn=0 bad=0
  local G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[90m' O=$'\e[0m'
  pass() { print -r -- "  ${G}ok${O}    $1"; (( ok++ )); return 0 }
  note() { print -r -- "  ${Y}warn${O}  $1"; (( warn++ )); return 0 }
  fail() { print -r -- "  ${R}fail${O}  $1"; (( bad++ )); return 0 }

  print -r -- ""
  print -r -- "  workspace doctor"
  print -r -- ""

  # tools
  command -v tmux >/dev/null && pass "tmux $(tmux -V | awk '{print $2}')" || fail "tmux missing — brew install tmux"
  pass "platform $(uname -s)"
  local gbin; gbin=$(_siding_ghostty) \
    && pass "Ghostty found" \
    || note "Ghostty not found — optional; tmux runs in any terminal"
  command -v git >/dev/null && pass "git $(git --version | awk '{print $3}')" || fail "git missing"
  command -v docker >/dev/null && pass "docker present" || note "docker missing — wsup/wsconsole inert, rest works"

  # config
  if [[ -f "$HOME/.siding.env" ]]; then pass "~/.siding.env present"; else fail "~/.siding.env missing"; fi
  if [[ -d "$WS_ROOT" ]]; then pass "WS_ROOT=$WS_ROOT"; else fail "WS_ROOT does not exist: $WS_ROOT"; fi
  [[ -n "$WS_NAME" ]] && pass "WS_NAME=$WS_NAME" || note "WS_NAME empty"

  # repos discoverable
  local -a repos
  local d
  for d in "$WS_ROOT"/*(/N) "$WS_ROOT"/apps/*(/N) "$WS_ROOT"/gems/*(/N); do
    [[ -e "$d/.git" ]] && repos+=("$d")
  done
  (( ${#repos} )) && pass "${#repos} repo(s) visible to the picker" \
                  || fail "no git repos found under $WS_ROOT — is WS_ROOT right?"

  # scripts
  local f n missing=0
  for n in wt pick open newtask home launch; do
    f="$HOME/.siding-$n.zsh"
    [[ -f "$f" ]] || { fail "missing $f"; missing=1; continue }
    zsh -n "$f" 2>/dev/null || { fail "syntax error in $f"; missing=1 }
  done
  (( missing )) || pass "all scripts present and parse"

  # wiring
  grep -q 'siding-wt.zsh' "$HOME/.zshrc" 2>/dev/null \
    && pass "~/.zshrc sources the helpers" || fail "~/.zshrc does not source ~/.siding-wt.zsh"
  if [[ -f "$HOME/.tmux.conf" ]]; then
    if tmux -f "$HOME/.tmux.conf" -L doctorcheck start-server \; kill-server 2>/dev/null; then
      pass "~/.tmux.conf loads without errors"
    else
      fail "~/.tmux.conf has errors — one bad option aborts the whole file"
    fi
  else fail "~/.tmux.conf missing"; fi
  if [[ -n "$gbin" ]]; then
    local gerr
    gerr=$("$gbin" +show-config 2>&1 | grep -ci error)
    (( gerr == 0 )) && pass "Ghostty config valid" || fail "Ghostty config reports $gerr error(s)"
    "$gbin" +show-config 2>/dev/null | grep -q 'siding-launch' \
      && pass "Ghostty launches the workspace" || note "Ghostty config does not run ~/.siding-launch.zsh"
  fi
  command -v pbcopy >/dev/null 2>&1 || command -v wl-copy >/dev/null 2>&1 || \
    command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1 || \
    command -v clip.exe >/dev/null 2>&1 || note "no clipboard tool — copy-mode y will discard"

  # state worth knowing about
  local stale=0
  for d in "$(_ws_wtbase)"/*(/N); do
    (( $(_ws_age_days "$d") > 14 )) && (( stale++ ))
  done
  (( stale )) && note "$stale worktree(s) older than 14 days — wswip to review" \
              || pass "no stale worktrees"


  # identity — the thing that fails silently and is only noticed on a push
  if [[ -n "$SIDING_PROFILE" ]]; then
    pass "profile $SIDING_PROFILE"
    if [[ -n "$WS_GH" ]] && command -v gh >/dev/null 2>&1; then
      local active; active=$(gh api user --jq .login 2>/dev/null)
      if [[ "$active" == "$WS_GH" ]]; then pass "gh account $active matches profile"
      else note "gh is $active but this profile is $WS_GH — siding ws $SIDING_PROFILE"; fi
    fi
    # Does git actually resolve to this identity inside the workspace? Ask git
    # rather than assume: insteadOf rules rewrite silently.
    local rd; rd=$(_ws_repodirs | head -1)
    if [[ -n "$rd" ]]; then
      local e; e=$(git -C "$rd" config user.email 2>/dev/null)
      if [[ -z "$e" ]]; then note "git has no email in $WS_ROOT — check ~/.gitconfig includeIf"
      elif [[ -n "$WS_EMAIL" && "$e" != "$WS_EMAIL" ]]; then
        fail "git email in workspace is $e, profile expects $WS_EMAIL"
      else pass "git identity $e"; fi
      local url; url=$(git -C "$rd" ls-remote --get-url origin 2>/dev/null)
      local host=${${url#*@}%%:*}
      if [[ -n "$WS_SSH_HOST" && -n "$host" && "$host" != "$WS_SSH_HOST" ]]; then
        fail "remotes resolve to $host, profile expects $WS_SSH_HOST"
      elif [[ -n "$host" ]]; then pass "remotes resolve to $host"; fi
    fi
  else
    note "no profile loaded — siding profile list"
  fi
  print -r -- ""
  print -r -- "  ${G}$ok ok${O}   ${Y}$warn warn${O}   ${R}$bad fail${O}"
  print -r -- ""
  (( bad == 0 ))
}


# ─────────────────────────────────────────────────────────────────────────────
# Isolated stacks — two features of one repo running at the same time
#
# `wsup` re-points a repo's single stack at a tree. That is enough when you work
# on one thing per repo, and it is the default because it costs nothing extra.
# When you genuinely need two trees of the SAME repo up at once, wsupiso gives
# each its own compose project.
#
# Compose already isolates almost everything per project — networks, and
# crucially NAMED VOLUMES, which is why each isolated stack gets its own
# postgres volume and therefore its own database. No database renaming needed:
# a task branch's migrations cannot reach another tree's data.
#
# Only two things had to be overridden: container_name, which these files
# hardcode, and host ports, which are fixed. See siding-stackgen.py.
# ─────────────────────────────────────────────────────────────────────────────

_ws_isoproj() { print -r -- "${${1:l}//[^a-z0-9]/-}-${${2:l}//[^a-z0-9]/-}"; }

# wsupiso <task> <repo> — bring up an isolated stack for that worktree.
wsupiso() {
  local task=$1 repo=$2
  if [[ -z "$task" || -z "$repo" ]]; then
    print -u2 "usage: wsupiso <task> <repo>     (isolated stack: own containers, ports and database)"
    return 1
  fi
  local p; p=$(_ws_repo "$repo") || { print -u2 "wsupiso: unknown repo '$repo'"; return 1; }
  _ws_compose_file "$p" >/dev/null || { print -u2 "wsupiso: ${p:t} has no compose file"; return 1; }
  local dir; dir=$(_ws_dir_for "$task" "$p")
  [[ -d "$dir" ]] || { print -u2 "wsupiso: no tree at $dir"; return 1; }
  [[ "$dir" == "$p" ]] && { print -u2 "wsupiso: 'main' is the shared stack — use wsup main $repo"; return 1; }

  local svc; svc=$(_ws_app_svc "$p")
  [[ -z "$svc" ]] && { print -u2 "wsupiso: ${p:t} bakes its code into the image; a worktree cannot be served"; return 1; }

  mkdir -p "$(_ws_statedir)"
  local proj; proj=$(_ws_isoproj "${p:t}" "$task")
  local ov="$(_ws_statedir)/$proj.override.yml"
  local cf; cf=$(_ws_compose_file "$dir")

  _ws_seed_local "$p" "$dir"

  # Resolve the config with docker itself, then generate the override from it.
  local tmpjson="$(_ws_statedir)/$proj.config.json"
  (cd "$dir" && docker compose -f "$cf" config --format json > "$tmpjson") 2>/dev/null \
    || { print -u2 "wsupiso: could not resolve compose config"; return 1 }

  # A deterministic starting offset per project, so the same task keeps the same
  # ports across restarts; the generator walks upward if any are taken.
  local off=$(( 1000 + (${#proj} * 137) % 3000 ))
  local out
  # The gitdir mount goes through the generator so it lands inside the app
  # service's own block — a second block for the same service is a duplicate
  # mapping key and compose rejects the file outright.
  # Borrow any cache volume the shared stack has already populated. Data
  # volumes are deliberately NOT shared — those are what isolate the database.
  local shared_proj="$(_ws_project "$p")"
  local -a shargs
  local v ext
  for v in $(python3 -c "import json,sys;print(' '.join((json.load(open(sys.argv[1])).get('volumes') or {}).keys()))" "$tmpjson" 2>/dev/null); do
    case "$v" in *cache*|*bundle*|*gems*)
      ext="${shared_proj}_${v}"
      docker volume inspect "$ext" >/dev/null 2>&1 && shargs+=("$v=$ext") ;;
    esac
  done
  (( ${#shargs} )) && print -r -- "  sharing cache volume(s): ${shargs}"
  out=$(python3 "$HOME/.siding-stackgen.py" "$proj" "$off" "$tmpjson" "$ov" "$svc" "$p/.git" "${shargs[@]}") || return 1
  rm -f "$tmpjson"

  print -r -- "starting isolated stack $proj from ${dir:t} ..."
  (cd "$dir" && docker compose -p "$proj" -f "$cf" -f "$ov" up -d 2>&1 | tail -3)
  print -r -- "$dir" > "$(_ws_statedir)/iso-$proj"
  print -r -- ""
  print -r -- "  project   $proj"
  print -r -- "  tree      $dir"
  print -r -- "$out" | sed -n '2,$p' | sed 's/^/  port      /'
  print -r -- "  database  own volume — this stack cannot touch another tree's data"
}

# wsdowniso <task> <repo> — stop and forget an isolated stack.
wsdowniso() {
  local task=$1 repo=$2
  local p; p=$(_ws_repo "$repo") || return 1
  local proj; proj=$(_ws_isoproj "${p:t}" "$task")
  local dir; dir=$(cat "$(_ws_statedir)/iso-$proj" 2>/dev/null)
  local ov="$(_ws_statedir)/$proj.override.yml"
  [[ -d "$dir" ]] || { print -u2 "wsdowniso: no isolated stack '$proj'"; return 1 }
  (cd "$dir" && docker compose -p "$proj" -f "$(_ws_compose_file "$dir")" -f "$ov" down --remove-orphans 2>&1 | tail -2)
  rm -f "$(_ws_statedir)/iso-$proj" "$ov"
  print -r -- "→ $proj down"
}

