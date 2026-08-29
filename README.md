# gwt

A zsh helper for git worktrees. Each repo gets a folder of worktrees at
`$GWT_BASE/<repo>/wt-<branch>`, and `gwt` moves you between them.

## Install

```zsh
[ -f ~/projects/ai/gwt/gwt.plugin.zsh ] && source ~/projects/ai/gwt/gwt.plugin.zsh
```

The `-f` guard keeps a machine that has not cloned this repo from erroring at shell startup.

## Commands

```
gwt add [-b <start>] <branch>   create worktree from <start> (default HEAD), cd into it
gwt go  [-b <start>] <branch>   cd into worktree if it exists; otherwise create it
gwt rm  <branch>                remove worktree; delete branch if merged; prune
gwt checkout [-f] <branch>      checkout <branch> here; -f force-removes a worktree holding it
gwt reset [-d]                  cd back to the main repo root; -d also removes the worktree you left
gwt list                        list all worktrees for the current repo
gwt sync [-n] [--force] [<branch>|--all]
                                re-carry files from the main checkout into an existing worktree
gwt include                     show what a worktree would inherit; changes nothing
gwt init [--force]              wizard that writes this repo's .gwtrc
gwt setup [--force]             re-run this repo's setup hook here
gwt serve [stop|restart|status|logs [-f]|open]
                                point this repo's single dev server at the current worktree
gwt prune --merged [-n] [-f]    remove worktrees whose branch is merged or gone on origin
```

`gwt go` with no branch opens a picker over the worktrees that already exist — fzf if
you have it, a numbered menu if you do not.

`GWT_BASE` sets where worktrees live. The remote is `origin`.

## Carry-over

Creating a worktree copies files from the main checkout so `.env`, local config and
dependencies are usable right away. Copies use reflink where the filesystem supports
it, so a cloned `node_modules` costs almost no disk until something writes to it.

Put a `.worktreeinclude` at the repo root to say exactly what gets carried:

```
.env
.env*.local
node_modules
.next
!.next/cache
```

It is gitignore syntax, and `!` excludes. Because gitignore itself cannot re-include a
path inside an excluded directory, gwt applies `!` entries during the copy — so
`.next` is carried while `.next/cache` is left behind.

Resolution order is `<repo>/.worktreeinclude`, then `~/.config/gwt/<repo>/worktreeinclude`.
The first one found is used whole; they do not merge. With no file at all, gwt keeps its
original behaviour — every gitignored path except heavy regenerable directories like
`node_modules` and build output.

Tracked files are never carried. If an entry matches one, `gwt include` says so.
On the first real carry, `.worktreeinclude` and `.gwtrc` are added to
`.git/info/exclude` so they cannot be committed by accident.

`gwt include` prints the resolved plan with sizes and touches nothing. `gwt sync`
re-runs carry-over into a worktree that already exists — it refreshes files that have
drifted, but a directory the worktree already has is left alone unless you pass
`--force`, since that is where installed dependencies live.

## Setup hooks

`gwt init` writes the `.gwtrc` for you. It reads the repo first — package manager,
lockfile, dev script and the port baked into it — and arrives with those already
filled in and editable in place, so accepting a default and correcting one cost the
same. Nothing is written until it has shown you the finished file. `--force`
rewrites one that already exists.

Answers piped in work too: with no terminal to edit on, the defaults come back as
bracketed hints and colour is dropped, so it stays usable from a script.

Or write it by hand. A `.gwtrc` at the repo root says what should happen when a
worktree is created:

```zsh
GWT_SERVER='npm run dev'
GWT_SERVER_PORT=9000

gwt_setup() {
  gwt_step deps --watch package-lock.json --watch .nvmrc -- npm install
  gwt_step db -- ./bin/seed-branch-db.sh
}
```

`gwt add` runs carry-over, then setup, then cds you in. A failing hook still lands you
in the worktree and returns non-zero, so the failure is visible rather than silent.
`--no-setup` skips it and `gwt setup` re-runs it on demand.

