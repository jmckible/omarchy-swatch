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

# omarchy-theme-set keeps one remembered background per theme, and this is the
# only place outside it that writes one. Same shape it writes (a path and a
# newline), one file per validated theme name, temp sibling + rename.
ostate=$HOME/.local/state/omarchy
remember() {
  local dir=$ostate/theme-backgrounds tmp
  valid_name "$1" && [[ $2 == /* ]] || return 1
  mkdir -p -- "$dir" && tmp=$(mktemp "$dir/.swatch.XXXXXXXX") || return 1
  printf '%s\n' "$2" >"$tmp" && mv -f -- "$tmp" "$dir/$1" || { rm -f -- "$tmp"; return 1; }
}

prev=$(cat "$ostate/current/theme.name" 2>/dev/null)
old=$(readlink -f "$ostate/current/background" 2>/dev/null)

# Will the desktop play an intro? The conditions omarchy-theme-set checks, and
# its own resolver for the clip, so this cannot disagree with what it does. An
# Omarchy without intros has no resolver and answers no.
intro_plays() {
  [[ -n $bg && $bg == /* && $prev != "$name" ]] || return 1
  [[ ! -f $ostate/toggles/background-intros-off ]] || return 1
  [[ $(timeout 2 hyprctl -j getoption animations:enabled 2>/dev/null | jq -r '.bool' 2>/dev/null) == true ]] || return 1
  [[ -n $(timeout 2 omarchy-theme-bg-boot-intro --resolve-only "$bg" 2>/dev/null) ]]
}

# An intro is stock's to play: it holds a cover, starts OWE on the first frame,
# fades the cover out once the clip is moving, and reloads Hyprland only after
# playback. None of that runs under OMARCHY_THEME_SKIP_BACKGROUND, so here the
# background is not set first. It is pinned instead, through the memory
# choose_theme_background() reads for a theme being switched *to* -- which is
# also why this path is only for a different theme: for the same one it cycles
# from the current link, and upstream plays no intro then anyway. The overlay
# holds its black until the shell's cover is gone (see introSettled).
if intro_plays && remember "$name" "$bg"; then
  exec omarchy-theme-set "$name"
fi

# Otherwise the background goes on first, and omarchy-theme-set is told to leave
# it alone. Left to itself it picks its own: choose_theme_background() cycles to
# whatever follows the current link, which is not the wallpaper the picker was
# showing -- and setting the right one afterwards swaps the wallpaper a second
# time, seconds later, once the retint hooks and cache warmups it runs first
# have finished. One swap, the one that was previewed, while the overlay still
# covers it.
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
omarchy-theme-set "$name"; rc=$?

# omarchy-theme-set remembers the outgoing theme's background from the current
# link, which the line above already moved -- so it filed the incoming theme's
# wallpaper under the outgoing theme, and the next stock switch back would land
# on it. Put back what that theme was actually showing.
if [[ -n $prev && $prev != "$name" && -f $old ]]; then
  remember "$prev" "$old"
fi
exit $rc
