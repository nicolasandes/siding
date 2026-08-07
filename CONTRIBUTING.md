# Contributing

This is a small tool with one regular user. Contributions are welcome; here is
what is actually useful and what to expect.

## Most useful right now

**Tell me whether it works on Linux.** The macOS-specific pieces are detected
rather than assumed and everything structural exists on Linux, but nobody has
run it there. A report either way — `siding doctor` output, what broke — is
worth more than a feature.

The same goes for WSL, with one known unknown: `siding stack` mounts the parent
repo's `.git` at its own absolute host path, and Windows-side Docker sees
different paths than the Linux side. That likely needs work.

## What this is opinionated about

Not up for changing without a good argument, because they are the design:

- **A worktree per task.** The point is that an interruption never forces you to
  stash half-finished work.
- **Main checkouts stay clean.** Work happens in worktrees, not in the checkout.
- **Option keys, no prefix in daily use.** `Ctrl-a` never reached tmux on the
  machine this was built on, and a workspace you cannot get into is worse than
  one extra modifier. The prefix bindings still exist.
- **Shell, not a compiled binary.** It orchestrates tmux, git and docker; those
  are the interfaces. A rewrite would need to be worth losing hackability.

## Practical notes

- **There are no automated tests.** Everything was verified by running it. If
  you change something, say in the PR what you actually ran — "worked for me" is
  not the same as "I created a worktree, pointed a stack at it and opened a
  console".
- **Prefer fixing a silent failure over adding a feature.** Most bugs found here
  were things that appeared to work: a picker that drew nowhere, an inventory
  that listed 7 of 25, a stat call that made every worktree look ageless.
- **Explain why in the commit message.** The reasoning is the part that is hard
  to recover later; the diff shows the what.
- Keep the shell portable-ish: zsh is required, but avoid new hard dependencies
  and check both BSD and GNU behaviour for anything touching `stat`, `sed` or
  `date`.

## Reporting something

Include your OS, `tmux -V`, and the output of `siding doctor`. If a keybinding
does nothing, check first whether your terminal sends Option as Meta — that
accounts for a good share of "nothing happens".
