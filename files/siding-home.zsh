#!/usr/bin/env zsh
[[ -f "$HOME/.siding.env" ]] && source "$HOME/.siding.env"   # per-machine: WS_ROOT, WS_NAME
# The window you land on when Ghostty opens. Its whole job is to make sure you
# never have to remember a command.
#
# Option, not Ctrl-a: the Ctrl-a prefix never arrives on this machine, while the
# Option (Alt) bindings fire immediately.

print -P ""
print -P "  %F{green}%B${WS_NAME:-myworkspace} workspace%b%f"
print -P ""
print -P "  %F{green}%B⌥r%b%f   open a repo or task worktree"
print -P "  %F{green}%B⌥x%b%f   close the current repo window"
print -P "  %F{green}%B⌥d%b%f   detach to a plain shell — this keeps running"
print -P "  %F{green}%B⌥s%b%f   switch session   %F{8}(ws returns here · wsdir <dir> for other work)%f"
print -P "  %F{green}%B⌥⇥%b%f   next window"
# printf, not print -P: print -P eats the backslash as an escape, and this line
# has to display the ⌥\ key literally.
printf '  \e[32m\e[1m⌥\\\e[0m   split right     \e[32m\e[1m⌥-\e[0m  split down     \e[32m\e[1m⌥w\e[0m  close pane\n'
print -P "  %F{8}Splits inherit the current pane's directory — use these, not ⌘D.%f"
print -P ""
print -P "  Also: %F{white}double-click the status bar%f opens the picker,"
print -P "  or type %F{white}~/.siding-pick.zsh%f"
print -P "  %F{8}Right-click a tab for tmux's own menu (kill, rename, swap).%f"
print -P ""
print -P "  Each repo window: %F{white}Claude on the left, a shell on the right.%f"
print -P "  %F{8}Claude runs at the workspace root so /implement, the agents and%f"
print -P "  %F{8}the hooks load; the shell sits in the repo or worktree itself.%f"
print -P "  The names along the bottom are your tabs — click one to switch."
print -P ""
print -P "  %F{8}In the right-hand shell: %faxconsole main <repo>%F{8} for a rails console,%f"
print -P "  %F{8}%faxup <task> <repo>%F{8} to point the dev stack at a worktree.%f"
print -P ""

exec /bin/zsh -l
