#!/bin/zsh
# Builds and runs tests, printing only diagnostics and the test summary.
# Usage: scripts/check.sh [swift test filter]
cd "${0:A:h}/.." || exit 1
if [[ -n "$1" ]]; then
  swift test --filter "$1" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | grep -E "error:|warning: |originates here|✘|Test run|passed after|failed after|Expectation failed|issue" | grep -v "^error: Build failed" | sort -u | head -${LINES_MAX:-60}
else
  swift build --build-tests 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | grep -E "error:|warning: |originates here" | grep -v "^error: Build failed" | sort -u | head -${LINES_MAX:-60}
fi
