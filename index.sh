#!/bin/bash
# Emit the theme index as JSON on stdout. One record per installed theme;
# a record is carried over from the cached index when its signature is
# unchanged, so a warm run is a find, a stat loop, and two jq calls. Only
# themes whose files changed pay for omarchy-theme-color.
set -uo pipefail

cache=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/swatch
thumbs=$cache/thumbs
index=$cache/index.json
user_themes=$HOME/.config/omarchy/themes
stock_themes=${OMARCHY_PATH:-$HOME/.local/share/omarchy}/themes
state=$HOME/.local/state/omarchy/current
mkdir -p "$thumbs"

prev=$( [[ -f $index ]] && cat "$index" || echo '{"themes":[]}' )
[[ $prev == \{* ]] || prev='{"themes":[]}'

image_find=(-type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \))
video_find=(-type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' \))

sig() {
  local d=$1 f
  {
    echo v2   # record schema version: bump when resolve() output changes
    stat -Lc '%Y' "$d"
    [[ -d $d/backgrounds ]] && stat -Lc 'bg:%Y' "$d/backgrounds"
    [[ -d $HOME/.config/omarchy/backgrounds/${d##*/} ]] && stat -Lc 'ubg:%Y' "$HOME/.config/omarchy/backgrounds/${d##*/}"
    for f in colors.toml shell.toml alacritty.toml preview.png preview.jpg preview.jpeg preview.webp; do
      [[ -e $d/$f ]] && stat -Lc "$f:%s:%Y" "$d/$f"
    done
  } 2>/dev/null | paste -sd,
}

resolve() {
  local path=$1 src=$2 name=${1##*/}
  local colors=$path/colors.toml shell=/dev/null preview="" video="" s key tmp=""
  s=$(sig "$path")
  key=$(printf '%s' "$s" | md5sum | cut -c1-12)
  [[ -f $path/shell.toml ]] && shell=$path/shell.toml

  # Legacy alacritty-only theme: convert into scratch, the way theme-set does.
  if [[ ! -f $colors && -f $path/alacritty.toml ]]; then
    tmp=$(mktemp -d)
    cp "$path/alacritty.toml" "$tmp/"
    omarchy-theme-colors-from-alacritty "$tmp" >/dev/null 2>&1
    colors=$tmp/colors.toml
  fi
  [[ -f $colors ]] || colors=/dev/null

  preview=$(find -L "$path" -maxdepth 1 -iname 'preview.*' "${image_find[@]}" -print -quit 2>/dev/null)
  # Backgrounds: the user's per-theme dir first, then the theme's own, sorted — same order theme-set cycles.
  local bgs
  bgs=$( { find -L "$HOME/.config/omarchy/backgrounds/$name" -maxdepth 1 "${image_find[@]}" -print 2>/dev/null
           find -L "$path/backgrounds" -maxdepth 1 "${image_find[@]}" -print 2>/dev/null; } | sort )
  [[ -n $preview ]] || preview=$(head -n1 <<<"$bgs")
  # One filmstrip thumb per background, keyed by path + stat so a replaced
  # file gets a new thumb. Cold path only; the record caches the names.
  local bgthumbs="" b
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    bgthumbs+="$thumbs/bg-$(printf '%s\t%s' "$b" "$(stat -Lc '%s:%Y' "$b" 2>/dev/null)" | md5sum | cut -c1-16).jpg"$'\n'
  done <<<"$bgs"
  video=$( { find -L "$HOME/.config/omarchy/backgrounds/$name" -maxdepth 1 "${video_find[@]}" -print 2>/dev/null
             find -L "$path/backgrounds" -maxdepth 1 "${video_find[@]}" -print 2>/dev/null; } | sort | head -n1 )

  omarchy-theme-color --file "$colors" --all 2>/dev/null | jq -Rs \
    --arg name "$name" --arg src "$src" --arg path "$path" --arg sig "$s" \
    --arg preview "$preview" --arg video "$video" \
    --arg thumb "$( [[ -n $preview ]] && printf '%s/%s-%s.jpg' "$thumbs" "$name" "$key" )" \
    --arg bgs "$bgs" --arg bgthumbs "$bgthumbs" \
    --rawfile colors "$colors" --rawfile shell "$shell" '
    (split("\n") | map(select(length > 0) | split("\t") | select(length >= 2) | {(.[0]): .[1]}) | add // {}) as $c
    | { name: $name,
        label: ($name | split("-") | map((.[:1] | ascii_upcase) + .[1:]) | join(" ")),
        source: $src, path: $path, signature: $sig,
        mode: (($c.mode // "dark") | ascii_downcase),
        colors: ($c | {background, foreground, accent, selection, muted, red, yellow, green, cyan, blue, magenta}),
        preview: $preview, thumb: $thumb, video: $video,
        backgrounds: ($bgs | split("\n") | map(select(length > 0))),
        bgThumbs: ($bgthumbs | split("\n") | map(select(length > 0))),
        colorsToml: $colors, shellToml: $shell }'
  [[ -n $tmp ]] && rm -rf "$tmp"
}

# 1. Walk. User dir first so it wins the name collision in step 3.
rows=$(mktemp); fresh=$(mktemp); trap 'rm -f "$rows" "$fresh"' EXIT
for entry in "user:$user_themes" "stock:$stock_themes"; do
  src=${entry%%:*}; dir=${entry#*:}
  [[ -d $dir ]] || continue
  while IFS= read -r -d '' path; do
    printf '%s\t%s\t%s\t%s\n' "${path##*/}" "$(sig "$path")" "$path" "$src"
  done < <(find -L "$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 2>/dev/null | sort -z)
done >"$rows"

# 2. Resolve only rows with no cached record for (name, signature).
jq -r --rawfile rows "$rows" '
  ([.themes[]? | {key: "\(.name)\t\(.signature)", value: true}] | from_entries) as $have
  | $rows | split("\n") | map(select(length > 0) | split("\t")) | unique_by(.[0])
  | map(select($have["\(.[0])\t\(.[1])"] | not) | "\(.[2])\t\(.[3])") | .[]' <<<"$prev" |
while IFS=$'\t' read -r path src; do
  [[ -n $path ]] && resolve "$path" "$src"
done >"$fresh"

# 3. Merge in walk order, flag shadowed names, add session state, publish atomically.
current_theme=$(cat "$state/theme.name" 2>/dev/null || true)
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
