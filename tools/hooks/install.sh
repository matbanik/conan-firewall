#!/bin/sh
# Make tools/hooks/pre-commit the pre-commit hook of this checkout. Run once after a clone:
#     sh tools/hooks/install.sh
# It sets core.hooksPath for this repository only. Undo: git config --unset core.hooksPath
set -eu
cd "$(dirname "$0")/../.."
git rev-parse --git-dir >/dev/null
chmod +x tools/hooks/pre-commit 2>/dev/null || true
git config core.hooksPath tools/hooks
echo "pre-commit hook installed: every commit now runs tools/scan-public.py --staged"
