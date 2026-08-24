#!/bin/bash
# Produce the derivatives the overlay shows: per image named in index.json, a
# stage copy at most WxH (stage-<key>-WxH.jpg, never upscaled) and a 640×360 filmstrip thumb
# (bg-<key>.jpg), for whichever is missing. Idempotent and cheap when nothing
# is missing, so the overlay runs it on every open.
#
# This is the only place theme image bytes are decoded; the shell never opens
# a theme file, it shows these JPEGs. Each source is read once through
# read_bounded into a private snapshot, and the header check (loader
# allowlist, pixel ceiling) and both decodes run on that snapshot — what was
# checked is what is decoded. vips runs single-threaded under a deadline and
# an address-space limit, at bounded parallelism, and writes only into
# exclusively created files in our own thumbs dir. A source that is refused
# is remembered by key so it is not copied again on every open.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v vipsthumbnail >/dev/null && command -v vipsheader >/dev/null || exit 0

if [[ ${SWATCH_THUMBS_WRAPPED:-0} != 1 ]] && command -v timeout >/dev/null; then
  export SWATCH_THUMBS_WRAPPED=1
  exec timeout --signal=TERM --kill-after=5s 600s /bin/bash "$0" "$@"
fi

MAX_JOBS=512
PAR=$(( $(nproc) / 2 )); (( PAR < 1 )) && PAR=1; (( PAR > 4 )) && PAR=4

mkdir -p "$SWATCH_THUMBS"
# One run at a time. The lock descriptor is a read-only open of this script's
# own file: nothing is created or truncated, and no predictable path in a
# writable directory is involved. (A swap of the plugin's own code is outside
# every boundary — it is the code.)
exec 9<"${BASH_SOURCE[0]}" || exit 0
flock -n 9 || exit 0

index=$(read_bounded "$SWATCH_INDEX" "$MAX_INDEX_BYTES") || exit 0
jq -e '.themes | type == "array"' <<<"$index" >/dev/null 2>&1 || exit 0

# Stage size as index.sh measured it (largest monitor, physical pixels); bounded.
read -r W H < <(jq -r '"\(.stageW // 0) \(.stageH // 0)"' <<<"$index" 2>/dev/null)
[[ $W =~ ^[0-9]+$ && $H =~ ^[0-9]+$ ]] && (( W >= 320 && W <= 7680 && H >= 200 && H <= 4320 )) || { W=2560; H=1440; }

snapdir=$(mktemp -d "${XDG_RUNTIME_DIR:-$SWATCH_CACHE}/swatch-snap.XXXXXXXX") || exit 1
trap 'rm -rf -- "$snapdir"' EXIT

# A reject marker is an exclusive create (noclobber → O_EXCL), never a
# truncating redirect: a link planted at the predictable reject-<key> path
# makes the create fail, and nothing it points to is touched.
mark_reject() { (set -C; : >"$1") 2>/dev/null; }

# vips on one file, bounded: single-threaded, 2 GB address space, deadline.
# vipsthumbnail exits 0 on unreadable input, so the output is what is checked.
vips_to() {
  local src=$1 size=$2 out=$3 q=$4 tmp
  tmp=$(mktemp --suffix=.jpg "$SWATCH_THUMBS/.tmp.XXXXXXXX") || return 1
  ( ulimit -v 2097152 2>/dev/null; VIPS_CONCURRENCY=1 timeout --kill-after=2s 30s \
      vipsthumbnail "$src" --size "$size" --smartcrop=centre --no-rotate --path "$tmp[Q=$q,strip]" ) 2>/dev/null
  if [[ -s $tmp ]]; then mv -f -- "$tmp" "$out"; else rm -f -- "$tmp"; return 1; fi
}

