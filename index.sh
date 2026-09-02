#!/bin/bash
# Emit the theme index as JSON on stdout. One record per installed theme;
# a record is carried over from the cached index when its signature is
# unchanged, so a warm run is a find, a stat loop, and two jq calls. Only
# themes whose files changed pay for omarchy-theme-color.
#
# The index is an inventory, not a trust decision. The paths it records are
# names; the one consumer that decodes them (thumbs.sh — the shell itself
# never opens a theme file) re-establishes trust on the descriptor it reads.
# The bytes this script parses — two TOML files per theme, the cached index,
# the state files — arrive only through read_bounded (lib.sh).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# One deadline for the whole run, so a pathological tree cannot hang the shell.
if [[ ${SWATCH_INDEX_WRAPPED:-0} != 1 ]] && command -v timeout >/dev/null; then
  export SWATCH_INDEX_WRAPPED=1
  exec timeout --signal=TERM --kill-after=2s 20s /bin/bash "$0" "$@"
fi
RESOLVE_BUDGET=14   # seconds; themes not resolved by then land on a later open

cache=$SWATCH_CACHE; thumbs=$SWATCH_THUMBS; index=$SWATCH_INDEX
user_themes=$HOME/.config/omarchy/themes
user_bgs=$HOME/.config/omarchy/backgrounds
stock_themes=${OMARCHY_PATH:-$HOME/.local/share/omarchy}/themes
state=$HOME/.local/state/omarchy/current
mkdir -p "$thumbs"

# Private scratch for this run: TOML snapshots and the legacy-theme conversion.
run=$(mktemp -d "${XDG_RUNTIME_DIR:-$cache}/swatch-index.XXXXXXXX") || exit 1
trap 'rm -rf -- "$run"' EXIT
rows=$run/rows; fresh=$run/fresh

# The cached index is our own output, but it lives in a writable cache dir:
# it comes in through the same bounded descriptor as everything else and
# must have the expected shape before any record is reused.
prev='{"themes":[]}'
if p=$(read_bounded "$index" "$MAX_INDEX_BYTES") && jq -e '.themes | type == "array"' <<<"$p" >/dev/null 2>&1; then
  prev=$p
fi

