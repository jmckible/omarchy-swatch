#!/bin/bash
# The overlay's only writes and its only hand-off to Omarchy, argv in, nothing
# composed into a shell string.
#
#   apply.sh <theme> [background]   apply, the way the stock picker does
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
omarchy-theme-set "$name" || exit
[[ -n $bg ]] && exec omarchy-theme-bg-set "$bg"
exit 0
