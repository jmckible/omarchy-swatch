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
#
# Exit 2 means "not this time": the deadline was hit, which says the machine
# was busy, not that the file is bad. That distinction matters because a
# refusal is remembered forever — see gen(). A wallpaper that timed out once
# under load would otherwise lose its filmstrip thumb permanently, since its
# key stays live and the sweep never revisits it.
vips_to() {
  local src=$1 size=$2 out=$3 q=$4 tmp rc
  tmp=$(mktemp --suffix=.jpg "$SWATCH_THUMBS/.tmp.XXXXXXXX") || return 1
  ( ulimit -v 2097152 2>/dev/null; VIPS_CONCURRENCY=1 timeout --kill-after=2s 30s \
      vipsthumbnail "$src" --size "$size" --smartcrop=centre --no-rotate --path "$tmp[Q=$q,strip]" ) 2>/dev/null
  rc=$?
  if [[ -s $tmp ]]; then mv -f -- "$tmp" "$out"; return 0; fi
  rm -f -- "$tmp"
  (( rc == 124 || rc == 137 )) && return 2   # deadline, or killed after it
  return 1
}

# ffmpeg on one snapshot, bounded like vips is. The output is transcoded, not
# copied: the shell must decode bytes our own encoder wrote, exactly as it
# decodes our JPEGs and never a theme's PNG. A validated copy would still hand
# a long-lived decoder attacker-shaped bytes, which is the thing the posture
# exists to prevent — the ffprobe gate only decides whether to transcode.
#
# Audio, subtitles, data streams and metadata are dropped. A theme picker that
# makes noise is a bug, and every stream not carried is a decoder not reached.
video_to() {
  local src=$1 out=$2 tmp
  tmp=$(mktemp --suffix=.mp4 "$SWATCH_THUMBS/.tmp.XXXXXXXX") || return 1
  local rc
  ( ulimit -v 4194304 2>/dev/null; timeout --kill-after=5s 120s \
      ffmpeg -nostdin -v error -y -threads 1 -i "$src" \
        -an -sn -dn -map_metadata -1 \
        -vf "scale=w='min(iw,$W)':h='min(ih,$H)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2" \
        -c:v libx264 -preset veryfast -crf 26 -pix_fmt yuv420p -movflags +faststart \
        -f mp4 -- "$tmp" ) 2>/dev/null
  rc=$?
  if [[ -s $tmp ]]; then mv -f -- "$tmp" "$out"; return 0; fi
  rm -f -- "$tmp"
  (( rc == 124 || rc == 137 )) && return 2   # deadline: retry later, do not condemn the file
  return 1
}

