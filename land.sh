#!/bin/bash
# The exit's landing probe, polled while the overlay holds its black.
#
#   land.sh <background>   prints three lines:
#     where the current-background link resolves
#     where <background> resolves
#     "pending" while the shell is mid theme intro, else "ready"
#
# The intro token is the staged theme directory's inode, which is what
# omarchy-theme-set hands prepareThemeIntro. It names next-theme until the swap
# and current/theme after it -- mv keeps the inode -- so both are asked, and an
# intro is seen from its first prepare rather than only once the link lands.
set -u
o=$HOME/.local/state/omarchy/current
readlink -f -- "$o/background" 2>/dev/null || echo
readlink -f -- "${1:-}" 2>/dev/null || echo
status=ready
for d in "$o/next-theme" "$o/theme"; do
  t=$(stat -Lc '%d:%i' -- "$d" 2>/dev/null) || continue
  [[ $(timeout 1 omarchy-shell shell themeIntroStatus "$t" 2>/dev/null) == pending ]] && { status=pending; break; }
done
echo "$status"
