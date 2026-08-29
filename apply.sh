#!/bin/bash
# The overlay's only writes and its only hand-off to Omarchy, argv in, nothing
# composed into a shell string.
#
#   apply.sh <theme> [background]   apply, pinning the background that was shown
#   apply.sh --pick <dir> [theme]   answer pick.sh: selection (if any) and done
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PATH="${OMARCHY_PATH:-$HOME/.local/share/omarchy}/bin:$PATH"

if [[ ${1:-} == --pick ]]; then
  dir=${2:-}; name=${3:-}
  [[ -n $dir ]] || exit 1
  # pick.sh made the directory with mktemp -d (0700). Both files are created
  # exclusively (noclobber → O_EXCL), so nothing planted there can redirect them.
  set -C
  if [[ -n $name ]] && valid_name "$name"; then printf '%s\n' "$name" >"$dir/selection"; fi
  : >"$dir/done"
  exit 0
fi

name=${1:-}; bg=${2:-}
valid_name "$name" || exit 1

# The background goes on first, and omarchy-theme-set is told to leave it alone.
# Left to itself it picks its own: choose_theme_background() cycles to whatever
# follows the current link, which is not the wallpaper the picker was showing --
# and setting the right one afterwards swaps the wallpaper a second time, seconds
# later, once the retint hooks and cache warmups it runs first have finished.
# One swap, the one that was previewed, while the overlay still covers it.
#
# If a future omarchy drops the variable this degrades to that older two-swap
# behaviour rather than breaking, and a background that has since gone away
# leaves the stock choice in charge.
#
# The instant swap first: the overlay lifts its black on the symlink landing,
# and the shell's own 420 ms reveal would still be running at that point --
# caught half-finished under a cover that has just come off. setInstant leaves
# nothing to catch, and omarchy-theme-bg-set's own `background set` then
# early-returns because currentBackground already matches. If the IPC is not
# answered this degrades to the animated reveal rather than failing.
if [[ -n $bg && $bg == /* ]]; then
  timeout 2 omarchy-shell -q background setInstant "$bg" >/dev/null 2>&1
  if omarchy-theme-bg-set "$bg" >/dev/null 2>&1; then
    export OMARCHY_THEME_SKIP_BACKGROUND=1
  fi
fi
exec omarchy-theme-set "$name"
