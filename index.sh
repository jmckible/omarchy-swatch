#!/bin/bash
# Emit the theme index as JSON on stdout. One record per installed theme;
# a record is carried over from the cached index when its signature is
# unchanged, so a warm run is a find, a stat loop, and two jq calls. Only
# themes whose files changed pay for omarchy-theme-color.
#
# Trust model: an installed theme is untrusted input (anyone can
# `omarchy theme install` a hostile repo). A theme directory may itself be a
# symlink (that is how people develop themes), but nothing *inside* one is
# followed: every file must be a regular, non-symlink file that resolves
# under the theme's own directory or the user's per-theme backgrounds dir,
# within size and count ceilings, or it is ignored.
set -uo pipefail

# One deadline for the whole run, so a pathological tree cannot hang the shell.
if [[ ${SWATCH_INDEX_WRAPPED:-0} != 1 ]] && command -v timeout >/dev/null; then
  export SWATCH_INDEX_WRAPPED=1
  exec timeout --signal=TERM --kill-after=2s 20s /bin/bash "$0" "$@"
fi

MAX_THEMES=512
MAX_BACKGROUNDS=200
MAX_PATH_BYTES=512
MAX_TOML_BYTES=65536        # colors.toml / shell.toml are hundreds of bytes to a few KB
MAX_VIDEO_BYTES=268435456   # 256 MB
MAX_IMAGE_BYTES=67108864    # 64 MB — 4K PNG wallpapers run 10–30 MB
MAX_PIXELS=50000000         # 50 MP — 8K is 33 MP
LOADERS='^(jpegload|pngload|webpload|gifload)$'
MAX_INDEX_BYTES=8388608     # cached index.json larger than this is discarded
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

cache=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/swatch
thumbs=$cache/thumbs
index=$cache/index.json
user_themes=$HOME/.config/omarchy/themes
user_bgs=$HOME/.config/omarchy/backgrounds
stock_themes=${OMARCHY_PATH:-$HOME/.local/share/omarchy}/themes
state=$HOME/.local/state/omarchy/current
mkdir -p "$thumbs"

# The cached index is our own output, but it lives in a writable cache dir:
# size-cap it and require valid JSON of the expected shape before trusting it.
prev='{"themes":[]}'
if [[ -f $index && ! -L $index ]] && (( $(stat -c %s "$index") <= MAX_INDEX_BYTES )); then
  if jq -e '.themes | type == "array"' "$index" >/dev/null 2>&1; then
    prev=$(cat "$index")
  fi
fi

