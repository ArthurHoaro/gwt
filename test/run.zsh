#!/usr/bin/env zsh
# Runs every test_*.zsh in its own process. Exit 0 only if all pass.

emulate -L zsh
setopt no_nomatch

local here="${0:A:h}"
local -a files
files=( "$here"/test_*.zsh(N) )
(( ${#files} )) || { print -ru2 -- "no tests found in $here"; exit 1 }

local f failed=0
for f in $files; do
  print -r -- "── ${f:t:r}"
  zsh "$f" || (( failed++ ))
done

print -r -- ""
if (( failed )); then
  print -r -- "FAILED: $failed of ${#files} test file(s)"
  exit 1
fi
print -r -- "PASSED: ${#files} test file(s)"
