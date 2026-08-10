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
if [[ -d "$HOME/.siding/profiles" && -z "${SIDING_NO_PROFILE:-}" ]]; then
  # Which workspace this shell belongs to. The tmux session knows — sidingws
  # records it — and that must win, because tmux propagates the environment of
  # whichever session started the server: a pane in the work session inherits
  # WS_ROOT from personal, and the profile's own ${WS_ROOT:-…} then politely
  # keeps the inherited value. That is how the picker showed the wrong repos.
  _sd=""
  if [[ -n "${TMUX_PANE:-}" ]]; then
    _sd=$(command tmux display-message -p -t "$TMUX_PANE" '#{@profile}' 2>/dev/null)
  elif [[ -n "${TMUX:-}" ]]; then
    _sd=$(command tmux display-message -p '#{@profile}' 2>/dev/null)
  fi
  [[ -n "$_sd" && -f "$HOME/.siding/profiles/$_sd.env" ]] || \
    _sd=$([[ -f "$HOME/.siding/last" ]] && cat "$HOME/.siding/last" \
          || { [[ -f "$HOME/.siding/default" ]] && cat "$HOME/.siding/default" || print -r -- work; })
  if [[ -f "$HOME/.siding/profiles/$_sd.env" ]]; then
    # Clear first: a resolved profile describes the workspace, and an inherited
    # value must not override it.
    unset WS_ROOT WS_NAME WS_GH WS_EMAIL WS_SSH_HOST
    source "$HOME/.siding/profiles/$_sd.env"
    export SIDING_PROFILE=$_sd
  fi
  unset _sd
elif [[ -f "$HOME/.siding.env" && -z "${SIDING_NO_PROFILE:-}" ]]; then
  source "$HOME/.siding.env"
fi
export WS_ROOT="${WS_ROOT:-$HOME/dev}"
export WS_NAME="${WS_NAME:-${WS_ROOT:t}}"
export WS_GH WS_EMAIL WS_SSH_HOST