image_find=(-type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' \))
video_find=(-type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' \))

# Inventory filter, advisory only: a directory entry is listed when it is a
# regular non-symlink file with a bounded path that resolves under one of
# the allowed roots and is not absurdly large. Nothing is decided from this;
# thumbs.sh re-verifies on the descriptor it decodes.
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
    echo v7   # record schema version: bump when resolve() output changes
    stat -Lc '%Y' -- "$d"
    [[ -d $d/backgrounds ]] && stat -c 'bg:%Y' -- "$d/backgrounds"
    [[ -d $user_bgs/${d##*/} ]] && stat -c 'ubg:%Y' -- "$user_bgs/${d##*/}"
    for f in colors.toml shell.toml alacritty.toml preview.png preview.jpg preview.jpeg preview.webp; do
      [[ -e $d/$f ]] && stat -c "$f:%s:%Y" -- "$d/$f"
    done
  } 2>/dev/null | paste -sd,
}

# Files directly inside a directory: no symlinks followed, at most
# MAX_DIR_ENTRIES readdir entries considered, sorted, filtered, capped.
list_files() {
  local dir=$1 max=$2 bytes=${LIST_BYTES:-$MAX_IMAGE_BYTES}; shift 2
  [[ -d $dir ]] || return 0
  find -H "$dir" -mindepth 1 -maxdepth 1 "$@" -print0 2>/dev/null | head -z -n "$MAX_DIR_ENTRIES" | sort -z |
    while IFS= read -r -d '' f; do safe_file "$f" "$bytes" && printf '%s\n' "$f"; done | head -n "$max"
}

# One cache key per image, from its path and stat, so a replaced file gets
# new derivatives. thumbs.sh names bg-<key>.jpg and stage-<key>-WxH.jpg by it.
image_key() { printf '%s\t%s' "$1" "$(stat -c '%s:%Y' -- "$1" 2>/dev/null)" | md5sum | cut -c1-16; }

# Stage size: the largest connected monitor, in physical pixels. (Qt rounds
# devicePixelRatio under fractional scaling, so the QML side cannot know this.)
# Compositor output is a producer like any other — deadline, byte ceiling,
# shape and range check — or a sane default.
stage_size() {
  local out w h
  out=$(timeout 3s hyprctl monitors -j 2>/dev/null | head -c 65536)
  read -r w h < <(jq -r 'if type == "array" then
      (map(select((.width | type) == "number" and (.height | type) == "number")) | max_by(.width * .height) // {}
       | "\(.width // 0 | floor) \(.height // 0 | floor)") else "0 0" end' <<<"$out" 2>/dev/null)
  [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] && (( w >= 320 && w <= 7680 && h >= 200 && h <= 4320 )) || { w=2560; h=1440; }
  printf '%s %s' "$w" "$h"
}

resolve() {
  local path=$1 src=$2 name=${1##*/}
  local real s colors=/dev/null shell=/dev/null preview="" pkey="" bgs bgkeys="" bgvids="" b pal n
  real=$(realpath -e -- "$path" 2>/dev/null) || return 0
  ALLOWED_ROOTS=("$real" "$(realpath -e -- "$user_bgs/$name" 2>/dev/null || true)")
  s=$(sig "$path")

  # Each TOML is read once, through one descriptor, into this run's scratch;
  # every later use (omarchy-theme-color, jq) reads that snapshot.
  local csnap=$run/$name.colors.toml ssnap=$run/$name.shell.toml
  snapshot "$path/colors.toml" "$MAX_TOML_BYTES" "$csnap" "$real" && colors=$csnap
  snapshot "$path/shell.toml" "$MAX_TOML_BYTES" "$ssnap" "$real" && shell=$ssnap

  # Legacy alacritty-only theme: convert a snapshot in scratch, as theme-set does.
  if [[ $colors == /dev/null ]]; then
    local legacy=$run/$name.legacy; mkdir -p "$legacy"
    if snapshot "$path/alacritty.toml" "$MAX_TOML_BYTES" "$legacy/alacritty.toml" "$real"; then
      timeout 5s omarchy-theme-colors-from-alacritty "$legacy" >/dev/null 2>&1
      snapshot "$legacy/colors.toml" "$MAX_TOML_BYTES" "$csnap" && colors=$csnap
    fi
  fi

  preview=$(list_files "$path" 1 -iname 'preview.*' "${image_find[@]}")
  # Backgrounds: the user's per-theme dir first, then the theme's own, sorted — same order theme-set cycles.
  bgs=$( { list_files "$user_bgs/$name" "$MAX_BACKGROUNDS" "${image_find[@]}"
           list_files "$path/backgrounds" "$MAX_BACKGROUNDS" "${image_find[@]}"; } | head -n "$MAX_BACKGROUNDS" )
  [[ -n $preview ]] || preview=$(head -n1 <<<"$bgs")
  [[ -n $preview ]] && pkey=$(image_key "$preview")
  while IFS= read -r b; do [[ -n $b ]] && bgkeys+="$(image_key "$b")"$'\n'; done <<<"$bgs"

  # Animated backgrounds: a clip is an alternative rendering of the background
  # sharing its stem, so it is discovered per background rather than per theme.
  # Same two dirs and the same order, so a user clip shadows a theme's own.
  # One line per background, empty where there is no clip — position is the
  # pairing, which is why these are not filtered like $bgs is.
  local vids vkeys="" vk v bstem vstem
  vids=$( { LIST_BYTES=$MAX_VIDEO_BYTES list_files "$user_bgs/$name" "$MAX_BACKGROUNDS" "${video_find[@]}"
            LIST_BYTES=$MAX_VIDEO_BYTES list_files "$path/backgrounds" "$MAX_BACKGROUNDS" "${video_find[@]}"; } \
          | head -n "$MAX_BACKGROUNDS" )
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    bstem=${b##*/}; bstem=${bstem%.*}
    # First clip whose stem matches wins, preserving user-dir-first order.
    vk=$(while IFS= read -r v; do
           [[ -n $v ]] || continue
           vstem=${v##*/}; vstem=${vstem%.*}
           [[ $vstem == "$bstem" ]] && { printf '%s' "$v"; break; }
         done <<<"$vids")
    bgvids+="$vk"$'\n'
    if [[ -n $vk ]]; then vkeys+="$(image_key "$vk")"$'\n'; else vkeys+=$'\n'; fi
  done <<<"$bgs"

  # Palette via omarchy-theme-color, so legacy keys and aliases match what
  # theme-set produces: under a deadline, and a ceiling that refuses rather
  # than truncates. Values are shaped to hex colours before they reach QML.
  pal=$(timeout 5s omarchy-theme-color --file "$colors" --all 2>/dev/null | head -c $((MAX_PALETTE_BYTES + 1)))
  n=$(printf '%s' "$pal" | wc -c); (( n > MAX_PALETTE_BYTES )) && pal=""

  jq -n --arg name "$name" --arg src "$src" --arg path "$path" --arg sig "$s" \
    --arg preview "$preview" --arg previewKey "$pkey" --arg bgs "$bgs" --arg bgkeys "$bgkeys" \
    --arg bgvids "$bgvids" --arg vkeys "$vkeys" \
    --arg pal "$pal" --rawfile colors "$colors" --rawfile shell "$shell" '
    def hex: if type == "string" and test("^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$") then . else null end;
    ($pal | split("\n") | map(select(length > 0 and length <= 256) | split("\t") | select(length >= 2) | {(.[0]): .[1]}) | add // {}) as $c
    | { name: $name,
        label: ($name | split("-") | map((.[:1] | ascii_upcase) + .[1:]) | join(" ")),
        source: $src, path: $path, signature: $sig,
        mode: (if (($c.mode // "dark") | ascii_downcase) == "light" then "light" else "dark" end),
        colors: ($c | {background, foreground, accent, selection, muted, red, yellow, green, cyan, blue, magenta} | map_values(hex)),
        preview: $preview, previewKey: $previewKey,
        backgrounds: ($bgs | split("\n") | map(select(length > 0))),
        bgKeys: ($bgkeys | split("\n") | map(select(length > 0))),
        # Parallel to backgrounds, empty where a background does not move.
        # Trailing "" from the final newline is dropped, never the interior
        # blanks — those are the pairing.
        bgVideos: ($bgvids | split("\n") | .[:-1]),
        bgVideoKeys: ($vkeys | split("\n") | .[:-1]),
        colorsToml: $colors, shellToml: $shell }'
}

# 1. Walk. User dir first so it wins the name collision in step 3. A theme
#    entry may be a symlink (that is how themes get developed); its name must
#    be a plain slug.
for entry in "user:$user_themes" "stock:$stock_themes"; do
  src=${entry%%:*}; dir=${entry#*:}
  [[ -d $dir ]] || continue
  while IFS= read -r -d '' path; do
    name=${path##*/}
    valid_name "$name" && [[ -d $path ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$name" "$(sig "$path")" "$path" "$src"
  done < <(find -H "$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 2>/dev/null | head -z -n "$MAX_DIR_ENTRIES" | sort -z)
done | head -n "$MAX_THEMES" >"$rows"

# 2. Resolve only rows with no cached record for (name, signature), within
#    the time budget; whatever is left resolves on a later open.
partial=false
while IFS=$'\t' read -r path src; do
  [[ -n $path ]] || continue
  if (( SECONDS >= RESOLVE_BUDGET )); then partial=true; break; fi
  resolve "$path" "$src"
done < <(jq -r --rawfile rows "$rows" '
  ([.themes[]? | {key: "\(.name)\t\(.signature)", value: true}] | from_entries) as $have
  | $rows | split("\n") | map(select(length > 0) | split("\t")) | unique_by(.[0])
  | map(select($have["\(.[0])\t\(.[1])"] | not) | "\(.[2])\t\(.[3])") | .[]' <<<"$prev") >"$fresh"

# 3. Merge in walk order, flag shadowed names, add session state. The result
#    is held in memory, size-checked against the ceiling the readers apply,
#    then published through an exclusively created sibling and a rename.
current_theme=$(read_bounded "$state/theme.name" 256 2>/dev/null | tr -d '\n' || true)
current_bg=$(readlink -f -- "$state/background" 2>/dev/null || true)
read -r stage_w stage_h < <(stage_size)
json=$(jq -n --rawfile rows "$rows" --slurpfile prev <(printf '%s' "$prev") --slurpfile fresh "$fresh" \
      --arg thumbs "$thumbs" --argjson partial "$partial" --argjson stageW "$stage_w" --argjson stageH "$stage_h" \
      --arg currentTheme "$current_theme" --arg currentBackground "$current_bg" '
  (($prev[0].themes + $fresh) | map({key: "\(.name)\t\(.signature)", value: .}) | from_entries) as $rec
  | ($rows | split("\n") | map(select(length > 0) | split("\t"))) as $all
  | ($all | map(.[0]) | group_by(.) | map(select(length > 1) | .[0])) as $dupes
  | { version: 2,
      thumbsDir: $thumbs,
      stageW: $stageW, stageH: $stageH,
      partial: $partial,
      currentTheme: $currentTheme,
      currentBackground: $currentBackground,
      themes: ($all | unique_by(.[0])
        | map(. as $r | $rec["\($r[0])\t\($r[1])"] | select(. != null)
              | . + { shadowsStock: ($dupes | index($r[0]) != null) })) }')
n=$(printf '%s' "$json" | wc -c)
if [[ -z $json ]] || (( n > MAX_INDEX_BYTES )); then
  jq -n --arg thumbs "$thumbs" --argjson stageW "$stage_w" --argjson stageH "$stage_h" '{version: 2, thumbsDir: $thumbs, stageW: $stageW, stageH: $stageH, partial: false, currentTheme: "", currentBackground: "", themes: [], error: "index exceeds ceiling"}'
  exit 0
fi
if out=$(mktemp "$cache/index.XXXXXXXX"); then
  printf '%s\n' "$json" >"$out" && mv -f -- "$out" "$index" || rm -f -- "$out"
fi
printf '%s\n' "$json"
