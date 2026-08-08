#!/usr/bin/env zsh
# Smoke test: exercise the paths that have broken silently before.
#
#   script/smoke.zsh
#
# Builds a throwaway workspace in a temp directory — a bare repo standing in for
# a remote, a checkout inside a grouping directory — points siding at it, and
# asserts behaviour. Touches no network, no docker, no gh, and nothing in your
# real workspace.
#
# Every assertion here corresponds to something that was once wrong and looked
# right: a picker that drew nowhere, an inventory that reported 7 of 25, a stat
# call that made every worktree ageless, profiles that overwrote the workspace
# they were handed. Silent failure is this project's characteristic bug, so the
# test asserts on output, not on exit codes alone.

# Deliberately NOT `set -u`: siding's functions take optional positional
# arguments (`local br=$3`), which is a parameter-not-set error under it, and
# the harness would exit mid-run looking like a hang.
pass=0; fail=0
G=$'\e[32m'; R=$'\e[31m'; D=$'\e[90m'; O=$'\e[0m'
ok()   { print -r -- "  ${G}ok${O}    $1"; (( pass++ )); return 0 }
bad()  { print -r -- "  ${R}FAIL${O}  $1${2:+  ${D}($2)${O}}"; (( fail++ )); return 0 }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected '$3', got '$2'" }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "'$3' not in output" }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "'$3' unexpectedly present" }

WS=${$(mktemp -d):A}
SEED=${$(mktemp -d):A}   # outside the workspace: a repo in it would be discovered
trap 'rm -rf "$WS" "$SEED"' EXIT INT TERM

print -r -- ""
print -r -- "  siding smoke test   ${D}$WS${O}"
print -r -- ""

# ── a workspace that looks like a real one ───────────────────────────────────
mkdir -p "$WS/projects"
git init -q --bare "$WS/origin.git"
git init -q "$SEED/seed"
(
  cd "$SEED/seed"
  git config user.email smoke@example.com; git config user.name Smoke
  print -r -- '{"scripts":{"test":"true"}}' > package.json
  git add -A; git -c commit.gpgsign=false commit -qm "seed"
  git branch -M main
  git remote add origin "$WS/origin.git"
  git push -q origin main
) >/dev/null 2>&1
git clone -q "$WS/origin.git" "$WS/projects/demo"
git -C "$WS/projects/demo" config user.email smoke@example.com
git -C "$WS/projects/demo" config user.name Smoke

# Point siding at the sandbox. Exported BEFORE sourcing on purpose: a profile
# that overwrites a caller-supplied WS_ROOT is a bug this once had, and it made
# the picker list an entirely different workspace's repos.
export WS_ROOT="$WS" WS_NAME=smoke WS_GH="" WS_EMAIL="" WS_SSH_HOST=""
export SIDING_WORKTREES="$WS/.siding/worktrees"
source "$HOME/.siding-wt.zsh"

is "profile load leaves an explicit WS_ROOT alone" "$WS_ROOT" "$WS"

# ── discovery ────────────────────────────────────────────────────────────────
dirs=$(_ws_repodirs)
has "finds a repo inside a grouping directory" "$dirs" "projects/demo"
is  "finds exactly one repo"                   "$(print -r -- "$dirs" | grep -c .)" "1"
is  "resolves by short name"                   "$(_ws_repo demo)" "$WS/projects/demo"
is  "resolves by path"                         "$(_ws_repo "$WS/projects/demo")" "$WS/projects/demo"
_ws_repo nosuchrepo >/dev/null 2>&1 && bad "rejects an unknown repo" || ok "rejects an unknown repo"

# The BSD/GNU stat split: the wrong one returns nothing and every worktree looks
# ageless, so the stale-worktree warning silently never fires.
age=$(_ws_age_days "$WS/projects/demo")
[[ "$age" == <-> ]] && ok "age is a number, not '?'" || bad "age is a number, not '?'" "got '$age'"

# ── worktrees ────────────────────────────────────────────────────────────────
wsnew t1 demo >/dev/null 2>&1
wt="$SIDING_WORKTREES/t1--demo"
[[ -d "$wt" ]] && ok "wsnew creates the worktree" || bad "wsnew creates the worktree"
is "branches off origin's default branch" \
   "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" "$(git -C "$WS/projects/demo" rev-parse origin/main 2>/dev/null)"
is "names the branch after the task" "$(git -C "$wt" branch --show-current 2>/dev/null)" "ai/t1"

wip=$(cd "$WS" && wswip --fast 2>&1)
has "wswip lists it"          "$wip" "t1--demo"
has "wswip shows the branch"  "$wip" "ai/t1"

tidy=$(cd "$WS" && print -r -- n | sidingtidy 2>&1)
has "tidy calls an empty tree empty, not merged" "$tidy" "no commits yet"

wsdone t1 demo --force >/dev/null 2>&1
[[ ! -d "$wt" ]] && ok "wsdone removes it" || bad "wsdone removes it"
has "wswip is empty again" "$(cd "$WS" && wswip --fast 2>&1)" "no task worktrees"

# ── refusing to lose work ────────────────────────────────────────────────────
wsnew t2 demo >/dev/null 2>&1
print -r -- "scratch" > "$SIDING_WORKTREES/t2--demo/dirty.txt"
out=$(wsdone t2 demo 2>&1)
has "wsdone refuses to drop uncommitted work" "$out" "uncommitted"
[[ -d "$SIDING_WORKTREES/t2--demo" ]] && ok "and leaves it in place" || bad "and leaves it in place"
wsdone t2 demo --force >/dev/null 2>&1

# ── inventory ────────────────────────────────────────────────────────────────
inv=$(sidinginventory 2>&1)
has "inventory records the path, not just the name" "$inv" "projects/demo"
has "inventory detects the stack"                   "$inv" "node"
hasnt "inventory emits no stray variable output"    "$inv" "="$'\n'

# ── the picker renders ───────────────────────────────────────────────────────
picked=$(print -r -- q | zsh "$HOME/.siding-pick.zsh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
has "picker lists the repo"        "$picked" "demo"
has "picker offers the workspace"  "$picked" "workspace root"

print -r -- ""
print -r -- "  ${G}$pass passed${O}   $( (( fail )) && print -r -- "${R}$fail failed${O}" || print -r -- "0 failed" )"
print -r -- ""
(( fail == 0 ))
