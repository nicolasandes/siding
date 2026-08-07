# siding — a Ghostty + tmux workspace: one window per repo, one worktree per
# task, and a dev stack that follows whichever tree you are editing.
#
# Portable by design. Everything machine-specific lives in ~/.siding.env
# (WS_ROOT, WS_NAME); this file makes no assumption about how the workspace is
# laid out, finding repos both directly under WS_ROOT and grouped in apps/gems.
#
# Sourced from ~/.zshrc. Run `wsdoctor` if anything misbehaves.

# Per-machine settings. Profiles first (one workspace + identity each), falling
# back to the single-workspace file from before profiles existed.
if [[ -d "$HOME/.siding/profiles" ]]; then
  _sd=$([[ -f "$HOME/.siding/default" ]] && cat "$HOME/.siding/default" || print -r -- work)
  [[ -f "$HOME/.siding/profiles/$_sd.env" ]] && { source "$HOME/.siding/profiles/$_sd.env"; export SIDING_PROFILE=$_sd }
  unset _sd
elif [[ -f "$HOME/.siding.env" ]]; then
  source "$HOME/.siding.env"
fi
export WS_ROOT="${WS_ROOT:-$HOME/dev}"
export WS_NAME="${WS_NAME:-${WS_ROOT:t}}"
export WS_GH WS_EMAIL WS_SSH_HOST

_ws_wtbase() { print -r -- "$WS_ROOT/.claude/worktrees"; }

