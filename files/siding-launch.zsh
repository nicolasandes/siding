#!/usr/bin/env zsh
# What Ghostty runs. Attaches to the workspace session, creating it the first
# time, then falls through to a plain login shell so ⌥d leaves you somewhere
# usable instead of closing the window.
# Ghostty passes no arguments, so this opens the default profile. `siding ws
# <name>` switches once you are inside.
source "$HOME/.siding-wt.zsh"
sidingws "${1:-}"
exec /bin/zsh -l
