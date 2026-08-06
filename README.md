# siding

> A siding is a short parallel track where a train waits without blocking the
> main line. That is exactly what a task worktree is for.

A Ghostty + tmux workspace for working across many repos with an AI coding
agent — without a terminal window per repo, and without pausing one task to
handle another.

When production breaks in the middle of a feature, you don't stash anything.
You put the feature on a siding and open a new one. It's still there when you
come back, agent session and all.

Nothing here is tied to a particular workspace. **Profiles** say where your
repos live and which GitHub identity belongs to them — one for work, one for
personal, each its own tmux session.

## Install

```sh
git clone <this repo> ~/dev/siding
cd ~/dev/siding
./install.sh                        # guesses ~/dev, ~/code, ~/projects, ~/src
WS_ROOT=~/code ./install.sh         # or say where
```

Prerequisites (the installer checks and tells you):

```sh
brew install tmux
brew install --cask ghostty
```

Then open Ghostty and press **⌥r**.

Check everything landed:

```sh
siding doctor
```

It verifies tools, config, that repos are actually visible to the picker, that
every script parses, the shell wiring, that `~/.tmux.conf` loads without errors
(one bad option silently aborts the whole file), that the Ghostty config is
valid, and flags worktrees older than two weeks.

Re-running the installer is safe; anything it replaces is copied to
`~/.siding-backup-<timestamp>/` first.

## What you get

Opening Ghostty attaches to a tmux session for your workspace. Each repo you
open becomes a **window** — a tab in the status bar — with two panes: an agent
on the left, a shell on the right.

Because tmux owns the processes, closing Ghostty doesn't stop anything. Reopen
it and every window, pane and agent session is exactly as you left it.

### Keys

| Key | |
|---|---|
| `⌥r` | open a repo or task worktree (the picker) |
| `⌥x` | close the current window (asks first) |
| `⌥d` | detach to a plain shell — the workspace keeps running |
| `⌥s` | switch session |
| `⌥⇥` | next window |
| `⌥\` `⌥-` | split right / down, inheriting the current pane's directory |
| `⌥w` | close pane |
| `⌥←→↑↓` | move between panes |

Double-click the status bar also opens the picker; right-click a tab for tmux's
own menu. `pick` runs the picker as a plain command.

There is no prefix key in daily use. `Ctrl-a` is still configured, but every
binding above is prefix-free — on some machines `Ctrl-a` never reaches tmux at
all, and a workspace you cannot get into is worse than one extra modifier.

### The picker

Lists task worktrees first (marked `●`), then every git repo in the workspace.
Repos are found whether they sit directly in `WS_ROOT` or are grouped under
`apps/` and `gems/`.

Choosing a **worktree** opens it. Choosing a **repo** asks first:

- `[1] open main checkout` — browse, read, run commands
- `[2] start a task worktree` — a new branch off `origin/<default>`

That second option is the point of the whole thing: a task worktree is a
separate directory, so an interrupt never forces you to stash half-finished
work. The feature tree simply sits there while you fix production in another.

Arrows or `j`/`k` move, Enter selects, a hotkey jumps, `q` goes back.

### Commands

One entry point, `siding <command>` — run `siding help` for the list:

| | |
|---|---|
| `siding open` | the repo picker (same as ⌥r) |
| `siding new <task> <repo>` | worktree off `origin/<default>` |
| `siding list` | what is parked where |
| `siding drop <task> <repo>` | remove one |
| `siding stack [<task\|main> <repo>]` | point the dev stack at a tree, or show state |
| `siding console <task\|main> <repo>` | rails console in the container serving it |
| `siding logs <repo>` | follow the app logs |
| `siding attach` / `siding dir [path]` | back to the workspace / any directory its own session |
| `siding theme [name]` | switch the Ghostty theme |
| `siding doctor` | check this machine |

The underlying `ws*` functions remain as shortcuts:

| | |
|---|---|
| `wsnew <task> <repo>` | worktree off `origin/<default>` |
| `wswip` | every task worktree, with dirty counts and age |
| `wsdone <task> <repo>` | remove one — refuses if uncommitted or unpushed |
| `wsup <task\|main> <repo>` | point the repo's docker-compose stack at that tree |
| `wsstack` / `wsdown <repo>` | what each stack serves / stop it |
| `wsconsole <task\|main> <repo>` | rails console in the container serving that tree |
| `wslogs <repo>` | follow the app service logs |
| `ws` / `wsdir [dir]` | attach to the workspace / give any directory its own session |
| `ghtheme [name]` | switch the Ghostty theme |
| `wsdoctor` | check the whole setup on this machine |

The docker commands are inert without docker; everything else still works.

## Profiles and GitHub identity

Work and personal live in separate workspaces, each with its own tmux session:

```sh
siding profile list
siding ws work        # ~/dev/... , acts as your work GitHub account
siding ws personal    # ~/personal, acts as your personal account
```

Entering a workspace switches the **gh** account to match, and the status bar
shows which account the session is acting as. That matters because git identity
can be routed by path (`includeIf` in `~/.gitconfig`) but **`gh`'s active
account is global and knows nothing about directories** — which is exactly how
you push to a personal repo as your work account and get a misleading
`ERROR: Repository not found`.

`siding doctor` verifies the whole chain for the active profile: gh account,
the email git actually resolves to inside the workspace, and the host remotes
resolve to *after* any `insteadOf` rewriting.

```sh
siding whoami         # profile, gh account, git email, remote host
```

### Setting it up on a new machine

The path-based git routing is not something you have to rebuild by hand:

```sh
siding profile add personal \
  --root ~/personal --gh my-personal-account \
  --email me@personal.example --ssh-host github.com-personal \
  --wire --keygen
