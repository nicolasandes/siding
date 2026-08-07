#!/usr/bin/env zsh
# Load the active profile so the banner can name the workspace and the GitHub
# identity it is acting as. Profiles first, single-file config as fallback.
if [[ -d "$HOME/.siding/profiles" ]]; then
  _p=$([[ -f "$HOME/.siding/default" ]] && cat "$HOME/.siding/default" || print -r -- work)
  [[ -n "$SIDING_PROFILE" ]] && _p=$SIDING_PROFILE
  [[ -f "$HOME/.siding/profiles/$_p.env" ]] && source "$HOME/.siding/profiles/$_p.env"
  unset _p
elif [[ -f "$HOME/.siding.env" ]]; then
  source "$HOME/.siding.env"
fi
# The window you land on when Ghostty opens. Its whole job is to make sure you
# never have to remember a command — so it leads with the one word that gets you
# everything else, and lists only keys that are actually bound.
#
# Option, not Ctrl-a: the Ctrl-a prefix never arrives on this machine, while the
# Option (Alt) bindings fire immediately.
#
# print -P renders zsh prompt escapes; plain `print -r` would show raw codes.

print -P ""
print -P "  %F{green}%B${WS_NAME:-workspace}%b%f %F{8}workspace · ${WS_GH:-no github profile}%f"
print -P ""
print -P "  %F{green}%Bsiding help%b%f   %F{8}every command%f          %F{green}%Bsiding doctor%b%f  %F{8}check this machine%f"
print -P "  %F{green}%Bsiding list%b%f   %F{8}what is parked where%f   %F{green}%Bsiding tidy%b%f    %F{8}sweep what has landed%f"
print -P "  %F{green}%Bsiding ws%b%f     %F{8}switch workspace/identity%f"
print -P ""
print -P "  %F{green}%B⌥r%b%f   open a repo or task worktree"
print -P "  %F{green}%B⌥x%b%f   close the current repo window        %F{green}%B⌥w%b%f  close pane"
print -P "  %F{green}%B⌥p%b%f   switch workspace/identity            %F{green}%B⌥s%b%f  session tree"
print -P "  %F{green}%B⌥⇥%b%f   next window"
print -P "  %F{green}%B⌥d%b%f   detach to a plain shell — this keeps running"
# printf, not print -P: print -P eats the backslash as an escape, and this line
# has to display the ⌥\ key literally.
printf '  \e[32m\e[1m⌥\\\e[0m   split right                          \e[32m\e[1m⌥-\e[0m  split down\n'
print -P "  %F{8}Splits inherit the current pane's directory — use these, not ⌘D.%f"
print -P ""
print -P "  %F{8}Double-click the status bar opens the picker; right-click a tab for%f"
print -P "  %F{8}tmux's own menu (kill, rename, swap). A%f %F{yellow}●%f %F{8}marks a window whose%f"
print -P "  %F{8}agent has gone quiet — usually waiting on you.%f"
print -P ""
print -P "  Each repo window: %F{white}an agent on the left, a shell on the right.%f"
print -P "  %F{8}The agent runs at the workspace root so workspace-level config,%f"
print -P "  %F{8}skills and hooks load; the shell sits in the repo or worktree.%f"
print -P ""

exec /bin/zsh -l