image_find=(-type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' \))
video_find=(-type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' \))

# Regular, non-symlink file whose real path stays under one of the allowed
# roots, with a bounded path length and (optionally) byte size.
safe_file() {
  local f=$1 max=${2:-0} real root ok=0
  [[ -f $f && ! -L $f ]] || return 1
  (( ${#f} <= MAX_PATH_BYTES )) || return 1
  real=$(realpath -e -- "$f" 2>/dev/null) || return 1
  for root in "${ALLOWED_ROOTS[@]}"; do
    [[ -n $root && $real == "$root/"* ]] && { ok=1; break; }
  done
  (( ok )) || return 1
  (( max == 0 )) || (( $(stat -c %s -- "$f") <= max )) || return 1
  return 0
}

sig() {
  local d=$1 f
  {
    echo v5   # record schema version: bump when resolve() output changes
    stat -Lc '%Y' -- "$d"
    [[ -d $d/backgrounds ]] && stat -c 'bg:%Y' -- "$d/backgrounds"
    [[ -d $user_bgs/${d##*/} ]] && stat -c 'ubg:%Y' -- "$user_bgs/${d##*/}"
    for f in colors.toml shell.toml alacritty.toml preview.png preview.jpg preview.jpeg preview.webp; do
      [[ -e $d/$f ]] && stat -c "$f:%s:%Y" -- "$d/$f"
    done
  } 2>/dev/null | paste -sd,
}

# Images we are willing to decode later (full-size in the overlay, thumbs in
# thumbs.sh): byte cap, then loader and pixel count from the header. One
# vipsheader call per batch reads only headers — the decoder is never
# touched here. A file that fails to parse is dropped; order is preserved.
filter_images() {
  local -a files=() keep=()
  local f line rest w h loader
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    (( $(stat -c %s -- "$f") <= MAX_IMAGE_BYTES )) && files+=("$f")
  done
  (( ${#files[@]} )) || return 0
  declare -A ok=()
  while IFS= read -r line; do
    # "<path>: <W>x<H> <fmt>, <bands> band(s), <space>, <loader>" — parse from
    # the right so a ": " inside the path cannot confuse it.
    [[ $line =~ ^(.*):\ ([0-9]+)x([0-9]+)\ [^,]+,\ [0-9]+\ bands?,\ [^,]+,\ ([a-z0-9]+)$ ]] || continue
    f=${BASH_REMATCH[1]}; w=${BASH_REMATCH[2]}; h=${BASH_REMATCH[3]}; loader=${BASH_REMATCH[4]}
    [[ $loader =~ $LOADERS ]] || continue
    (( w * h <= MAX_PIXELS )) || continue
    ok["$f"]=1
  done < <(timeout 10s vipsheader -- "${files[@]}" 2>/dev/null)
  for f in "${files[@]}"; do [[ ${ok["$f"]:-} ]] && printf '%s\n' "$f"; done
}

# Files directly inside a directory, without following symlinks, filtered
# through safe_file (and filter_images when asked), sorted, capped.
list_files() {
  local dir=$1 max=$2 kind=$3; shift 3
  [[ -d $dir ]] || return 0
  local listing
  listing=$(find -H "$dir" -mindepth 1 -maxdepth 1 "$@" -print0 2>/dev/null | sort -z |
    while IFS= read -r -d '' f; do safe_file "$f" && printf '%s\n' "$f"; done | head -n "$max")
  if [[ $kind == image ]]; then filter_images <<<"$listing"; else printf '%s\n' "$listing"; fi | grep -v '^$'
}

resolve() {
  local path=$1 src=$2 name=${1##*/}
  local real colors=/dev/null shell=/dev/null preview="" video="" s key tmp="" b bstem vstem
  real=$(realpath -e -- "$path" 2>/dev/null) || return 0
  ALLOWED_ROOTS=("$real" "$(realpath -e -- "$user_bgs/$name" 2>/dev/null || true)")
  s=$(sig "$path")
  key=$(printf '%s' "$s" | md5sum | cut -c1-12)

  safe_file "$path/colors.toml" "$MAX_TOML_BYTES" && colors=$path/colors.toml
  safe_file "$path/shell.toml" "$MAX_TOML_BYTES" && shell=$path/shell.toml

  # Legacy alacritty-only theme: convert into scratch, the way theme-set does.
  if [[ $colors == /dev/null ]] && safe_file "$path/alacritty.toml" "$MAX_TOML_BYTES"; then
    tmp=$(mktemp -d)
    cp -- "$path/alacritty.toml" "$tmp/"
    omarchy-theme-colors-from-alacritty "$tmp" >/dev/null 2>&1
    [[ -f $tmp/colors.toml ]] && (( $(stat -c %s "$tmp/colors.toml") <= MAX_TOML_BYTES )) && colors=$tmp/colors.toml
  fi

  preview=$(list_files "$path" 1 image -iname 'preview.*' "${image_find[@]}")
  # Backgrounds: the user's per-theme dir first, then the theme's own, sorted — same order theme-set cycles.
  local bgs
  bgs=$( { list_files "$user_bgs/$name" "$MAX_BACKGROUNDS" image "${image_find[@]}"
           list_files "$path/backgrounds" "$MAX_BACKGROUNDS" image "${image_find[@]}"; } | head -n "$MAX_BACKGROUNDS" )
  [[ -n $preview ]] || preview=$(head -n1 <<<"$bgs")

  video=$( { list_files "$user_bgs/$name" 1 video "${video_find[@]}"
             list_files "$path/backgrounds" 1 video "${video_find[@]}"; } | head -n1 )
  [[ -n $video ]] && ! safe_file "$video" "$MAX_VIDEO_BYTES" && video=""
  # The video is the theme's intro, not a wallpaper. A still sharing its
  # basename is its poster frame: recorded as videoStill and excluded from
  # the selectable backgrounds (stock tooling never globs videos at all).
  local video_still=""
  if [[ -n $video ]]; then
    vstem=${video##*/}; vstem=${vstem%.*}
    while IFS= read -r b; do
      [[ -n $b ]] || continue
      bstem=${b##*/}; bstem=${bstem%.*}
      [[ $bstem == "$vstem" ]] && { video_still=$b; break; }
    done <<<"$bgs"
    [[ -n $video_still ]] && bgs=$(grep -vxF -- "$video_still" <<<"$bgs")
  fi
  # One filmstrip thumb per background, keyed by path + stat so a replaced
  # file gets a new thumb. Cold path only; the record caches the names.
  local bgthumbs=""
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    bgthumbs+="$thumbs/bg-$(printf '%s\t%s' "$b" "$(stat -c '%s:%Y' -- "$b" 2>/dev/null)" | md5sum | cut -c1-16).jpg"$'\n'
  done <<<"$bgs"

  omarchy-theme-color --file "$colors" --all 2>/dev/null | head -c 65536 | jq -Rs \
    --arg name "$name" --arg src "$src" --arg path "$path" --arg sig "$s" \
    --arg preview "$preview" --arg video "$video" --arg videoStill "$video_still" \
    --arg thumb "$( [[ -n $preview ]] && printf '%s/%s-%s.jpg' "$thumbs" "$name" "$key" )" \
    --arg bgs "$bgs" --arg bgthumbs "$bgthumbs" \
    --rawfile colors "$colors" --rawfile shell "$shell" '
    (split("\n") | map(select(length > 0 and length <= 512) | split("\t") | select(length >= 2) | {(.[0]): .[1]}) | add // {}) as $c
    | { name: $name,
        label: ($name | split("-") | map((.[:1] | ascii_upcase) + .[1:]) | join(" ")),
        source: $src, path: $path, signature: $sig,
        mode: (($c.mode // "dark") | ascii_downcase),
        colors: ($c | {background, foreground, accent, selection, muted, red, yellow, green, cyan, blue, magenta}),
        preview: $preview, thumb: $thumb, video: $video, videoStill: $videoStill,
        backgrounds: ($bgs | split("\n") | map(select(length > 0))),
        bgThumbs: ($bgthumbs | split("\n") | map(select(length > 0))),
        colorsToml: $colors, shellToml: $shell }'
  [[ -n $tmp ]] && rm -rf -- "$tmp"
}

# 1. Walk. User dir first so it wins the name collision in step 3. A theme
#    entry may be a symlink; its name must be a plain slug (it becomes a
#    thumb filename and an argument to omarchy-theme-set).
rows=$(mktemp); fresh=$(mktemp); trap 'rm -f "$rows" "$fresh"' EXIT
for entry in "user:$user_themes" "stock:$stock_themes"; do
  src=${entry%%:*}; dir=${entry#*:}
  [[ -d $dir ]] || continue
  while IFS= read -r -d '' path; do
    name=${path##*/}
    [[ $name =~ $NAME_RE && $name != *..* ]] || continue
    [[ -d $path ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$name" "$(sig "$path")" "$path" "$src"
  done < <(find -H "$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 2>/dev/null | sort -z)
done | head -n "$MAX_THEMES" >"$rows"

# 2. Resolve only rows with no cached record for (name, signature).
jq -r --rawfile rows "$rows" '
  ([.themes[]? | {key: "\(.name)\t\(.signature)", value: true}] | from_entries) as $have
  | $rows | split("\n") | map(select(length > 0) | split("\t")) | unique_by(.[0])
  | map(select($have["\(.[0])\t\(.[1])"] | not) | "\(.[2])\t\(.[3])") | .[]' <<<"$prev" |
while IFS=$'\t' read -r path src; do
  [[ -n $path ]] && resolve "$path" "$src"
done >"$fresh"

# 3. Merge in walk order, flag shadowed names, add session state, publish atomically.
current_theme=$(head -c 256 "$state/theme.name" 2>/dev/null | tr -d '\n' || true)
current_bg=$(readlink -f "$state/background" 2>/dev/null || true)
jq -n --rawfile rows "$rows" --slurpfile prev <(printf '%s' "$prev") --slurpfile fresh "$fresh" \
      --arg currentTheme "$current_theme" --arg currentBackground "$current_bg" '
  (($prev[0].themes + $fresh) | map({key: "\(.name)\t\(.signature)", value: .}) | from_entries) as $rec
  | ($rows | split("\n") | map(select(length > 0) | split("\t"))) as $all
  | ($all | map(.[0]) | group_by(.) | map(select(length > 1) | .[0])) as $dupes
  | { version: 1,
      currentTheme: $currentTheme,
      currentBackground: $currentBackground,
      themes: ($all | unique_by(.[0])
        | map(. as $r | $rec["\($r[0])\t\($r[1])"] | select(. != null)
              | . + { shadowsStock: ($dupes | index($r[0]) != null) })) }' \
  >"$index.$$" && mv -f "$index.$$" "$index"
cat "$index"