# Resolve a repo shorthand to its checkout path. Accepts the exact directory
# name or a suffix (tms -> apps/service-a).
_ws_repo() {
  local r=$1 p
  # A path to a checkout resolves to itself, so callers can pass either a
  # shorthand or a directory. The picker passes a directory, which also avoids
  # the ambiguity of shared-gem existing under both apps/ and gems/.
  [[ -n "$r" && -e "$r/.git" ]] && { print -r -- "${r:A}"; return 0; }
  # Both workspace shapes: repos directly in the root (a flat ~/dev/project
  # layout) and repos grouped under apps/ or gems/. No bare globs in the for
  # list — an unmatched glob is a hard error in zsh, not an empty result.
  local -a cands
  local d
  cands=("$WS_ROOT/$r" "$WS_ROOT/apps/$r" "$WS_ROOT/gems/$r")
  # Suffix match, so `tms` finds service-a without hardcoding any prefix.
  for d in "$WS_ROOT"/*(/N) "$WS_ROOT"/apps/*(/N) "$WS_ROOT"/gems/*(/N); do
    [[ "${d:t}" == *"-$r" || "${d:t}" == *"_$r" ]] && cands+=("$d")
  done
  for p in "${cands[@]}"; do
    if [[ -e "$p/.git" ]]; then print -r -- "${p:A}"; return 0; fi
  done
  return 1
}

# The remote's default branch (main here, master for alex_hr_app and
# delivery_report) — read from origin/HEAD, never from the local checkout.
_ws_base_branch() {
  local p=$1 b
  b=$(git -C "$p" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) \
    && { print -r -- "${b#origin/}"; return 0; }
  git -C "$p" show-ref --verify --quiet refs/remotes/origin/main \
    && { print -r -- main; return 0; }
  print -r -- master
}

_ws_age_days() {
  local d=$1 mt now
  mt=$(stat -f %m "$d" 2>/dev/null) || { print -r -- '?'; return; }
  now=$(date +%s)
  print -r -- $(( (now - mt) / 86400 ))
}

# wsclaude — start an agent session at the workspace root, where the
# workspace-level config, skills, agents and hooks live.
wsclaude() { cd "$WS_ROOT" && claude "$@"; }

# wsnew <task> <repo> [branch] — isolated worktree off origin's default branch.
wsnew() {
  local task=$1 repo=$2 br=$3
  if [[ -z "$task" || -z "$repo" ]]; then
    print -u2 "usage: wsnew <task> <repo> [branch]"
    print -u2 "  e.g. wsnew hotfix-auth gms"
    return 1
  fi
  local p; p=$(_ws_repo "$repo") || { print -u2 "wsnew: unknown repo '$repo'"; return 1; }
  local name=${p:t}
  local base; base=$(_ws_base_branch "$p")
  : ${br:=ai/$task}
  local dir="$(_ws_wtbase)/${task}--${name}"

  if [[ -e "$dir" ]]; then
    print -u2 "wsnew: $dir already exists"
    return 1
  fi

  git -C "$p" fetch origin --quiet || return 1
  git -C "$p" worktree add "$dir" -b "$br" "origin/$base" || return 1

  print -r -- "→ $dir"
  print -r -- "  $name  $br  off origin/$base"
  cd "$dir"
}

# wswip — every task worktree across the workspace. Main checkouts excluded;
# they are meant to stay clean on their default branch.
wswip() {
  local p wt br dirty age pr found=0 nopr=0
  [[ "$1" == "--fast" ]] && nopr=1     # skip the gh lookups
  printf "%-18s %-26s %-30s %5s %5s  %s\n" REPO TASK BRANCH DIRTY DAYS PR
  printf "%-18s %-26s %-30s %5s %5s  %s\n" "------------------" \
    "--------------------------" "------------------------------" \
    "-----" "-----" "--"
  for p in "$WS_ROOT" "$WS_ROOT"/*(/N) "$WS_ROOT"/apps/*(/N) "$WS_ROOT"/gems/*(/N); do
    p=${p%/}
    [[ -e "$p/.git" ]] || continue
    git -C "$p" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        worktree\ *) wt=${line#worktree } ;;
        branch\ *)   br=${line#branch refs/heads/} ;;
        '')
          if [[ -n "$wt" && "$wt" != "$p" ]]; then
            dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            age=$(_ws_age_days "$wt")
            pr=""; (( nopr )) || pr=$(_ws_pr "$wt" "$br")
            printf "%-18s %-26s %-30s %5s %5s  %s\n" "${p:t}" "${wt:t}" "${br:-detached}" "$dirty" "$age" "${pr:--}"
            found=1
          fi
          wt= br=
          ;;
      esac
    done
  done
  (( found )) || print -r -- "(no task worktrees — all clean)"
}

# wsdone <task> <repo> [--force] — remove a task worktree. Refuses when it holds
# uncommitted changes or commits that were never pushed; that refusal is the
# whole point, since silent abandonment is what left four orphan trees behind.
wsdone() {
  local task=$1 repo=$2 force=$3
  if [[ -z "$task" || -z "$repo" ]]; then
    print -u2 "usage: wsdone <task> <repo> [--force]"
    return 1
  fi
  local p; p=$(_ws_repo "$repo") || { print -u2 "wsdone: unknown repo '$repo'"; return 1; }
  local dir="$(_ws_wtbase)/${task}--${p:t}"
  [[ -d "$dir" ]] || { print -u2 "wsdone: no worktree at $dir"; return 1; }

  local br; br=$(git -C "$dir" branch --show-current 2>/dev/null)

  if [[ "$force" != "--force" ]]; then
    local dirty; dirty=$(git -C "$dir" status --porcelain | wc -l | tr -d ' ')
    if (( dirty > 0 )); then
      print -u2 "wsdone: $dir has $dirty uncommitted change(s). Commit, or pass --force."
      return 1
    fi
    if [[ -n "$br" ]] && ! git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$br"; then
      local ahead; ahead=$(git -C "$dir" rev-list --count "origin/$(_ws_base_branch "$p")..HEAD" 2>/dev/null)
      if (( ${ahead:-0} > 0 )); then
        print -u2 "wsdone: $br has $ahead unpushed commit(s) and no remote branch."
        print -u2 "        git -C $dir push -u origin $br    (or pass --force to discard)"
        return 1
      fi
    fi
  fi

  [[ "$PWD" == "$dir"* ]] && cd "$WS_ROOT"
  git -C "$p" worktree remove "$dir" ${force:+--force} || return 1
  print -r -- "removed $dir"

  # -d refuses an unmerged branch, which would strand the ref exactly like the
  # four orphans this replaces. --force means the user already accepted the loss.
  if [[ -n "$br" ]]; then
    if [[ "$force" == "--force" ]]; then
      git -C "$p" branch -D "$br" >/dev/null 2>&1 && print -r -- "deleted branch $br"
    elif git -C "$p" branch -d "$br" >/dev/null 2>&1; then
      print -r -- "deleted branch $br"
    else
      print -r -- "kept branch $br (unmerged — delete with: git -C $p branch -D $br)"
    fi
  fi
}

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
  local bin=/Applications/Ghostty.app/Contents/MacOS/ghostty
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

# Back-compat: the ax* names this started life with. The setup is not tied to
# any one workspace any more, so ws* is the real vocabulary; these remain so
# muscle memory and older notes keep working.
alias ax=wsclaude   axnew=wsnew   axwip=wswip   axdone=wsdone
alias axup=wsup     axdown=wsdown axstack=wsstack
alias axconsole=wsconsole axlogs=wslogs axtask=wstask

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
  [[ -d /Applications/Ghostty.app ]] && pass "Ghostty installed" || note "Ghostty missing — brew install --cask ghostty"
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
  if [[ -d /Applications/Ghostty.app ]]; then
    local gerr
    gerr=$(/Applications/Ghostty.app/Contents/MacOS/ghostty +show-config 2>&1 | grep -ci error)
    (( gerr == 0 )) && pass "Ghostty config valid" || fail "Ghostty config reports $gerr error(s)"
    /Applications/Ghostty.app/Contents/MacOS/ghostty +show-config 2>/dev/null | grep -q 'siding-launch' \
      && pass "Ghostty launches the workspace" || note "Ghostty config does not run ~/.siding-launch.zsh"
  fi

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
    local probe; probe=$(command ls -d "$WS_ROOT"/*/.git(N) "$WS_ROOT"/apps/*/.git(N) 2>/dev/null | head -1)
    if [[ -n "$probe" ]]; then
      local rd=${probe:h}
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
# siding — one entry point. The ws* functions above stay as shortcuts; this is
# the discoverable face of them, so there is one word to remember and
# `siding help` lists the rest.
# ─────────────────────────────────────────────────────────────────────────────
siding() {
  local cmd=${1:-help}; shift 2>/dev/null
  case "$cmd" in
    open|pick)   "$HOME/.siding-pick.zsh" ;;
    new)         wsnew "$@" ;;
    list|wip)    wswip "$@" ;;
    tidy)        sidingtidy "$@" ;;
    drop|done)   wsdone "$@" ;;
    stack)       [[ -n "$1" ]] && wsup "$@" || wsstack ;;
    down)        wsdown "$@" ;;
    console)     wsconsole "$@" ;;
    logs)        wslogs "$@" ;;
    task)        wstask "$@" ;;
    attach)      ws ;;
    ws|workspace) sidingws "$@" ;;
    profile)
      case "${1:-list}" in
        list|"")  sidingprofile_list ;;
        show)     sidingprofile_load "${2:-}" && sidingwhoami ;;
        use)      [[ -n "$2" ]] && { print -r -- "$2" > "$(_siding_dir)/default"; print -r -- "default profile → $2" } ;;
        add)      shift; sidingprofile_add "$@" ;;
        *)        print -u2 "siding profile: list | show <name> | use <name> | add <name> …" ; return 1 ;;
      esac ;;
    whoami)      sidingwhoami "$@" ;;
    dir)         wsdir "$@" ;;
    theme)       ghtheme "$@" ;;
    doctor)      wsdoctor ;;
    agent)       wsclaude "$@" ;;
    help|-h|--help)
      local A=$'\e[32m' B=$'\e[1m' D=$'\e[90m' O=$'\e[0m'
      print -r -- ""
      print -r -- "  ${A}${B}siding${O} ${D}— park work on a parallel track, keep the main line clear${O}"
      print -r -- ""
      print -r -- "  ${A}open${O}                        the repo picker  ${D}(also ⌥r)${O}"
      print -r -- "  ${A}new${O} <task> <repo>           worktree off origin/<default>"
      print -r -- "  ${A}list${O}                        what is parked where"
      print -r -- "  ${A}drop${O} <task> <repo> [--force] remove a worktree"
      print -r -- "  ${A}tidy${O}                        offer to remove worktrees whose work has landed"
      print -r -- ""
      print -r -- "  ${A}stack${O} [<task|main> <repo>]  point the dev stack at a tree, or show state"
      print -r -- "  ${A}down${O} <repo>                 stop that repo's stack"
      print -r -- "  ${A}console${O} <task|main> <repo>  rails console in the container serving it"
      print -r -- "  ${A}logs${O} <repo>                 follow the app logs"
      print -r -- ""
      print -r -- "  ${A}ws${O} <profile>                switch workspace (work / personal)"
      print -r -- "  ${A}profile${O} list|show|use|add     workspaces and their GitHub identities"
      print -r -- "  ${A}whoami${O}                      which identity is active here"
      print -r -- "  ${A}attach${O}                      back to the workspace session"
      print -r -- "  ${A}dir${O} [path]                  give any directory its own session"
      print -r -- "  ${A}agent${O}                       start an agent at the workspace root"
      print -r -- "  ${A}theme${O} [name]                switch the Ghostty theme"
      print -r -- "  ${A}doctor${O}                      check this machine"
      print -r -- ""
      print -r -- "  ${D}ws* shortcuts also work: wsnew, wswip, wsdone, wsup, wsconsole …${O}"
      print -r -- ""
      ;;
    *) print -u2 "siding: unknown command '$cmd' — try: siding help"; return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Profiles — one workspace per identity
#
# Each profile is a workspace root plus the GitHub identity that belongs to it.
# Work and personal get their own tmux session, so they are never one keystroke
# apart, and the active gh account follows whichever you are in.
#
# git identity is already decided by path (~/.gitconfig includeIf), so siding
# does not set it — it verifies it. The gh CLI is the gap: its active account is
# GLOBAL and knows nothing about directories, which is precisely how you end up
# pushing as the wrong account and getting "Repository not found".
# ─────────────────────────────────────────────────────────────────────────────

_siding_dir()      { print -r -- "$HOME/.siding"; }
_siding_profdir()  { print -r -- "$HOME/.siding/profiles"; }
_siding_default()  { [[ -f "$(_siding_dir)/default" ]] && cat "$(_siding_dir)/default" || print -r -- work; }

# Load a profile into the current shell.
sidingprofile_load() {
  local name=${1:-$(_siding_default)}
  local f="$(_siding_profdir)/$name.env"
  [[ -f "$f" ]] || { print -u2 "siding: no profile '$name' (siding profile list)"; return 1 }
  unset WS_ROOT WS_NAME WS_GH WS_EMAIL WS_SSH_HOST
  source "$f"
  export WS_ROOT WS_NAME WS_GH WS_EMAIL WS_SSH_HOST
  export SIDING_PROFILE=$name
}

sidingprofile_list() {
  local d f n cur
  cur=$(_siding_default)
  printf "  %-12s %-34s %-22s %s\n" PROFILE WORKSPACE "GITHUB ACCOUNT" ""
  for f in "$(_siding_profdir)"/*.env(N); do
    n=${${f:t}%.env}
    ( source "$f"; printf "  %-12s %-34s %-22s %s\n" "$n" "${WS_ROOT/#$HOME/~}" "${WS_GH:-—}" "$([[ $n == $cur ]] && print default)" )
  done
}

# siding ws <profile> — attach to that workspace, switching gh with it.
sidingws() {
  local name=${1:-$(_siding_default)}
  sidingprofile_load "$name" || return 1

  # gh's active account is global. Switching on attach is the whole point: the
  # account matches whatever workspace is in front of you.
  if [[ -n "$WS_GH" ]] && command -v gh >/dev/null 2>&1; then
    local now; now=$(gh api user --jq .login 2>/dev/null)
    if [[ "$now" != "$WS_GH" ]]; then
      gh auth switch --user "$WS_GH" >/dev/null 2>&1 \
        && print -r -- "gh → $WS_GH" \
        || print -u2 "siding: could not switch gh to $WS_GH (gh auth login --user $WS_GH)"
    fi
  fi

  tmux new-session -A -s "$WS_NAME" -n home -c "$WS_ROOT" "$HOME/.siding-home.zsh" \; \
       set -t "$WS_NAME" @gh "${WS_GH:-?}" \; \
       set -t "$WS_NAME" @profile "$name"
}

# Identity check for one repo: does what git will actually DO here match the
# profile? Compares the effective email and the host the remote resolves to,
# after all insteadOf rewriting — which is where the surprises live.
sidingwhoami() {
  local dir=${1:-$PWD}
  local email host remote
  email=$(git -C "$dir" config user.email 2>/dev/null)
  remote=$(git -C "$dir" ls-remote --get-url origin 2>/dev/null)
  host=${${remote#*@}%%:*}
  print -r -- "  profile      ${SIDING_PROFILE:-none}"
  print -r -- "  workspace    $WS_ROOT"
  print -r -- "  gh account   $(command -v gh >/dev/null && gh api user --jq .login 2>/dev/null || print -- '—')"
  print -r -- "  git email    ${email:-<unset>}"
  print -r -- "  remote host  ${host:-<no remote>}"
  [[ -n "$WS_EMAIL" && -n "$email" && "$email" != "$WS_EMAIL" ]] \
    && print -r -- "  ${email:+⚠ email does not match this profile ($WS_EMAIL)}"
  [[ -n "$WS_SSH_HOST" && -n "$host" && "$host" != "$WS_SSH_HOST" ]] \
    && print -r -- "  ⚠ remote resolves to $host, profile expects $WS_SSH_HOST"
  return 0
}

# siding profile add <name> --root <dir> --gh <account> --email <addr>
#                          [--ssh-host <alias>] [--wire] [--keygen]
#
# --wire is the answer to "do I have to redo the gitconfig on every machine".
# It writes the path-based routing itself: an includeIf block in ~/.gitconfig,
# a ~/.gitconfig-<name> holding the email and the insteadOf rules that pin every
# URL in that tree to the right SSH host, and the matching ~/.ssh/config alias.
# Idempotent, and it backs up anything it edits.
sidingprofile_add() {
  local name=$1; shift 2>/dev/null
  local root gh email sshhost wire=0 keygen=0
  while (( $# )); do
    case "$1" in
      --root)     root=${2:A}; shift 2 ;;
      --gh)       gh=$2; shift 2 ;;
      --email)    email=$2; shift 2 ;;
      --ssh-host) sshhost=$2; shift 2 ;;
      --wire)     wire=1; shift ;;
      --keygen)   keygen=1; wire=1; shift ;;
      *) print -u2 "unknown option: $1"; return 1 ;;
    esac
  done
  if [[ -z "$name" || -z "$root" ]]; then
    print -u2 "usage: siding profile add <name> --root <dir> [--gh acct] [--email addr] [--ssh-host alias] [--wire] [--keygen]"
    return 1
  fi
  [[ -d "$root" ]] || { print -u2 "no such directory: $root"; return 1 }
  : ${sshhost:=github.com-$name}

  mkdir -p "$(_siding_profdir)"
  cat > "$(_siding_profdir)/$name.env" <<EOF
# siding profile: $name
WS_ROOT="${root/#$HOME/\$HOME}"
WS_NAME="$name"
WS_GH="$gh"
WS_EMAIL="$email"
WS_SSH_HOST="$sshhost"
EOF
  print -r -- "profile $name → $root"

  (( wire )) || { print -r -- "  (run with --wire to also set up git/ssh identity routing)"; return 0 }

  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local key="$HOME/.ssh/id_ed25519_$name"

  # ssh alias
  if [[ "$sshhost" != "github.com" ]]; then
    if grep -q "^[[:space:]]*Host[[:space:]]\+$sshhost\b" "$HOME/.ssh/config" 2>/dev/null; then
      print -r -- "  ssh: Host $sshhost already defined"
    else
      [[ -f "$HOME/.ssh/config" ]] && cp "$HOME/.ssh/config" "$HOME/.ssh/config.bak-$stamp"
      mkdir -p "$HOME/.ssh"
      cat >> "$HOME/.ssh/config" <<EOF

# $name (added by siding)
Host $sshhost
  HostName github.com
  User git
  IdentityFile $key
EOF
      chmod 600 "$HOME/.ssh/config"
      print -r -- "  ssh: added Host $sshhost → $key"
    fi
  fi

  # per-identity gitconfig
  local gcf="$HOME/.gitconfig-$name"
  if [[ -f "$gcf" ]]; then
    print -r -- "  git: $gcf already exists"
  else
    cat > "$gcf" <<EOF
[user]
	name = $(git config --global user.name 2>/dev/null || print -r -- "$USER")
	email = $email

# Every remote under this tree is pinned to the $name key. Rewrites away from
# the other host too, so a URL pasted from the wrong place self-corrects.
[url "git@$sshhost:"]
	insteadOf = git@github.com:
	insteadOf = https://github.com/
EOF
    print -r -- "  git: wrote $gcf"
  fi

  # includeIf block
  local relroot="${root/#$HOME/~}"
  if grep -q "gitdir/i:$relroot/" "$HOME/.gitconfig" 2>/dev/null; then
    print -r -- "  git: ~/.gitconfig already routes $relroot/"
  else
    cp "$HOME/.gitconfig" "$HOME/.gitconfig.bak-$stamp" 2>/dev/null
    cat >> "$HOME/.gitconfig" <<EOF

[includeIf "gitdir/i:$relroot/"]
	path = ~/.gitconfig-$name
EOF
    print -r -- "  git: ~/.gitconfig routes $relroot/ → ~/.gitconfig-$name"
  fi

  # key
  if (( keygen )); then
    if [[ -f "$key" ]]; then
      print -r -- "  ssh: key $key already exists"
    else
      ssh-keygen -t ed25519 -f "$key" -N "" -C "$email" -q
      print -r -- "  ssh: generated $key"
    fi
    print -r -- ""
    print -r -- "  add this key to the $gh account:"
    print -r -- "    gh auth switch --user $gh && gh ssh-key add $key.pub --title \"\$(hostname) $name\""
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Knowing what is safe to remove
#
# The four orphan worktrees that started all this survived because nothing ever
# swept, and nothing showed whether their work had landed. A branch being merged
# is the fact that makes a worktree disposable, so it belongs in the listing.
# ─────────────────────────────────────────────────────────────────────────────

# PR state for a branch, as a short label. Empty when gh is unavailable or the
# branch has no PR — absence of a PR is not evidence of anything.
_ws_pr() {
  local dir=$1 br=$2
  [[ -n "$br" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  local out
  out=$(cd "$dir" 2>/dev/null && gh pr view "$br" --json number,state,mergeStateStatus \
        --jq '"#\(.number) \(.state|ascii_downcase)\(if .mergeStateStatus=="DIRTY" then " ⚠conflict" else "" end)"' 2>/dev/null)
  print -r -- "$out"
}

# Has the branch landed on the default branch, PR or not?
_ws_merged() {
  local p=$1 br=$2
  [[ -n "$br" ]] || return 1
  local base; base=$(_ws_base_branch "$p")
  git -C "$p" merge-base --is-ancestor "$br" "origin/$base" 2>/dev/null
}

# sidingtidy [--yes] — offer to remove worktrees whose work has landed.
# Never touches anything with uncommitted or unpushed work: wsdone enforces
# that, and this deliberately routes through it rather than around it.
sidingtidy() {
  local auto=0; [[ "$1" == "--yes" || "$1" == "-y" ]] && auto=1
  local p wt br dirty pr base found=0 removed=0
  local G=$'\e[32m' Y=$'\e[33m' D=$'\e[90m' O=$'\e[0m'

  for p in "$WS_ROOT" "$WS_ROOT"/*(/N) "$WS_ROOT"/apps/*(/N) "$WS_ROOT"/gems/*(/N); do
    [[ -e "$p/.git" ]] || continue
    git -C "$p" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        worktree\ *) wt=${line#worktree } ;;
        branch\ *)   br=${line#branch refs/heads/} ;;
        '')
          # -d guards against a tree removed earlier in this same sweep still
          # appearing in output git had already produced.
          if [[ -n "$wt" && -d "$wt" && "$wt" != "$p" && "$wt" == "$(_ws_wtbase)"/* ]]; then
            dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            pr=$(_ws_pr "$wt" "$br")
            local reason="" ahead
            base=$(_ws_base_branch "$p")
            ahead=$(git -C "$wt" rev-list --count "origin/$base..HEAD" 2>/dev/null)
            [[ "$pr" == *merged* ]] && reason="${pr} merged"
            [[ "$pr" == *closed* ]] && reason="${pr} closed"
            # A tree cut from origin and never committed to is trivially an
            # ancestor of it. That is "nothing here", not "work landed" — saying
            # merged would be true and misleading.
            if [[ -z "$reason" ]]; then
              if (( ${ahead:-0} == 0 )) && (( dirty == 0 )); then reason="no commits yet — nothing in it"
              elif _ws_merged "$p" "$br"; then reason="branch merged into origin/$base"; fi
            fi
            if [[ -n "$reason" ]]; then
              found=1
              print -r -- ""
              print -r -- "  ${wt:t}  ${D}(${p:t})${O}"
              (( dirty > 0 )) \
                && print -r -- "    $reason, ${Y}$dirty uncommitted${O}" \
                || print -r -- "    $reason"
              local ans=y
              if (( ! auto )); then
                # From the terminal, not stdin: stdin here is the git worktree
                # listing being piped in, so a plain read swallows that instead
                # of waiting for you.
                print -n "    remove? [y/N] "
                read -r ans </dev/tty 2>/dev/null || ans=n
              fi
              if [[ "$ans" == y* ]]; then
                local task=${${wt:t}%%--*}
                if wsdone "$task" "$p" >/dev/null 2>&1; then
                  print -r -- "    ${G}removed${O}"; (( removed++ ))
                elif [[ -d "$wt" ]]; then
                  print -r -- "    ${Y}kept${O} — wsdone refused it (uncommitted or unpushed)"
                fi
              fi
            fi
          fi
          wt= br=
          ;;
      esac
    done
  done
  print -r -- ""
  (( found )) || print -r -- "  nothing to tidy — no worktree has landed yet"
  return 0
}
