#!/bin/bash
# Open Swatch and print the chosen theme name, or exit 1 on cancel.
# Drop-in for `theme=$(omarchy-theme-switcher)` — nothing is applied.
sel=$(mktemp); fin=$(mktemp); rm -f "$fin"
trap 'rm -f "$sel" "$fin"' EXIT
omarchy-shell shell summon jmckible.swatch \
  "$(jq -cn --arg s "$sel" --arg d "$fin" '{selectionFile: $s, doneFile: $d}')" >/dev/null || exit 1
while [[ ! -e $fin ]]; do sleep 0.02; done
[[ -s $sel ]] && cat "$sel" || exit 1
