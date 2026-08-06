#!/usr/bin/env zsh
# What Ghostty runs. Attaches to the workspace session, creating it the first
# time, then falls through to a plain login shell so ⌥d leaves you somewhere
# usable instead of closing the window.
[[ -f "$HOME/.siding.env" ]] && source "$HOME/.siding.env"
: ${WS_ROOT:=$HOME/dev/myworkspace}
: ${WS_NAME:=myworkspace}
tmux new-session -A -s "$WS_NAME" -n home -c "$WS_ROOT" "$HOME/.siding-home.zsh"
exec /bin/zsh -l