`gwt_step` skips a step whose watched files are byte-identical to what was there the
last time it succeeded, and records the new hash only on success. A step with no
`--watch` always runs. `gwt setup --force` ignores the cache. State lives in the
worktree's own git directory, which git deletes when the worktree is removed, so the
cache never outlives what it describes.

Hooks run with `GWT_WORKTREE`, `GWT_BRANCH`, `GWT_MAIN_ROOT` and `GWT_REPO` exported.
`GWT_TEARDOWN` or a `gwt_teardown()` function runs in a worktree just before `gwt rm`
removes it; it can never block the removal. Resolution is `<repo>/.gwtrc`, then
`~/.config/gwt/<repo>/rc`, then `~/.config/gwt/rc`.

**`.gwtrc` is executed as zsh, so gwt refuses to source one that git tracks.** A
tracked config would run code from every `git pull`. Keep it untracked — gwt adds it
to `.git/info/exclude` for you.

## Pruning

`gwt prune --merged` removes every worktree whose branch is either merged into the
default branch or tracking an upstream that no longer exists on origin. It fetches
first, prints what it intends to remove with the reason, and asks before doing
anything; `-n` previews without prompting and `-f` skips the prompt.

Each removal goes through `gwt rm`, so everything that command refuses, it still
refuses: the worktree you are standing in is skipped rather than failed, an unmerged
branch keeps its branch after the worktree goes, teardown hooks run, and a dev server
pointed at a removed tree is stopped first.

## Dev server

One server per repo, retargetable at any worktree, supervised by systemd. It never
starts on its own: `gwt serve` is the only thing that starts or moves it.

```zsh
./install.sh          # symlinks the launcher, installs the unit, daemon-reload
```

Then, per repo, in an untracked `.gwtrc`:

```zsh
GWT_SERVER='npm run dev'
GWT_SERVER_PORT=9000
```

`gwt serve` inside any worktree points the server there and restarts it. `gwt serve
status` says which worktree owns it and whether the port is actually live, `gwt serve
logs -f` follows the journal, and `gwt list` marks the serving worktree with `▶`
alongside dirty and ahead/behind columns.

Two things keep it from going wrong. Before starting, gwt checks the port: if it is
held by a process that is not in this unit's cgroup, it refuses and prints the
offending command line rather than letting systemd restart-loop against it. And
removing a worktree the server points at stops the server first, so nothing is left
serving a directory that no longer exists.

The unit uses `KillMode=control-group`, because `next dev` and `concurrently` spawn
children that would otherwise survive a stop and keep holding the port. `install.sh`
bakes your current `PATH` into the unit: systemd starts with almost nothing, and zsh
does not read `.zshrc` for a non-interactive shell, so node would not otherwise
resolve. Re-run `install.sh` if your node version changes.

Set `GWT_SERVER_HINT=1` before sourcing the plugin to get a one-line note when you cd
into a worktree that is not the server's target. It is off by default because it costs
a git call on every directory change.

## Tests

```zsh
zsh test/run.zsh
```

Coverage is deliberately narrow: the destructive paths only — `rm`, `checkout -f`,
and `reset -d`, the ones that call `git worktree remove --force` and `git branch -d`.
Every test builds throwaway repos in a temp dir; the harness refuses to run at all
unless its sandbox is a directory it created itself under a temp root.

`GWT_TEST_KEEP=1` leaves the sandbox behind for inspection.

## Layout

```
gwt.plugin.zsh     entry point; sources lib/*.zsh and registers completion
lib/gwt.zsh        dispatcher, shared helpers, exit-code table
lib/config.zsh     .worktreeinclude and .gwtrc resolution
lib/sync.zsh       carry-over of gitignored files into a fresh worktree
lib/init.zsh       the 'gwt init' wizard and its stack detection
lib/setup.zsh      .gwtrc hooks and the gwt_step cache
lib/server.zsh     the singleton dev server client
lib/prune.zsh      branch classification for gwt prune
completions/_gwt   zsh completion
libexec/           gwt-serve-run, the systemd ExecStart target
systemd/           the gwt-server@.service template
install.sh         installs the launcher and the unit
test/              destructive-path tests (harness.zsh, run.zsh, test_*.zsh)
```

Exit codes are documented at the top of `lib/gwt.zsh`.
