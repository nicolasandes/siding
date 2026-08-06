#!/usr/bin/env zsh
[[ -f "$HOME/.siding.env" ]] && source "$HOME/.siding.env"   # per-machine: WS_ROOT, WS_NAME
# Open (or jump to) a workspace window for one repo/tree.
# Called by the picker; not meant to be typed.
#
# Layout: Claude on the left, a shell on the right.
#
# The two panes deliberately start in DIFFERENT directories:
#
#   left  — the workspace root. Claude Code resolves .claude/ from the project
#           directory, and every apps/* is its own git repo, so a Claude started
#           inside one gets none of the root workspace's 8 skills (/implement,
#           /issue, /deploy-tag …), 8 agents or 6 guardrail hooks. Verified: a
#           session running in apps/service-d produced no entries in the root
#           .claude/audit.log all day, while a root session did. CLAUDE.md is
#           the exception — it cascades upward, so a repo's own CLAUDE.md is
#           still read either way.
#
#   right — the repo or worktree itself, for the rails console, git, and
#           anything where you want short paths.

WS_ROOT="${WS_ROOT:-$HOME/dev/myworkspace}"

dir=$1
label=$2
[[ -d "$dir" ]] || { tmux display-message "no such directory: $dir"; exit 1 }

# tmux window names cannot carry dots without confusing target parsing.
label=${label//./_}

# Already open? Just go there — clicking a repo twice should not spawn a second
# Claude in the same tree.
existing=$(tmux list-windows -F '#{window_id} #{window_name}' 2>/dev/null \
           | awk -v l="$label" '$2==l {print $1; exit}')
if [[ -n "$existing" ]]; then
  tmux select-window -t "$existing"
  exit 0
fi

win=$(tmux new-window -P -F '#{window_id}' -n "$label" -c "$WS_ROOT")
tmux send-keys -t "${win}.1" "claude" C-m
tmux split-window -h -l 40% -c "$dir" -t "$win"
tmux select-pane -t "${win}.2"
