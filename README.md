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

Just using it — no clone needed. `install.sh` copies into `$HOME`, so nothing
reads from a checkout at runtime:

```sh
curl -fsSL https://raw.githubusercontent.com/nicolasandes/siding/main/get.sh | sh
```

Working on it, or if you would rather see what you are running first:

```sh
git clone https://github.com/nicolasandes/siding.git ~/dev/siding
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
| `⌥p` | switch workspace / identity |
| `⌥s` | tmux's session tree |
| `⌥⇥` | next window |
| `⌥\` `⌥-` | split right / down, inheriting the current pane's directory |
| `⌥w` | close pane |
| `⌥←→↑↓` | move between panes |

Double-click the status bar also opens the picker; right-click a tab for tmux's
own menu. `pick` runs the picker as a plain command.

A **●** beside a window name means that window has gone quiet for 45 seconds —
usually an agent waiting on you. It is a proxy, not a certainty: a window you
simply are not using looks the same. With several windows open it is still the
fastest answer to "who needs me".

There is no prefix key in daily use. `Ctrl-a` is still configured, but every
binding above is prefix-free — on some machines `Ctrl-a` never reaches tmux at
all, and a workspace you cannot get into is worse than one extra modifier.

### The picker

Lists task worktrees first (marked `●`), then every git repo in the workspace.
Repos are found whether they sit directly in `WS_ROOT` or one level down in a
grouping directory — `projects/`, `apps/`, `gems/`, whatever you call it. The
grouping directories are discovered, not hardcoded: naming them in the code is
how a workspace that reorganises itself quietly stops being scanned.

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
| `siding list [--fast]` | what is parked where, with PR state (`--fast` skips the gh lookups) |
| `siding tidy [--yes]` | offer to remove worktrees whose work has landed |
| `siding drop <task> <repo>` | remove one |
| `siding stack [<task\|main> <repo>]` | point the dev stack at a tree, or show state |
| `siding console <task\|main> <repo>` | rails console in the container serving it |
| `siding logs <repo>` | follow the app logs |
| `siding attach` / `siding dir [path]` | back to the workspace / any directory its own session |
| `siding theme [name]` | switch the Ghostty theme |
| `siding init` | scaffold a workspace layer in the root |
| `siding inventory [--write]` | regenerate the repo table from disk |
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

A **profile** is a workspace root plus the GitHub identity that belongs to it.
Add as many as you have identities — work, personal, a client, an org you
contribute to. Each gets its own tmux session.

Ghostty opens **whichever workspace you used last**, so it resumes rather than
always landing in a fixed default. `⌥p` switches, and a second Ghostty window on
the same workspace gets a *grouped* session — same windows available, but each
window can sit on a different one instead of mirroring.

```sh
siding profile list
siding ws work           # attach to that workspace
siding ws personal
siding ws acme
siding profile use work  # which one Ghostty opens by default
siding whoami            # profile, gh account, git email, remote host
```

Profiles are plain files in `~/.siding/profiles/<name>.env`, so you can also
write one by hand or keep them in your own dotfiles:

```sh
WS_ROOT="$HOME/clients/acme"      # directory holding the checkouts
WS_NAME="acme"                    # tmux session name
WS_GH="me-at-acme"                # gh switches to this on entry
WS_EMAIL="me@acme.example"        # what git should be using here
WS_SSH_HOST="github.com-acme"     # host remotes must resolve to
```

`~/.siding/default` holds the name of the profile Ghostty opens.

### Why this exists

Entering a workspace switches the **gh** account to match, and the status bar
shows which account the session is acting as.

That matters because the two halves of GitHub identity behave differently. git
can be routed per-directory with `includeIf` in `~/.gitconfig`, but **`gh`'s
active account is global and knows nothing about directories.** The mismatch is
silent until a push returns `ERROR: Repository not found` — which reads as *the
repo does not exist* when it means *wrong account*.

`siding doctor` verifies the whole chain for the active profile: the gh account,
the email git actually resolves to inside the workspace, and the host remotes
resolve to *after* any `insteadOf` rewriting.

### Setting it up on a new machine

The path-based git routing is not something you have to rebuild by hand:

```sh
siding profile add personal \
  --root ~/personal --gh my-personal-account \
  --email me@personal.example --ssh-host github.com-personal \
  --wire --keygen

