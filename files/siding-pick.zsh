#!/usr/bin/env zsh
[[ -f "$HOME/.siding.env" ]] && source "$HOME/.siding.env"   # per-machine: WS_ROOT, WS_NAME
# The repo picker, drawn as ordinary terminal output inside a tmux popup.
#
# A popup rather than tmux's display-menu: a menu is an overlay, and when
# anything is off it draws nowhere and reports nothing, which reads as a dead
# keybinding. A popup runs a real program on a real TTY, so errors are visible.
#
# Navigation: arrow keys or j/k move, Enter selects, a hotkey jumps straight to
# an entry, q or Esc cancels. Arrows used to close the picker outright — an
# arrow arrives as the three bytes ESC [ A, and a naive single-byte read saw the
# ESC and quit. read_key below consumes the whole sequence.

WS_ROOT="${WS_ROOT:-$HOME/dev/myworkspace}"
OPEN="$HOME/.siding-open.zsh"
WTBASE="$WS_ROOT/.claude/worktrees"

typeset -a labels dirs wins kinds
keys=(1 2 3 4 5 6 7 8 9 0 a b c d e f g h i l m n o p s t u v w y z)

add() { labels+=("$1"); dirs+=("$2"); wins+=("$3"); kinds+=("$4"); }

if [[ -d "$WTBASE" ]]; then
  for d in "$WTBASE"/*(/N); do
    task=${${d:t}%%--*}; repo=${${d:t}#*--}
    add "● ${repo}  ·  ${task}" "$d" "${repo}~${task}" wt
  done
fi

# Repos live either directly in the workspace (a flat ~/dev/project layout) or
# grouped under apps/ and gems/. Scan all three so the setup is not tied to any
# one workspace's shape; seen[] keeps a repo from listing twice.
typeset -A seen
for d in "$WS_ROOT"/*(/N) "$WS_ROOT"/apps/*(/N) "$WS_ROOT"/gems/*(/N); do
  [[ -e "$d/.git" ]] || continue
  [[ -n "${seen[${d:A}]}" ]] && continue
  seen[${d:A}]=1
  name=${d:t}; parent=${${d:h}:t}; label=$name; win=$name
  # Same basename in more than one group — say which, or you cannot tell them
  # apart in the list.
  if [[ -e "$WS_ROOT/apps/$name/.git" && -e "$WS_ROOT/gems/$name/.git" ]]; then
    label="$name  ($parent)"; win="${name}_${parent}"
  fi
  add "$label" "$d" "$win" repo
done

add "workspace root" "$WS_ROOT" "${WS_NAME:-workspace}" plain

ACCENT=$'\e[32m'; BOLD=$'\e[1m'; DIM=$'\e[90m'; OFF=$'\e[0m'
INV=$'\e[7m'

# One keypress, with escape sequences consumed whole so an arrow never leaks a
# stray ESC. Falls back to a line read when there is no terminal (tests, pipes).
read_key() {
  local a b c
  if ! read -k 1 a 2>/dev/null; then
    read -r a || { print -r -- q; return }
    [[ -z "$a" ]] && { print -r -- enter; return }
    print -r -- "${a:0:1}"; return
  fi
  case "$a" in
    $'\e')
      if read -k 1 -t 0.06 b 2>/dev/null && [[ "$b" == "[" || "$b" == "O" ]]; then
        read -k 1 -t 0.06 c 2>/dev/null
        case "$c" in
          A) print -r -- up ;;   B) print -r -- down ;;
          C) print -r -- right ;; D) print -r -- left ;;
          *) print -r -- ignore ;;
        esac
      else
        print -r -- q          # a bare Esc really is cancel
      fi
      ;;
    $'\n'|$'\r') print -r -- enter ;;
    *) print -r -- "$a" ;;
  esac
}

cls() { printf '\e[H\e[2J'; }

# A cancellable line prompt. Every text prompt in this picker needs a way out —
# an entry field with no escape hatch is a dead end you can only leave by
# inventing a value. Empty input or q backs out; the hint says so on screen.
PROMPT_VALUE=""
prompt_line() {
  local label=$1 ans
  print -n "   ${label}${DIM}  (empty or q to go back)${OFF}: "
  read -r ans || return 1
  ans=${ans##[[:space:]]#}
  [[ -z "$ans" || "$ans" == "q" ]] && return 1
  PROMPT_VALUE=$ans
  return 0
}

draw_list() {
  cls
  print -r -- ""
  print -r -- "   ${ACCENT}${BOLD}open a repo${OFF}"
  print -r -- ""
  local i
  for i in {1..${#labels}}; do
    if (( i == sel )); then
      print -r -- "   ${INV} ${keys[$i]}  ${labels[$i]} ${OFF}"
    else
      print -r -- "   ${ACCENT}${BOLD}[${keys[$i]}]${OFF} ${labels[$i]}"
    fi
  done
  print -r -- ""
  print -r -- "   ${ACCENT}${BOLD}[+]${OFF} new task worktree      ${ACCENT}${BOLD}[q]${OFF} cancel"
  print -r -- "   ${DIM}↑↓ move · Enter select · or press a key${OFF}"
}

draw_sub() {
  cls
  print -r -- ""
  print -r -- "   ${ACCENT}${BOLD}${labels[$idx]}${OFF}"
  print -r -- ""
  local rows=("open main checkout      ${DIM}browse, read, run commands${OFF}" \
              "start a task worktree   ${DIM}new branch off origin/main${OFF}")
  local i
  for i in 1 2; do
    if (( i == sub )); then
      print -r -- "   ${INV} $i  ${rows[$i]}${INV} ${OFF}"
    else
      print -r -- "   ${ACCENT}${BOLD}[$i]${OFF} ${rows[$i]}"
    fi
  done
  print -r -- ""
  print -r -- "   ${ACCENT}${BOLD}[q]${OFF} back to the list"
  print -r -- "   ${DIM}↑↓ move · Enter select${OFF}"
}

sel=1
idx=0

while true; do
  draw_list
  k=$(read_key)

  case "$k" in
    up|k)    (( sel = sel > 1 ? sel - 1 : ${#labels} )); continue ;;
    down|j)  (( sel = sel < ${#labels} ? sel + 1 : 1 ));  continue ;;
    ignore|right|left) continue ;;
    q)       cls; exit 0 ;;
    enter)   idx=$sel ;;
    '+')
      cls
      print -r -- ""
      print -r -- "   ${ACCENT}${BOLD}new task worktree${OFF}"
      print -r -- ""
      prompt_line "task name" || continue
      task=${PROMPT_VALUE// /-}
      prompt_line "repo     " || continue
      repo=$PROMPT_VALUE
      exec "$HOME/.siding-newtask.zsh" "$task" "$repo"
      ;;
    *)
      idx=0
      for i in {1..${#keys}}; do
        [[ "$k" == "${keys[$i]}" ]] && { idx=$i; break }
      done
      (( idx == 0 || idx > ${#labels} )) && continue
      ;;
  esac

  (( idx == 0 )) && continue

  # A worktree already IS a task, and the workspace root has no branch
  # semantics — open those straight away. For a repo's main checkout, ask:
  # opening it to work means Claude creates the branch THERE, which is how a
  # main checkout ends up parked on someone else's feature branch.
  if [[ "${kinds[$idx]}" != "repo" ]]; then
    cls; exec "$OPEN" "${dirs[$idx]}" "${wins[$idx]}"
  fi

  sub=1
  while true; do
    draw_sub
    s=$(read_key)
    case "$s" in
      up|k)   (( sub = sub == 1 ? 2 : 1 )); continue ;;
      down|j) (( sub = sub == 2 ? 1 : 2 )); continue ;;
      ignore|right|left) continue ;;
      q)      break ;;                       # back to the list, not exit
      enter)  s=$sub ;;
    esac
    case "$s" in
      1) cls; exec "$OPEN" "${dirs[$idx]}" "${wins[$idx]}" ;;
      2)
        cls
        print -r -- ""
        print -r -- "   ${ACCENT}${BOLD}${labels[$idx]}${OFF}  ${DIM}new task worktree${OFF}"
        print -r -- ""
        prompt_line "task name" || continue   # back to this repo's submenu
        task=${PROMPT_VALUE// /-}
        exec "$HOME/.siding-newtask.zsh" "$task" "${dirs[$idx]}"
        ;;
    esac
  done
done
