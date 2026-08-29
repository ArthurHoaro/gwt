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
```

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
lib/sync.zsh       carry-over of gitignored files into a fresh worktree
completions/_gwt   zsh completion
test/              destructive-path tests (harness.zsh, run.zsh, test_*.zsh)
```

Exit codes are documented at the top of `lib/gwt.zsh`.
