#!/usr/bin/env zsh
[[ -f "$HOME/.siding.env" ]] && source "$HOME/.siding.env"   # per-machine: WS_ROOT, WS_NAME
# Create a task worktree and open a window on it, driven from the picker rather
# than typed. Called as: newtask <task> <repo>

source "$HOME/.siding-wt.zsh"

task=$1
repo=$2

if [[ -z "$task" || -z "$repo" ]]; then
  tmux display-message "new task: need both a task name and a repo"
  exit 1
fi

p=$(_ws_repo "$repo") || { tmux display-message "unknown repo: $repo"; exit 1 }
dir="$(_ws_wtbase)/${task}--${p:t}"

if [[ ! -d "$dir" ]]; then
  # wsnew ends with a cd, harmless here, but its output belongs in a message
  # rather than scrolling past in whatever pane happened to be focused.
  out=$(wsnew "$task" "$repo" 2>&1) || { tmux display-message "${out##*$'\n'}"; exit 1 }
fi

"$HOME/.siding-open.zsh" "$dir" "${p:t}~${task}"
tmux display-message "worktree ready: ${task} on ${p:t}"
