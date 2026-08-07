#!/usr/bin/env bash
# Install the terminal workspace on this machine.
#
#   ./install.sh                      # workspace defaults to ~/dev/<something>
#   WS_ROOT=~/code ./install.sh       # or say where explicitly
#   WS_ROOT=~/code WS_NAME=code ./install.sh
#
# Safe to re-run: existing files are backed up before being replaced.

set -euo pipefail

SRC="$(cd "$(dirname "$0")/files" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.siding-backup-$STAMP"
backed_up=0

say()  { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

install_file() {
  local src=$1 dst=$2
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    mkdir -p "$BACKUP/$(dirname "${dst#"$HOME"/}")"
    cp -a "$dst" "$BACKUP/${dst#"$HOME"/}"
    backed_up=1
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

echo
echo "terminal workspace — install"
echo

# ── prerequisites ────────────────────────────────────────────────────────────
missing=()
command -v tmux >/dev/null 2>&1 || missing+=("tmux")
[ -d /Applications/Ghostty.app ] || missing+=("ghostty (cask)")
if [ ${#missing[@]} -gt 0 ]; then
  warn "missing: ${missing[*]}"
  warn "install with:  brew install tmux && brew install --cask ghostty"
  warn "continuing anyway — the files will be in place when you do"
fi
command -v git >/dev/null 2>&1 || warn "git not found; the worktree helpers need it"
command -v docker >/dev/null 2>&1 || say "docker not found — wsup/wsconsole will be inert (everything else works)"

# ── per-machine settings ─────────────────────────────────────────────────────
# Written once and never overwritten: this is the file that makes the setup
# specific to a machine, and the reason nothing else needs editing.
if [ ! -f "$HOME/.siding.env" ]; then
  root="${WS_ROOT:-}"
  if [ -z "$root" ]; then
    for guess in "$HOME/dev" "$HOME/code" "$HOME/projects" "$HOME/src"; do
      [ -d "$guess" ] && { root="$guess"; break; }
    done
    root="${root:-$HOME/dev}"
  fi
  name="${WS_NAME:-$(basename "$root")}"
  # Quoted heredoc terminator, then the values substituted afterwards: an
  # unquoted heredoc would expand ${WS_ROOT:-...} here instead of writing it.
  cat > "$HOME/.siding.env" <<'EOF'
# Per-machine settings for the Ghostty + tmux workspace.
# This is the ONLY file you should need to edit on a new machine.

# The workspace: a directory holding your checkouts. The picker lists every git
# repo directly inside it, plus any under its apps/ and gems/ subdirectories.
# The ${VAR:-default} form means an explicit WS_ROOT=... in the environment
# still wins, which is what makes a second workspace testable.
WS_ROOT="${WS_ROOT:-__ROOT__}"

# tmux session name, and the label shown in the banner.
WS_NAME="${WS_NAME:-__NAME__}"
EOF
  perl -pi -e "s|__ROOT__|$root|; s|__NAME__|$name|" "$HOME/.siding.env"
  say "wrote ~/.siding.env  (WS_ROOT=$root, WS_NAME=$name)"
else
  say "kept existing ~/.siding.env"
fi

# ── files ────────────────────────────────────────────────────────────────────
for f in "$SRC"/siding-*.zsh; do
  install_file "$f" "$HOME/.$(basename "$f")"
  chmod +x "$HOME/.$(basename "$f")"
done
install_file "$SRC/siding-stackgen.py" "$HOME/.siding-stackgen.py"
chmod +x "$HOME/.siding-stackgen.py"
install_file "$SRC/tmux.conf"      "$HOME/.tmux.conf"
install_file "$SRC/ghostty-config" "$HOME/.config/ghostty/config"
say "installed tmux.conf, ghostty config and the siding-* scripts"

# ── shell wiring ─────────────────────────────────────────────────────────────
if ! grep -q 'siding-wt.zsh' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'EOF'

# Terminal workspace: repo picker, worktrees, dev-stack helpers (ws*, pick)
# Per-machine settings live in ~/.siding.env
source ~/.siding-wt.zsh
EOF
  say "added the source line to ~/.zshrc"
else
  say "~/.zshrc already sources it"
fi

[ "$backed_up" -eq 1 ] && say "replaced files backed up to $BACKUP"

echo
echo "done. open Ghostty, then press ⌥r"
echo "if the workspace path is wrong, edit ~/.siding.env and reopen Ghostty"
echo
