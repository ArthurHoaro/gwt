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
```

`GWT_BASE` sets where worktrees live. The remote is `origin`.

Creating a worktree copies gitignored files (`.env`, local config, …) from the main
checkout, skipping heavy regenerable directories like `node_modules` and build output.

## Layout

```
gwt.plugin.zsh     entry point; sources lib/*.zsh and registers completion
lib/gwt.zsh        dispatcher, shared helpers, exit-code table
lib/sync.zsh       carry-over of gitignored files into a fresh worktree
completions/_gwt   zsh completion
```

Exit codes are documented at the top of `lib/gwt.zsh`.
