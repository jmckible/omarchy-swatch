#!/bin/bash
# Generate every filmstrip thumbnail named in index.json that does not exist
# yet. Idempotent and cheap when nothing is missing, so the overlay runs it on
# every open. One single-threaded vips per image, nproc at a time.
set -uo pipefail
index=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/swatch/index.json
[[ -f $index ]] || exit 0
command -v vipsthumbnail >/dev/null || exit 0

gen() {
  local src=$1 dst=$2 tmp="${2%.jpg}.$$.jpg"
  [[ -f $dst ]] && return 0
  if VIPS_CONCURRENCY=1 vipsthumbnail "$src" --size 640x360 --smartcrop=centre --path "$tmp[Q=80,strip]" 2>/dev/null; then
    mv -f "$tmp" "$dst"
  else
    rm -f "$tmp"
  fi
}
export -f gen

jq -r '.themes[]
       | (select(.thumb != "" and .preview != "") | "\(.preview)\t\(.thumb)"),
         ([.backgrounds, (.bgThumbs // [])] | transpose[] | select(.[0] != null and .[1] != null) | "\(.[0])\t\(.[1])")' "$index" |
  while IFS=$'\t' read -r src dst; do
    [[ -f $dst ]] || printf '%s\0%s\0' "$src" "$dst"
  done |
  xargs -0 -r -n 2 -P "$(nproc)" bash -c 'gen "$1" "$2"' _
