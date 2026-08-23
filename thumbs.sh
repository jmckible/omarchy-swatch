#!/bin/bash
# Generate every filmstrip thumbnail named in index.json that does not exist
# yet. Idempotent and cheap when nothing is missing, so the overlay runs it on
# every open.
#
# Every source is untrusted (it came from an installed theme). Before a byte
# reaches the decoder: regular non-symlink file, byte cap, header-declared
# loader in the allowlist, pixel cap. The decoder itself runs single-threaded,
# under a wall-clock timeout and an address-space limit, at bounded parallelism.
set -uo pipefail
index=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/swatch/index.json
thumbs_dir=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/swatch/thumbs
[[ -f $index && ! -L $index ]] || exit 0
command -v vipsthumbnail >/dev/null || exit 0
command -v vipsheader >/dev/null || exit 0

MAX_IMAGE_BYTES=67108864   # 64 MB — 4K PNG wallpapers run 10–30 MB
MAX_PIXELS=50000000        # 50 MP — 8K is 33 MP
MAX_JOBS=512
LOADERS='^(jpegload|pngload|webpload|gifload)$'
PAR=$(( $(nproc) / 2 )); (( PAR < 1 )) && PAR=1; (( PAR > 8 )) && PAR=8

gen() {
  local src=$1 dst=$2 tmp="${2%.jpg}.$$.jpg" line loader dims w h
  [[ -f $dst ]] && return 0
  [[ -f $src && ! -L $src ]] || return 0
  (( $(stat -c %s -- "$src") <= MAX_IMAGE_BYTES )) || return 0
  # One header read gives "path: WxH uchar, N bands, space, loader".
  line=$(timeout 5s vipsheader -- "$src" 2>/dev/null) || return 0
  loader=${line##*, }
  [[ $loader =~ $LOADERS ]] || return 0
  dims=${line#*: }; dims=${dims%% *}
  w=${dims%x*}; h=${dims#*x}
  [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 0
  (( w * h <= MAX_PIXELS )) || return 0
  if ( ulimit -v 2097152 2>/dev/null; VIPS_CONCURRENCY=1 timeout --kill-after=2s 20s \
         vipsthumbnail "$src" --size 640x360 --smartcrop=centre --path "$tmp[Q=80,strip]" ) 2>/dev/null; then
    mv -f -- "$tmp" "$dst"
  else
    rm -f -- "$tmp"
  fi
}
export -f gen
export MAX_IMAGE_BYTES MAX_PIXELS LOADERS

# Only write into our own thumbs dir, and only names index.sh would have made.
jq -r --arg dir "$thumbs_dir" '
  .themes[]?
  | (select((.thumb // "") != "" and (.preview // "") != "") | "\(.preview)\t\(.thumb)"),
    ([.backgrounds // [], .bgThumbs // []] | transpose[] | select(.[0] != null and .[1] != null) | "\(.[0])\t\(.[1])")
  | select(split("\t")[1] | startswith($dir + "/"))' "$index" 2>/dev/null |
  head -n "$MAX_JOBS" |
  while IFS=$'\t' read -r src dst; do
    [[ -f $dst ]] || printf '%s\0%s\0' "$src" "$dst"
  done |
  xargs -0 -r -n 2 -P "$PAR" bash -c 'gen "$1" "$2"' _