siding profile add acme \
  --root ~/clients/acme --gh me-at-acme \
  --email me@acme.example --wire --keygen
```

Repeat per identity — there is no limit, and nothing is special-cased about
"work" or "personal"; they are just the names in the examples.

`--wire` writes the `includeIf` block in `~/.gitconfig`, a `~/.gitconfig-<name>`
holding the email plus `insteadOf` rules pinning every URL in that tree to the
right SSH host, and the matching `~/.ssh/config` alias. `--keygen` creates the
key and prints the one command needed to register it. Idempotent, and it backs
up anything it edits.

### Knowing what is safe to remove

`siding list` shows each worktree's PR state, and `siding tidy` offers to remove
the ones whose work has landed — PR merged or closed, branch merged into the
default branch, or a tree with no commits in it at all. It routes every removal
through the same refusal rules, so uncommitted or unpushed work is never
dropped. Nothing sweeping is why orphaned worktrees accumulate.

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

### Two trees of one repo at once

`siding stack <task> <repo>` re-points the repo's single stack — enough when you
work on one thing per repo, and the default because it costs nothing. When you
need two trees of the **same** repo running together:

```sh
siding stack 348 service-a --iso
siding down 348 service-a          # two args = the isolated stack
```

Each isolated stack is its own compose project, which means its own containers,
its own host ports (remapped automatically to a free block) and — because these
compose files use **named volumes** — its own postgres volume. So the database
is isolated for free: a task branch's migrations cannot reach another tree's
data. Verified by creating a table in one and confirming the other cannot see
it.

Only two things need overriding, and the generator does both: `container_name`,
which these files hardcode, and host ports. Ports use compose's `!override`
tag — a plain list would *merge*, publishing the original port alongside the
remapped one, and the original is exactly what the other stack is holding.

Cache volumes (`bundle_cache` and friends) are deliberately **shared** with the
main stack. They are not data, and a fresh project would otherwise re-download
every dependency — which for private git-sourced gems needs credentials the warm
shared cache never had to present.

Caveat: the *shared* stack (`siding stack main <repo>`) still uses one database
across trees. Use `--iso` when a branch has migrations you do not want landing
in it.

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

## The workspace layer

`siding init` scaffolds the root of a workspace: a `CLAUDE.md` describing it, a
`PRINCIPLES.md`, a `decisions/` directory for dated one-file-per-decision
records, `skills/` and `scripts/`, and a `.gitignore` that tracks only this
layer — project directories are ignored by pattern, so cloning a new one needs
no maintenance.

The repo table is **generated**:

```sh
siding inventory --write
```

It lists what is actually on disk, plus what exists on the profile's GitHub
account but is not cloned here. It refuses to produce that second list when gh
is signed in as a different account, because a confidently short list reads as
"these are all missing" when it means "I could not see the private ones".

Generating it is the point. A hand-maintained inventory drifts, and tooling that
reads a stale one fails silently rather than loudly.

## Using a different terminal

**Ghostty is not load-bearing.** It launches tmux and supplies the theme and
transparency; everything else — the picker, worktrees, profiles, identity
switching, isolated stacks — is tmux and shell. Any terminal works.

Point your terminal's startup command at the launcher:

| terminal | where |
|---|---|
| macOS Terminal | Settings → Profiles → Shell → *Run command*: `~/.siding-launch.zsh` |
| iTerm2 | Profiles → General → Command → *Send text at start*, or set Command |
| Windows Terminal (WSL) | profile `commandline`, appending `-c '~/.siding-launch.zsh'` |
| anything else | just run `ws` after opening |

**One thing you must change**, because every binding here is Option-based:
tell the terminal to send Option as Meta, or `⌥r` arrives as `®` instead of a
keystroke tmux understands.

- macOS Terminal: Settings → Profiles → **Keyboard** → *Use Option as Meta key*
- iTerm2: Profiles → **Keys** → *Left Option key: Esc+*
- Ghostty: `macos-option-as-alt = true` (already in the shipped config)

Without Ghostty you lose `siding theme` (a Ghostty feature) and the transparency
settings. tmux takes its colours from the terminal palette, so whatever theme
your terminal uses, siding follows it.

## Platforms

**Developed and used on macOS.** That is the only platform it has actually run
on.

Linux support is *written* but **untested**: the macOS-specific pieces are
detected rather than assumed — Ghostty is optional, mtime handles both BSD and
GNU `stat`, and the clipboard picks `pbcopy` / `wl-copy` / `xclip` / `xsel` /
`clip.exe` — and everything structural (tmux, zsh, git, gh, docker, python3)
exists there. It should work. Nobody has confirmed it. Reports welcome.

**Windows** needs WSL2 — `tmux` and `zsh` do not run natively, and a native port
would be a different program against PowerShell. Under WSL everything works with
Windows Terminal in place of Ghostty. One caveat there: `siding stack` mounts
the parent repo's `.git` at its own absolute host path, and Windows-side Docker
sees different paths than the Linux side, so isolated stacks want testing on
WSL specifically.

## Testing

```sh
script/smoke.zsh
```

Builds a throwaway workspace in a temp directory — a bare repo standing in for
a remote, a checkout inside a grouping directory — points siding at it, and
asserts behaviour. No network, no docker, no gh, and nothing in your real
workspace is touched.

Every assertion corresponds to something that was once wrong and looked right.
Silent failure is this project's characteristic bug, so the test asserts on
output rather than exit codes alone.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The most useful contribution right now
is telling me whether it works on Linux, since nobody has run it there.

## Prior art

[workmux](https://github.com/raine/workmux) pairs git worktrees with tmux
windows; [ntm](https://github.com/Dicklesworthstone/ntm) coordinates AI agents
across tmux panes; [sesh](https://github.com/joshmedeski/sesh) and
[twm](https://github.com/vinnymeller/twm) manage tmux sessions. What siding adds
is the dev stack following the worktree — see above.

## Limitations

Worth knowing before you rely on it.

- **Tested on macOS only.** See Platforms above.
- **Opinionated about keys.** Every binding is on Option, with no prefix in
  daily use, because `Ctrl-a` never reached tmux on the machine this was built
  on. If your prefix works fine, the prefix bindings are still there.
- **`siding stack` needs the compose file to bind-mount the source.** A repo
  that bakes its code into the image cannot be served from a worktree without a
  rebuild; siding says so and declines rather than pretending.
- **The shared stack uses one database across trees.** Switching it between
  worktrees reuses the same data, so a branch's migrations persist. `--iso`
  gives a tree its own database; the shared stack deliberately does not.
- **Isolated stacks cost real resources.** Each is a full set of containers —
  app, database, cache — so two of them is two databases running.
- **The quiet-window marker is a proxy.** A window with an agent waiting and a
  window you simply are not using look identical to tmux.
- **`siding list` costs one `gh` call per worktree.** Use `--fast` to skip.
- **`profile add --wire` edits `~/.gitconfig` and `~/.ssh/config`.** It is
  idempotent and backs up what it touches, but it writes to files you probably
  care about. Read it first if that matters to you.
- **The `gh` account is global.** siding switches it when you enter a workspace,
  which means it changes for every other terminal too. That is the point, but it
  is a side effect worth knowing.
- **One smoke test, not a suite.** `script/smoke.zsh` builds a throwaway
  workspace and asserts 22 behaviours — discovery, resolution, worktree
  creation and removal, the refusal to drop uncommitted work, inventory and the
  picker. It covers the paths that have broken silently before; it does not
  cover the docker or gh paths, which need both installed and configured.
- **Not packaged.** Install with `get.sh` or `./install.sh`; no Homebrew formula.
- **It installs a tmux config.** If you already have one, siding's is written to
  `~/.tmux.siding.conf` and you are told to `source-file` it — an installer
  replacing a curated tmux.conf would be rude. It does replace its own.

## Notes

- Colours come from the terminal palette (`default`, slots 0–15), so tmux
  follows whatever Ghostty theme is active. `ghtheme <name>` restyles
  everything at once.
- The agent pane starts at the **workspace root**, not in the repo. Agent tools
  resolve project config from the working directory, and a repo that is its own
  git checkout gets none of the workspace-level config. The shell pane is where
  the repo-local paths are.
- No secrets live in any of these files.