```

`--wire` writes the `includeIf` block in `~/.gitconfig`, a `~/.gitconfig-<name>`
holding the email plus `insteadOf` rules pinning every URL in that tree to the
right SSH host, and the matching `~/.ssh/config` alias. `--keygen` creates the
key and prints the one command needed to register it. Idempotent, and it backs
up anything it edits.

## Why the dev stack follows the worktree

`wsup` exists because compose files usually bind-mount the repo directory into
the container. A console opened against a running stack therefore tests the
**main checkout**, not the worktree you're editing. Splitting your terminal
doesn't fix that; it only puts the wrong console closer to you.

Two things make re-pointing work, both found the hard way:

1. **A fixed compose project name per repo.** Compose files that hardcode
   `container_name` cannot run two stacks of one repo, and starting from a
   worktree directory otherwise adopts that directory as the project name — at
   which point `down` can no longer find the containers it must remove.

2. **Mounting the parent repo's `.git`.** In a worktree, `.git` is a *file*
   holding `gitdir: /abs/host/path/.git/worktrees/<name>` — a host path with no
   counterpart inside the container. Any git command there fails with
   `fatal: not a git repository: (null)`, exit 128, which kills entrypoints that
   run git before `bundle install`.

Caveat: the stack keeps its usual database, so migrations from a task branch
mutate the shared dev database.

## Renaming it

The name lives in filenames and a handful of identifiers — nothing structural —
so changing it is one command:

```sh
./rename.sh newname                 # files become ~/.newname-*.zsh
./rename.sh newname --prefix nn     # and wsnew/wswip become nnnew/nnwip
```

It moves the files, rewrites every reference (tmux, Ghostty, `~/.zshrc`, the
scripts themselves), and backs up what it touched.

## Files

| | |
|---|---|
| `~/.siding.env` | **the only per-machine file** — `WS_ROOT`, `WS_NAME` |
| `~/.siding-wt.zsh` | the `ws*` commands, sourced from `~/.zshrc` |
| `~/.siding-pick.zsh` | the picker |
| `~/.siding-open.zsh` | opens a window: agent left, shell right |
| `~/.siding-newtask.zsh` | creates a worktree and its window |
| `~/.siding-home.zsh` | the banner you land on |
| `~/.siding-launch.zsh` | what Ghostty runs |
| `~/.tmux.conf`, `~/.config/ghostty/config` | |

## Prior art

[workmux](https://github.com/raine/workmux) pairs git worktrees with tmux
windows; [ntm](https://github.com/Dicklesworthstone/ntm) coordinates AI agents
across tmux panes; [sesh](https://github.com/joshmedeski/sesh) and
[twm](https://github.com/vinnymeller/twm) manage tmux sessions. What siding adds
is the dev stack following the worktree — see above.

## Notes

- Colours come from the terminal palette (`default`, slots 0–15), so tmux
  follows whatever Ghostty theme is active. `ghtheme <name>` restyles
  everything at once.
- The agent pane starts at the **workspace root**, not in the repo. Agent tools
  resolve project config from the working directory, and a repo that is its own
  git checkout gets none of the workspace-level config. The shell pane is where
  the repo-local paths are.
- No secrets live in any of these files.
