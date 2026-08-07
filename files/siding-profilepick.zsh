#!/usr/bin/env zsh
# Profile picker — bound to ⌥p. Same shape as the repo picker: a popup running
# a real program, so anything that goes wrong is printed where you can read it.

source "$HOME/.siding-wt.zsh"

typeset -a names roots ghs
for f in "$(_siding_profdir)"/*.env(N); do
  names+=("${${f:t}%.env}")
  roots+=("$(source "$f" >/dev/null 2>&1; print -r -- "${WS_ROOT/#$HOME/~}")")
  ghs+=("$(source "$f" >/dev/null 2>&1; print -r -- "$WS_GH")")
done
(( ${#names} )) || { print -r -- "  no profiles — siding profile add <name> --root <dir>"; sleep 2; exit 0 }

keys=(1 2 3 4 5 6 7 8 9 0 a b c d e f g h i)
A=$'\e[32m'; B=$'\e[1m'; D=$'\e[90m'; O=$'\e[0m'; INV=$'\e[7m'
cur=$(cat "$(_siding_dir)/last" 2>/dev/null || cat "$(_siding_dir)/default" 2>/dev/null)

read_key() {
  local a b c
  if ! read -k 1 a 2>/dev/null; then read -r a || { print -r -- q; return }; print -r -- "${a:0:1}"; return; fi
  case "$a" in
    $'\e') if read -k 1 -t 0.06 b 2>/dev/null && [[ "$b" == "[" ]]; then
             read -k 1 -t 0.06 c 2>/dev/null
             case "$c" in A) print -r -- up ;; B) print -r -- down ;; *) print -r -- ignore ;; esac
           else print -r -- q; fi ;;
    $'\n'|$'\r') print -r -- enter ;;
    *) print -r -- "$a" ;;
  esac
}

sel=1
for i in {1..${#names}}; do [[ "${names[$i]}" == "$cur" ]] && sel=$i; done

while true; do
  printf '\e[H\e[2J'
  print -r -- ""
  print -r -- "   ${A}${B}switch workspace${O}"
  print -r -- ""
  for i in {1..${#names}}; do
    local line="${names[$i]}  ${D}${roots[$i]}  ·  ${ghs[$i]:-no github}${O}"
    if (( i == sel )); then print -r -- "   ${INV} ${keys[$i]}  ${names[$i]} ${O}  ${D}${roots[$i]}  ·  ${ghs[$i]:-no github}${O}"
    else print -r -- "   ${A}${B}[${keys[$i]}]${O} $line"; fi
  done
  print -r -- ""
  print -r -- "   ${D}↑↓ move · Enter switch · q cancel${O}"
  print -n "   > "
  k=$(read_key); print ""
  case "$k" in
    up)     (( sel = sel > 1 ? sel - 1 : ${#names} )); continue ;;
    down)   (( sel = sel < ${#names} ? sel + 1 : 1 )); continue ;;
    ignore) continue ;;
    q)      printf '\e[H\e[2J'; exit 0 ;;
    enter)  ;;
    *)      local idx=0
            for i in {1..${#keys}}; do [[ "$k" == "${keys[$i]}" ]] && { idx=$i; break } done
            (( idx == 0 || idx > ${#names} )) && continue
            sel=$idx ;;
  esac
  printf '\e[H\e[2J'
  exec sidingws "${names[$sel]}"
done