# Every repo in the workspace, whether it sits directly in the root or inside a
# grouping directory like projects/, apps/ or gems/. One level of grouping is
# discovered generically rather than by name — hardcoding the names is how a
# workspace that reorganises itself quietly stops being scanned.
_ws_repodirs() {
  local d g
  for d in "$WS_ROOT"/*(/N); do
    if [[ -e "$d/.git" ]]; then print -r -- "$d"; continue; fi
    case "${d:t}" in
      .*|node_modules|decisions|skills|scripts|docs|bin) continue ;;
    esac
    for g in "$d"/*(/N); do
      [[ -e "$g/.git" ]] && print -r -- "$g"
    done
  done
}

# Worktrees live under the workspace so they are found wherever the workspace
# is, and named after this tool rather than the workspace it was first built in.
# Honours an override for anyone who wants them elsewhere.
_ws_wtbase() { print -r -- "${SIDING_WORKTREES:-$WS_ROOT/.siding/worktrees}"; }

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
  for d in $(_ws_repodirs); do
    [[ "${d:t}" == "$r" || "${d:t}" == *"-$r" || "${d:t}" == *"_$r" ]] && cands+=("$d")
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

# BSD and GNU stat disagree on how to ask for an mtime, and getting it wrong
# yields a silent '?' rather than an error.
_ws_age_days() {
  local d=$1 mt now
  mt=$(stat -f %m "$d" 2>/dev/null) || mt=$(stat -c %Y "$d" 2>/dev/null)
  [[ -z "$mt" ]] && { print -r -- '?'; return }
  now=$(date +%s)
  print -r -- $(( (now - mt) / 86400 ))
}

# Ghostty is optional: it launches tmux and supplies the theme, but nothing
# structural depends on it. Found rather than assumed, so Linux and WSL — where
# the terminal is something else entirely — degrade instead of failing.
_siding_ghostty() {
  [[ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]] \
    && { print -r -- /Applications/Ghostty.app/Contents/MacOS/ghostty; return 0 }
  command -v ghostty 2>/dev/null && return 0
  return 1
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
  for p in "$WS_ROOT" $(_ws_repodirs); do
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

[[ -f "$HOME/.siding-stack.zsh" ]] && source "$HOME/.siding-stack.zsh"
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
    stack)
      if [[ -z "$1" ]]; then wsstack
      elif [[ "$3" == "--iso" || "$3" == "--isolated" ]]; then wsupiso "$1" "$2"
      else wsup "$@"; fi ;;
    down)
      # two args = an isolated stack for that task; one = the shared stack
      if [[ -n "$2" ]]; then wsdowniso "$1" "$2"; else wsdown "$@"; fi ;;
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
    init)        sidinginit "$@" ;;
    inventory)   sidinginventory "$@" ;;
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
      print -r -- "  ${A}stack${O} <task> <repo> --iso   its OWN containers, ports and database"
      print -r -- "  ${A}down${O} <repo> | <task> <repo> stop the shared, or an isolated, stack"
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
      print -r -- "  ${A}init${O}                        scaffold the workspace layer (CLAUDE.md, principles, decisions)"
      print -r -- "  ${A}inventory${O} [--write]         regenerate the repo table from disk"
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
# The profile whose WS_ROOT contains a given path, if any. Where you are is a
# better signal than what was last recorded, and it cannot go stale.
_siding_profile_for_path() {
  local target=${1:-$PWD} f n root
  target=${target:A}
  for f in "$(_siding_profdir)"/*.env(N); do
    n=${${f:t}%.env}
    root=$( unset WS_ROOT; source "$f" >/dev/null 2>&1; print -r -- "${WS_ROOT:A}" )
    [[ -n "$root" && "$target" == "$root"(|/*) ]] && { print -r -- "$n"; return 0 }
  done
  return 1
}

# Which workspace am I looking at? The tmux session knows — sidingws records it
# — and that beats guessing from a directory. The picker runs in a popup, whose
# working directory is NOT the pane's unless told, so inferring from the path
# there showed one workspace's repos while you were sitting in another.
#
# Note this answers a different question from "which workspace am I operating
# on", which is a path question — see sidinginventory, which adopts by path.
_siding_default() {
  # Ask about a specific pane when we know one: $TMUX is unset in some contexts
  # (run-shell, popups) where $TMUX_PANE is still set, and without a target tmux
  # answers about whichever session it considers current — which is how the work
  # session kept resolving to the personal profile.
  local sess
  if [[ -n "${TMUX_PANE:-}" ]]; then
    sess=$(tmux display-message -p -t "$TMUX_PANE" '#{@profile}' 2>/dev/null)
  elif [[ -n "${TMUX:-}" ]]; then
    sess=$(tmux display-message -p '#{@profile}' 2>/dev/null)
  fi
  [[ -n "$sess" && -f "$(_siding_profdir)/$sess.env" ]] && { print -r -- "$sess"; return }
  local bypath; bypath=$(_siding_profile_for_path 2>/dev/null) && { print -r -- "$bypath"; return }
  [[ -f "$(_siding_dir)/last" ]] && { cat "$(_siding_dir)/last"; return }
  [[ -f "$(_siding_dir)/default" ]] && { cat "$(_siding_dir)/default"; return }
  print -r -- work
}

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
    ( unset WS_ROOT WS_NAME WS_GH WS_EMAIL WS_SSH_HOST
      source "$f"
      printf "  %-12s %-34s %-22s %s\n" "$n" "${WS_ROOT/#$HOME/~}" "${WS_GH:-—}" "$([[ $n == $cur ]] && print default)" )
  done
}

# siding ws <profile> — attach to that workspace, switching gh with it.
sidingws() {
  local name=${1:-$(_siding_default)}
  local force_switch=0
  [[ "$2" == "--switch" || -n "$TMUX" ]] && force_switch=1
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

  # Remember where you were. Ghostty opens the last workspace you used, which
  # beats a fixed default: after a day in personal, being dropped into work is
  # a small daily annoyance.
  mkdir -p "$(_siding_dir)"
  print -r -- "$name" > "$(_siding_dir)/last"

  # Already inside tmux — including inside a display-popup, which is its own
  # little terminal. Attaching here would open the workspace INSIDE the popup
  # instead of moving the client you are actually looking at; switch-client
  # moves that client.
  if (( force_switch )); then
    if ! tmux has-session -t "=$WS_NAME" 2>/dev/null; then
      tmux new-session -d -s "$WS_NAME" -n home -c "$WS_ROOT" "$HOME/.siding-home.zsh" 2>/dev/null
    fi
    tmux set-option -t "$WS_NAME" @gh "${WS_GH:-?}" 2>/dev/null
    tmux set-option -t "$WS_NAME" @profile "$name" 2>/dev/null
    _siding_export_session_env "$WS_NAME" "$name"
    tmux switch-client -t "$WS_NAME"
    return
  fi

  # Two tmux clients on ONE session mirror each other — move in one window and
  # the other follows. A grouped session shares the same windows but lets each
  # Ghostty sit on a different one, which is what makes a second window useful
  # rather than a duplicate. destroy-unattached cleans it up on close.
  if tmux has-session -t "=$WS_NAME" 2>/dev/null; then
    local clients; clients=$(tmux list-clients -t "$WS_NAME" 2>/dev/null | wc -l | tr -d ' ')
    if (( clients > 0 )) && [[ -z "$TMUX" ]]; then
      local n=2 alt="${WS_NAME}-2"
      while tmux has-session -t "=$alt" 2>/dev/null; do (( n++ )); alt="${WS_NAME}-$n"; done
      tmux new-session -d -t "$WS_NAME" -s "$alt" 2>/dev/null
      # NOT destroy-unattached: it kills a detached session immediately, so the
      # attach below would find nothing. A detach hook cleans up at the right
      # moment instead — when the window that owns it goes away.
      tmux set-hook -t "$alt" client-detached "kill-session -t $alt" 2>/dev/null
      tmux set-option -t "$alt" @gh "${WS_GH:-?}" 2>/dev/null
      tmux set-option -t "$alt" @profile "$name" 2>/dev/null
      tmux attach-session -t "$alt"
      return
    fi
  fi

  tmux new-session -d -A -s "$WS_NAME" -n home -c "$WS_ROOT" "$HOME/.siding-home.zsh" 2>/dev/null
  tmux set-option -t "$WS_NAME" @gh "${WS_GH:-?}" 2>/dev/null
  tmux set-option -t "$WS_NAME" @profile "$name" 2>/dev/null
  _siding_export_session_env "$WS_NAME" "$name"
  tmux attach-session -t "$WS_NAME"
}

# Put the workspace into the tmux SESSION environment, so every pane and popup
# opened in it inherits the right values. tmux otherwise propagates the
# environment of whichever session started the server — which is how a pane in
# one workspace ended up carrying another workspace's WS_ROOT, and the picker
# listed the wrong repos.
_siding_export_session_env() {
  local sess=$1 prof=$2 v
  for v in WS_ROOT WS_NAME WS_GH WS_EMAIL WS_SSH_HOST; do
    tmux set-environment -t "$sess" "$v" "${(P)v}" 2>/dev/null
  done
  tmux set-environment -t "$sess" SIDING_PROFILE "$prof" 2>/dev/null
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
WS_ROOT="\${WS_ROOT:-${root/#$HOME/\$HOME}}"
WS_NAME="\${WS_NAME:-$name}"
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

  for p in "$WS_ROOT" $(_ws_repodirs); do
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

# ─────────────────────────────────────────────────────────────────────────────
# Workspace scaffolding
#
# A workspace root that documents itself. The inventory is GENERATED, never
# hand-written: a hand-maintained list of what lives here is the thing that goes
# stale, and when tooling reads it, stale means silently broken rather than
# merely wrong.
# ─────────────────────────────────────────────────────────────────────────────

_siding_repo_row() {
  local d=$1 name lang last rem
  name=${d:t}
  lang=$(ls "$d" 2>/dev/null | grep -m1 -iE '^(package\.json|Gemfile|go\.mod|Cargo\.toml|requirements\.txt|pyproject\.toml|pubspec\.yaml|composer\.json)$')
  case "$lang" in
    package.json) lang="node" ;; Gemfile) lang="ruby" ;; go.mod) lang="go" ;;
    Cargo.toml) lang="rust" ;; requirements.txt|pyproject.toml) lang="python" ;;
    pubspec.yaml) lang="flutter" ;; composer.json) lang="php" ;; *) lang="—" ;;
  esac
  last=$(git -C "$d" log -1 --format=%as 2>/dev/null)
  rem=$(git -C "$d" remote get-url origin 2>/dev/null | sed -E 's|\.git$||; s|.*[:/]([^/]+/[^/]+)$|\1|')
  # Show the path relative to the workspace, not just the name: once repos are
  # grouped under projects/ or apps/, the name alone no longer says where it is.
  local rel=${d#$WS_ROOT/}
  print -r -- "| \`$rel\` | $lang | ${rem:-—} | ${last:-—} |"
}

# sidinginventory [--write] — the table of what is actually here.
sidinginventory() {
  local write=0 force=0 active a d n r slug f list out
  # Adopt the profile for wherever this is being run. The shell inherits
  # whichever profile the session opened with, so running this inside another
  # workspace would otherwise read that workspace's repos with the first
  # workspace's account — and then refuse to write, blaming the account.
  local here; here=$(_siding_profile_for_path 2>/dev/null)
  if [[ -n "$here" && "$here" != "${SIDING_PROFILE:-}" ]]; then
    print -r -- "  using profile '$here' for $(pwd | sed "s|$HOME|~|")"
    sidingprofile_load "$here" || return 1
  fi
  local -a rows absent have
  for a in "$@"; do
    [[ "$a" == "--write" ]] && write=1
    [[ "$a" == "--force" ]] && force=1
  done

  # Refuse to write a degraded document over a better one. Signed in as another
  # account, the not-cloned list cannot be produced — and writing "skipped" over
  # a complete list loses information silently, which is the exact failure this
  # generated inventory exists to prevent. It happened once already.
  if (( write )) && (( ! force )) && [[ -n "$WS_GH" ]] && command -v gh >/dev/null 2>&1; then
    active=$(gh api user --jq .login 2>/dev/null)
    if [[ "$active" != "$WS_GH" ]]; then
      print -u2 "siding inventory: gh is signed in as '${active:-none}', not '$WS_GH'."
      print -u2 "  The not-cloned list cannot be produced, and writing without it would"
      print -u2 "  replace a complete list with a note saying it could not look."
      local want; want=$(_siding_profile_for_path "$WS_ROOT" 2>/dev/null)
      print -u2 "  Fix:  siding ws ${want:-<the profile for this workspace>}     Override:  --force"
      return 1
    fi
  fi
  for d in $(_ws_repodirs); do rows+=("$(_siding_repo_row "$d")"); done

  out=""
  out+="| repo | stack | remote | last commit |"$'\n'
  out+="|---|---|---|---|"$'\n'
  for r in "${rows[@]}"; do out+="$r"$'\n'; done

  # Repos that exist on the account but are not cloned here. Knowing what is
  # missing is as useful as knowing what is present, and it is the half a
  # hand-written table never captures.
  if [[ -n "$WS_GH" ]] && command -v gh >/dev/null 2>&1; then
    # Only ask when gh is actually signed in as this profile's account. Another
    # account can see just the public repos, and a confidently short list is
    # worse than none — it reads as "these are all missing" when it means
    # "I could not see the private ones".
    active=$(gh api user --jq .login 2>/dev/null)
    if [[ "$active" == "$WS_GH" ]]; then
      # Include the workspace root itself: it is usually a repo too, and its
      # directory name need not match its repo name.
      for d in "$WS_ROOT" $(_ws_repodirs); do
        [[ -e "$d/.git" ]] || continue
        slug=$(git -C "$d" remote get-url origin 2>/dev/null | sed -E 's|\.git$||; s|.*/||')
        [[ -n "$slug" ]] && have+=("$slug")
      done
      for n in $(gh repo list "$WS_GH" --limit 200 --json name --jq '.[].name' 2>/dev/null); do
        (( ${have[(I)$n]} )) || absent+=("$n")
      done
      if (( ${#absent} )); then
        list=""
        for n in "${absent[@]}"; do list+="\`$n\`, "; done
        out+=$'\n'"On \`$WS_GH\` but not cloned here: ${list%, }"$'\n'
      fi
    else
      out+=$'\n'"_Not-cloned list skipped: gh is signed in as \`$active\`, not \`$WS_GH\` (\`siding ws\` switches it)._"$'\n'
    fi
  fi

  if (( write )); then
    f="$WS_ROOT/CLAUDE.md"
    [[ -f "$f" ]] || { print -u2 "sidinginventory: no $f — run siding init first"; return 1 }
    python3 - "$f" <<PYEOF
import re, sys
path = sys.argv[1]
body = """$out"""
s = open(path).read()
new = "<!-- siding:inventory:start -->\n" + body + "<!-- siding:inventory:end -->"
if "siding:inventory:start" in s:
    s = re.sub(r"<!-- siding:inventory:start -->.*?<!-- siding:inventory:end -->", new, s, flags=re.S)
else:
    s = s.rstrip() + "\n\n" + new + "\n"
open(path, "w").write(s)
print("  inventory written to CLAUDE.md")
PYEOF
  else
    print -r -- "$out"
  fi
}

# sidinginit — scaffold the workspace layer in WS_ROOT.
sidinginit() {
  local root=${1:-$WS_ROOT}
  [[ -d "$root" ]] || { print -u2 "sidinginit: no such directory: $root"; return 1 }
  mkdir -p "$root/decisions" "$root/skills" "$root/scripts"

  # Ignore every project directory rather than listing them: a list would need
  # updating on every clone, which is exactly the kind of maintenance that stops
  # happening.
  if [[ ! -f "$root/.gitignore" ]]; then
    cat > "$root/.gitignore" <<'EOF'
# Every project directory is its own git repo. Only the workspace layer — the
# map, the principles, the decisions and the shared tooling — is tracked here.
/*/
!/decisions/
!/skills/
!/scripts/
.DS_Store
EOF
    print -r -- "  .gitignore"
  fi

  if [[ ! -f "$root/CLAUDE.md" ]]; then
    cat > "$root/CLAUDE.md" <<EOF
# ${root:t} — workspace

The root of everything I build. Each directory below is its own git repo; this
level holds only what applies across all of them.

- **[PRINCIPLES.md](PRINCIPLES.md)** — how things are built here.
- **[decisions/](decisions/)** — one dated file per decision, with its reasoning.
- **skills/**, **scripts/** — shared tooling.

Managed with [siding](https://github.com/${WS_GH:-me}/siding): \`siding open\` to
pick a repo, \`siding new <task> <repo>\` for a worktree, \`siding doctor\` to
check the machine.

## Repos

The table below is generated by \`siding inventory --write\`. Do not edit it by
hand — a hand-maintained inventory drifts, and tooling that reads a stale one
fails silently rather than loudly.
EOF
    print -r -- "  CLAUDE.md"
  fi

  if [[ ! -f "$root/PRINCIPLES.md" ]]; then
    cat > "$root/PRINCIPLES.md" <<'EOF'
# Principles

Rules that already describe how I work — not aspirations. A principle written
before the decision it governs gets ignored; add one when you have decided the
same thing twice, and record the decision itself in `decisions/`.

## Identity and secrets

- Git identity is decided by path, never by remembering to set it. Work trees
  and personal trees route to different keys and emails automatically.
- Nothing secret is committed. Config that varies by machine lives outside the
  repo and is referenced, not embedded.
- Repos start private. Making something public is a deliberate act.

## Working

- One task, one worktree. An interruption never forces stashing half-done work.
- Main checkouts stay on the default branch, clean.
- Anything generated is generated on demand, not transcribed. Transcribed facts
  drift from their source and then mislead.

## Writing things down

- A decision worth explaining twice belongs in `decisions/`, dated, with the
  reasoning and what was rejected.
- Documentation states what is true now. When it stops being true it is fixed
  or deleted, not annotated.
EOF
    print -r -- "  PRINCIPLES.md"
  fi

  ( cd "$root" && WS_ROOT="$root" sidinginventory --write )
  print -r -- "  workspace scaffolded in $root"
}
