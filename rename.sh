#!/usr/bin/env bash
# Rename the whole setup — files, references and (optionally) the command
# prefix — in one pass.
#
#   ./rename.sh termyard                 # files become ~/.termyard-*.zsh
#   ./rename.sh termyard --prefix yard   # and wsnew/wswip become yardnew/yardwip
#
# Renaming is deliberately cheap: the name lives in filenames and a handful of
# identifiers, nothing structural. Picking a name later costs one command.
#
# Rewriting is done in python, not sed/perl — a $VAR in a shell script is very
# easy for those to eat, which is exactly how $HOME and $WS_ROOT went missing
# during an earlier rename.

set -euo pipefail

OLD="siding"
OLD_PREFIX="ws"
NEW="${1:-}"
NEW_PREFIX=""

if [ -z "$NEW" ]; then
  echo "usage: $(basename "$0") <newname> [--prefix <cmdprefix>]" >&2
  echo "  e.g. $(basename "$0") termyard --prefix yard" >&2
  exit 1
fi
shift
if [ "${1:-}" = "--prefix" ]; then NEW_PREFIX="${2:-}"; fi

case "$NEW" in
  *[!a-z0-9-]*) echo "name must be lowercase letters, digits and dashes" >&2; exit 1 ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.$OLD-rename-backup-$STAMP"
mkdir -p "$BACKUP"

echo
echo "renaming $OLD → $NEW${NEW_PREFIX:+  (commands ${OLD_PREFIX}* → ${NEW_PREFIX}*)}"
echo

# ── move the files ───────────────────────────────────────────────────────────
for f in "$HOME/.$OLD-"*.zsh; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  new="$HOME/.$NEW-${base#".$OLD-"}"
  cp -a "$f" "$BACKUP/"
  mv "$f" "$new"
  echo "  $(basename "$f") → $(basename "$new")"
done
if [ -f "$HOME/.$OLD.env" ]; then
  cp -a "$HOME/.$OLD.env" "$BACKUP/"
  mv "$HOME/.$OLD.env" "$HOME/.$NEW.env"
  echo "  .$OLD.env → .$NEW.env"
fi
if [ -d "$HOME/.$OLD-stacks" ]; then
  mv "$HOME/.$OLD-stacks" "$HOME/.$NEW-stacks"
  echo "  .$OLD-stacks/ → .$NEW-stacks/"
fi

# ── rewrite references ───────────────────────────────────────────────────────
targets=("$HOME/.$NEW.env" "$HOME/.tmux.conf" "$HOME/.zshrc" "$HOME/.config/ghostty/config")
for f in "$HOME/.$NEW-"*.zsh; do targets+=("$f"); done

for f in "${targets[@]}"; do
  [ -f "$f" ] || continue
  [ -f "$BACKUP/$(basename "$f")" ] || cp -a "$f" "$BACKUP/" 2>/dev/null || true
done

OLD="$OLD" NEW="$NEW" OLD_PREFIX="$OLD_PREFIX" NEW_PREFIX="$NEW_PREFIX" \
python3 - "${targets[@]}" <<'PY'
import os, re, sys
old, new = os.environ["OLD"], os.environ["NEW"]
oldp, newp = os.environ["OLD_PREFIX"], os.environ["NEW_PREFIX"]

# Commands are renamed only when a prefix is given. WS_ROOT/WS_NAME stay put:
# they are the documented contract of the config file, and churning them buys
# nothing.
cmds = ["new", "wip", "done", "up", "down", "stack", "console", "logs",
        "task", "dir", "doctor", "claude"]

for path in sys.argv[1:]:
    try:
        s = open(path).read()
    except OSError:
        continue
    o = s
    s = s.replace(f".{old}-", f".{new}-").replace(f".{old}.env", f".{new}.env")
    s = s.replace(f"{old}-stacks", f"{new}-stacks")
    s = re.sub(rf"\b{re.escape(old)}\b", new, s)
    if newp:
        for c in cmds:
            s = re.sub(rf"\b{oldp}{c}\b", f"{newp}{c}", s)
        s = re.sub(rf"\b_{oldp}_", f"_{newp}_", s)
        s = re.sub(rf"\b{oldp}\(\)", f"{newp}()", s)
    if s != o:
        open(path, "w").write(s)
        print(f"  rewrote {os.path.basename(path)}")
PY

echo
echo "done. backup in $BACKUP"
echo "open a new shell (or: source ~/.$NEW-wt.zsh), then run ${NEW_PREFIX:-$OLD_PREFIX}doctor"
echo
