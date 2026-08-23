#!/bin/bash
# Open Swatch and print the chosen theme name, or exit 1 on cancel.
# Drop-in for `theme=$(omarchy-theme-switcher)` — nothing is applied.
dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$dir"' EXIT
omarchy-shell shell summon jmckible.swatch "$(jq -cn --arg d "$dir" '{dir: $d}')" >/dev/null || exit 1
while [[ ! -e $dir/done ]]; do sleep 0.02; done
[[ -s $dir/selection ]] && head -c 256 -- "$dir/selection" || exit 1