# gen_video SRC KEY: the animated derivative, from one verified snapshot.
# Same shape as gen(): read once through a descriptor, check the snapshot,
# encode the snapshot, and remember a refusal by key.
gen_video() {
  local src=$1 key=$2 dir=$SWATCH_THUMBS
  local out=$dir/vid-$key.mp4 reject=$dir/reject-$key snap probe fmt codec w h dur
  [[ $key =~ ^[0-9a-f]{16}$ ]] || return 0
  [[ -e $reject ]] && return 0
  [[ -f $out ]] && return 0
  command -v ffprobe >/dev/null && command -v ffmpeg >/dev/null || return 0
  snap=$(mktemp "$snapdir/vid.XXXXXXXX") || return 0
  if ! read_bounded "$src" "$MAX_VIDEO_BYTES" >"$snap"; then rm -f -- "$snap"; mark_reject "$reject"; return 0; fi
  # ffprobe is a producer like every other: deadline, bounded output, and the
  # answer is shape-checked rather than trusted.
  probe=$(timeout 10s ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name,width,height -show_entries format=format_name,duration \
            -of json -- "$snap" 2>/dev/null | head -c 65536)
  read -r codec w h fmt dur < <(jq -r '
      ((.streams // [])[0] // {}) as $s | (.format // {}) as $f
      | "\($s.codec_name // "-") \($s.width // 0) \($s.height // 0) \($f.format_name // "-") \(($f.duration // "0") | tonumber? // 0 | floor)"
    ' <<<"$probe" 2>/dev/null)
  if [[ $fmt =~ $VIDEO_FORMATS && $codec =~ $VIDEO_CODECS ]] \
     && [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ && $dur =~ ^[0-9]+$ ]] \
     && (( w > 0 && h > 0 && w <= MAX_VIDEO_WIDTH && h <= MAX_VIDEO_HEIGHT )) \
     && (( dur > 0 && dur <= MAX_VIDEO_SECONDS )); then
    video_to "$snap" "$out"; local vrc=$?; (( vrc == 1 )) && mark_reject "$reject"
  else
    mark_reject "$reject"
  fi
  rm -f -- "$snap"
  return 0
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
  # A marker is a statement about the file, so only a real refusal earns one:
  # a header we do not accept, or a render that failed for a reason other than
  # the deadline. A timeout (rc 2) leaves no marker and is simply retried on a
  # later open, which is what makes a busy machine recoverable.
  local rc
  if [[ $loader =~ $LOADERS ]] && (( w > 0 && h > 0 && w * h <= MAX_PIXELS )); then
    if [[ ! -f $stage ]]; then vips_to "$snap" "${W}x${H}>" "$stage" 85; rc=$?; (( rc == 1 )) && mark_reject "$reject"; fi
    if [[ ! -f $thumb ]]; then vips_to "$snap" 640x360 "$thumb" 80; rc=$?; (( rc == 1 )) && mark_reject "$reject"; fi
  else
    mark_reject "$reject"
  fi
  rm -f -- "$snap"
  return 0
}
export -f gen gen_video vips_to video_to read_bounded mark_reject
export SWATCH_READ_PY SWATCH_READ_PL SWATCH_THUMBS MAX_IMAGE_BYTES MAX_PIXELS LOADERS snapdir W H
export MAX_VIDEO_BYTES MAX_VIDEO_SECONDS MAX_VIDEO_WIDTH MAX_VIDEO_HEIGHT VIDEO_FORMATS VIDEO_CODECS

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

# Animated backgrounds, after every still: a clip is a nicety and a transcode
# is the most expensive thing here, so stills must never wait behind one. Same
# ordering (current theme first) and the same dedupe by key.
jq -r --arg cur "$current" '
  (.themes | map(select(.name == $cur)) + map(select(.name != $cur)))[]
  | [.bgVideos // [], .bgVideoKeys // []] | transpose[]
  | select(.[0] != null and .[1] != null and .[0] != "" and .[1] != "")
  | "\(.[0])\t\(.[1])"' <<<"$index" 2>/dev/null |
  awk -F'\t' '!seen[$2]++' | head -n "$MAX_JOBS" |
  while IFS=$'\t' read -r src key; do
    [[ -f $SWATCH_THUMBS/vid-$key.mp4 ]] && continue
    [[ -e $SWATCH_THUMBS/reject-$key ]] && continue
    printf '%s\0%s\0' "$src" "$key"
  done |
  xargs -0 -r -n 2 -P "$PAR" bash -c 'gen_video "$1" "$2"' _

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
while IFS= read -r k; do [[ $k =~ ^[0-9a-f]{16}$ ]] && live[$k]=1; done < <(jq -r '.themes[] | (.previewKey // ""), (.bgKeys // [])[], ((.bgVideoKeys // [])[] | select(. != ""))' <<<"$index")
find "$SWATCH_THUMBS" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null | head -z -n 20000 |
  while IFS= read -r -d '' f; do
    b=${f##*/}
    case $b in
      bg-*.jpg)    k=${b#bg-}; k=${k%.jpg} ;;
      vid-*.mp4)   k=${b#vid-}; k=${k%.mp4} ;;
      stage-*.jpg) k=${b#stage-}; k=${k%%-*} ;;
      reject-*)    k=${b#reject-} ;;
      *)           k="" ;;
    esac
    [[ -n $k && ${live[$k]:-} ]] || rm -f -- "$f"
  done