# gen SRC KEY: both derivatives from one verified snapshot of SRC. Nothing is
# ever decoded by pathname — not the theme file, not our own cache.
gen() {
  local src=$1 key=$2 dir=$SWATCH_THUMBS
  local stage=$dir/stage-$key-${W}x${H}.jpg thumb=$dir/bg-$key.jpg reject=$dir/reject-$key snap line w=0 h=0 loader=""
  [[ $key =~ ^[0-9a-f]{16}$ ]] || return 0
  [[ -e $reject ]] && return 0
  [[ -f $stage && -f $thumb ]] && return 0
  snap=$(mktemp "$snapdir/img.XXXXXXXX") || return 0
  if ! read_bounded "$src" "$MAX_IMAGE_BYTES" >"$snap"; then rm -f -- "$snap"; mark_reject "$reject"; return 0; fi
  # Header of the snapshot: "<path>: <W>x<H> <fmt>, <bands> band(s), <space>, <loader>".
  # Capture before the loader test: a second =~ overwrites BASH_REMATCH.
  line=$(timeout 5s vipsheader -- "$snap" 2>/dev/null)
  if [[ $line =~ :\ ([0-9]+)x([0-9]+)\ [^,]+,\ [0-9]+\ bands?,\ [^,]+,\ ([a-z0-9]+)$ ]]; then
    w=${BASH_REMATCH[1]}; h=${BASH_REMATCH[2]}; loader=${BASH_REMATCH[3]}
  fi
  if [[ $loader =~ $LOADERS ]] && (( w > 0 && h > 0 && w * h <= MAX_PIXELS )); then
    [[ -f $stage ]] || vips_to "$snap" "${W}x${H}>" "$stage" 85 || mark_reject "$reject"
    [[ -f $thumb ]] || vips_to "$snap" 640x360 "$thumb" 80 || mark_reject "$reject"
  else
    mark_reject "$reject"
  fi
  rm -f -- "$snap"
  return 0
}
export -f gen vips_to read_bounded mark_reject
export SWATCH_READ_PY SWATCH_READ_PL SWATCH_THUMBS MAX_IMAGE_BYTES MAX_PIXELS LOADERS snapdir W H

# Jobs: current theme first so the first open lands on a finished stage;
# preview then backgrounds; one job per distinct image.
current=$(jq -r '.currentTheme // ""' <<<"$index")
jq -r --arg cur "$current" '
  (.themes | map(select(.name == $cur)) + map(select(.name != $cur)))[]
  | ([.preview // "", .previewKey // ""]), ([.backgrounds // [], .bgKeys // []] | transpose[])
  | select(.[0] != null and .[1] != null and .[0] != "" and .[1] != "")
  | "\(.[0])\t\(.[1])"' <<<"$index" 2>/dev/null |
  awk -F'\t' '!seen[$2]++' | head -n "$MAX_JOBS" |
  while IFS=$'\t' read -r src key; do
    [[ -f $SWATCH_THUMBS/stage-$key-${W}x${H}.jpg && -f $SWATCH_THUMBS/bg-$key.jpg ]] && continue
    [[ -e $SWATCH_THUMBS/reject-$key ]] && continue
    printf '%s\0%s\0' "$src" "$key"
  done |
  xargs -0 -r -n 2 -P "$PAR" bash -c 'gen "$1" "$2"' _

# Stage copies are per size. The current size's files are touched each run; a
# size nothing has used for 30 days (a monitor that is gone) is dropped, while
# a docked/undocked one stays warm.
find "$SWATCH_THUMBS" -maxdepth 1 -type f -name "stage-*-${W}x${H}.jpg" -exec touch -- {} + 2>/dev/null
find "$SWATCH_THUMBS" -maxdepth 1 -type f -name 'stage-*.jpg' ! -name "*-${W}x${H}.jpg" -mtime +30 -delete 2>/dev/null

# Sweep derivatives whose key no longer appears in the index (themes removed,
# files replaced) and anything else in our dir, so the cache tracks the
# collection instead of growing forever. Skipped on a partial index.
[[ $(jq -r '.partial // false' <<<"$index") == true ]] && exit 0
declare -A live=()
while IFS= read -r k; do [[ $k =~ ^[0-9a-f]{16}$ ]] && live[$k]=1; done < <(jq -r '.themes[] | (.previewKey // ""), (.bgKeys // [])[]' <<<"$index")
find "$SWATCH_THUMBS" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null | head -z -n 20000 |
  while IFS= read -r -d '' f; do
    b=${f##*/}
    case $b in
      bg-*.jpg)    k=${b#bg-}; k=${k%.jpg} ;;
      stage-*.jpg) k=${b#stage-}; k=${k%%-*} ;;
      reject-*)    k=${b#reject-} ;;
      *)           k="" ;;
    esac
    [[ -n $k && ${live[$k]:-} ]] || rm -f -- "$f"
  done
