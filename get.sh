#!/bin/sh
# Install siding without cloning it.
#
#   curl -fsSL https://raw.githubusercontent.com/nicolasandes/siding/main/get.sh | sh
#
# For machines that only USE siding. The installed files are copied into $HOME,
# so nothing reads from a checkout at runtime — a clone is only needed if you
# intend to work on siding itself.
#
#   SIDING_REF=<branch|tag>  install from somewhere other than main

set -eu

REPO="${SIDING_REPO:-nicolasandes/siding}"
REF="${SIDING_REF:-main}"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

TMP="$(mktemp -d)"
# Clean up even on failure: a half-extracted tarball in /tmp helps nobody.
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "fetching $REPO@$REF"
if ! curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" | tar -xz -C "$TMP"; then
  echo "could not fetch $REPO@$REF — check the name, the ref, and that the repo is public" >&2
  exit 1
fi

DIR="$(find "$TMP" -maxdepth 1 -type d -name '*siding*' | head -1)"
[ -n "$DIR" ] && [ -f "$DIR/install.sh" ] || {
  echo "the archive did not contain install.sh — layout may have changed" >&2
  exit 1
}

bash "$DIR/install.sh"
