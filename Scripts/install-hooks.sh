#!/bin/bash
# Points git at Scripts/git-hooks, so its pre-commit hook formats committed Swift files with
# SwiftFormat. Once per clone; the setting is shared by the clone's worktrees.

set -e
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git config core.hooksPath Scripts/git-hooks
echo "Git hooks: Scripts/git-hooks"
command -v swiftformat >/dev/null || echo "warning: swiftformat not found; brew install swiftformat"
