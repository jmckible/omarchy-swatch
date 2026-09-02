#!/bin/bash
# Hostile-fixture check for index.sh and thumbs.sh, in an isolated HOME.
# Builds a theme collection an attacker might install and asserts what the
# index records, what the thumbnailer decodes, and what the cache keeps.
#   bash test/hostile.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf -- "$T"' EXIT
export HOME=$T/home XDG_CACHE_HOME=$T/cache XDG_RUNTIME_DIR=$T/run OMARCHY_PATH=$T/omarchy
mkdir -p "$HOME/.config/omarchy/themes" "$HOME/.config/omarchy/backgrounds" "$HOME/.local/state/omarchy/current" \
         "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$OMARCHY_PATH/themes"
U=$HOME/.config/omarchy/themes; S=$OMARCHY_PATH/themes
fail=0
check() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

mk() { mkdir -p "$1/backgrounds"; printf 'background = "#101010"\nforeground = "#e0e0e0"\naccent = "#ff8800"\nred = "#ff0000"\n' >"$1/colors.toml"; printf 'bar.position = "top"\n' >"$1/shell.toml"; }
png() { vips black "$1" "${2:-64}" "${3:-36}" 2>/dev/null; }
svg=$(find /usr/share/icons -name '*.svg' -print -quit 2>/dev/null)

mk "$U/good";        png "$U/good/backgrounds/a.png"; png "$U/good/backgrounds/b.png" 1920 1080; png "$U/good/preview.png" 320 180
mk "$S/good";        png "$S/good/backgrounds/stock.png"                  # shadowed by the user theme
mk "$S/stockonly";   png "$S/stockonly/backgrounds/s.png"
mk "$U/passwd";      ln -sfn /etc/passwd "$U/passwd/colors.toml"; png "$U/passwd/backgrounds/a.png"
mk "$U/insym";       ln -sfn ./shell.toml "$U/insym/colors.toml"          # symlink, even to something inside
mk "$U/bigshell";    head -c 40000 /dev/zero | tr '\0' 'x' >"$U/bigshell/shell.toml"
mk "$U/symbg";       png "$T/outside.png"; ln -s "$T/outside.png" "$U/symbg/backgrounds/link.png"; png "$U/symbg/backgrounds/real.png"
mk "$U/symdir";      rm -r "$U/symdir/backgrounds"; ln -s "$U/good/backgrounds" "$U/symdir/backgrounds"
mk "$U/many";        for i in $(seq -w 1 230); do png "$U/many/backgrounds/bg$i.png"; done
mk "$U/bomb";        png "$U/bomb/backgrounds/bomb.png" 8000 7500        # 60 MP
mk "$U/fakepng";     [[ -n $svg ]] && cp "$svg" "$U/fakepng/backgrounds/x.png"
mk "$U/oversize";    head -c 70000000 /dev/zero >"$U/oversize/backgrounds/huge.png"
mk "$U/fifo";        rm "$U/fifo/colors.toml"; mkfifo "$U/fifo/colors.toml"
mk "$U/bad name";    png "$U/bad name/backgrounds/a.png"
mk "$U/evilcolor";   printf 'background = "#101010"\naccent = "\\"><img src=x>"\nred = "nothex"\ngreen = "#12345"\n' >"$U/evilcolor/colors.toml"
# Animated backgrounds. A clip is paired to the background sharing its stem,
# so each fixture is a still plus something claiming to be its moving version.
HAVE_FFMPEG=0
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
  HAVE_FFMPEG=1
  clip() {  # clip DEST [SECONDS] — a real, small, valid mp4
    ffmpeg -nostdin -v error -y -f lavfi -i "testsrc=size=64x36:rate=${3:-6}" \
      -t "${2:-1}" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$1" 2>/dev/null
  }
  mk "$U/vidgood";   png "$U/vidgood/backgrounds/clip.png"; clip "$U/vidgood/backgrounds/clip.mp4"
  # A symlinked clip must be refused on the descriptor, exactly as an image is.
  mk "$U/vidsym";    png "$U/vidsym/backgrounds/clip.png"; clip "$T/outside.mp4"
                     ln -s "$T/outside.mp4" "$U/vidsym/backgrounds/clip.mp4"
  # Not a video at all, wearing the extension. ffprobe must refuse it and the
  # refusal must be remembered, not retried on every open.
  # (cp, not vips: vips picks its writer from the extension and cannot emit .mp4)
  mk "$U/vidfake";   png "$U/vidfake/backgrounds/clip.png"
                     cp "$U/vidfake/backgrounds/clip.png" "$U/vidfake/backgrounds/clip.mp4"
  # Past the byte ceiling: filtered in the inventory, before any decoder.
  mk "$U/vidhuge";   png "$U/vidhuge/backgrounds/clip.png"
                     truncate -s 200000000 "$U/vidhuge/backgrounds/clip.mp4"
  # Valid, but longer than a background has any business being.
  mk "$U/vidlong";   png "$U/vidlong/backgrounds/clip.png"; clip "$U/vidlong/backgrounds/clip.mp4" 130 1
  # A clip with no still to attach to is not a background and must not become one.
  mk "$U/vidnopair"; png "$U/vidnopair/backgrounds/still.png"; clip "$U/vidnopair/backgrounds/orphan.mp4"
fi

mkdir -p "$U/userbg/backgrounds" "$HOME/.config/omarchy/backgrounds/userbg"; printf 'background = "#000000"\n' >"$U/userbg/colors.toml"
png "$HOME/.config/omarchy/backgrounds/userbg/mine.png"; ln -s "$T/outside.png" "$HOME/.config/omarchy/backgrounds/userbg/link.png"
printf 'good\n' >"$HOME/.local/state/omarchy/current/theme.name"
mkdir -p "$XDG_CACHE_HOME/omarchy/swatch/thumbs"; : >"$XDG_CACHE_HOME/omarchy/swatch/thumbs/stale.jpg"; : >"$XDG_CACHE_HOME/omarchy/swatch/thumbs/bg-ffffffffffffffff.jpg"
printf 'not json' >"$XDG_CACHE_HOME/omarchy/swatch/index.json"   # a corrupt cache must be ignored, not fatal

echo "--- index.sh (cold)"
start=$SECONDS; idx=$("$here/index.sh"); rc=$?; cold=$((SECONDS - start))
check "exit status"                 "$rc" 0
check "finished under the deadline" "$(( cold < 20 ))" 1
q() { jq -r "$1" <<<"$idx"; }
t() { jq -r --arg n "$1" ".themes[] | select(.name == \$n) | $2" <<<"$idx"; }
check "version/thumbsDir"      "$(q '.version, (.thumbsDir | endswith("/omarchy/swatch/thumbs"))' | paste -sd,)" "2,true"
check "partial"                "$(q '.partial')" false
check "currentTheme"           "$(q '.currentTheme')" good
check "no record for bad name" "$(q '[.themes[].name] | index("bad name")')" null
check "good: backgrounds"      "$(t good '.backgrounds | length')" 2
check "good: keys"             "$(t good '(.bgKeys | map(test("^[0-9a-f]{16}$")) | all), (.previewKey | test("^[0-9a-f]{16}$"))' | paste -sd,)" "true,true"
check "good: palette"          "$(t good '.colors.accent, .colors.red, .mode' | paste -sd,)" "#ff8800,#ff0000,dark"
check "good: toml kept"        "$(t good '(.colorsToml | length > 0), (.shellToml | length > 0), .shadowsStock' | paste -sd,)" "true,true,true"
check "stockonly: source"      "$(t stockonly '.source, .shadowsStock' | paste -sd,)" "stock,false"
check "passwd: no colors"      "$(t passwd '.colorsToml, .colors.background' | paste -sd,)" ",null"
check "insym: symlink refused" "$(t insym '.colorsToml')" ""
check "bigshell: shell dropped" "$(t bigshell '.shellToml | length')" 0
check "symbg: link skipped"    "$(t symbg '.backgrounds | map(split("/")[-1]) | join(",")')" "real.png"
check "symdir: nothing"        "$(t symdir '.backgrounds | length')" 0
check "many: capped at 200"    "$(t many '.backgrounds | length')" 200
check "oversize: filtered"     "$(t oversize '.backgrounds | length')" 0
check "fifo: no hang, no colors" "$(t fifo '.colorsToml')" ""
check "evilcolor: shaped"      "$(t evilcolor '.colors.background, .colors.accent, .colors.red, .colors.green' | paste -sd,)" "#101010,null,null,null"
check "userbg: own dir, no link" "$(t userbg '.backgrounds | map(split("/")[-1]) | join(",")')" "mine.png"
check "colorsToml never exceeds cap" "$(q '[.themes[].colorsToml, .themes[].shellToml | length] | max <= 32768')" true
# Position is the pairing: a blank entry, never a short array.
check "bgVideos parallel to backgrounds" "$(q '[.themes[] | select((.bgVideos | length) != (.backgrounds | length))] | length')" 0
check "bgVideoKeys parallel too"         "$(q '[.themes[] | select((.bgVideoKeys | length) != (.backgrounds | length))] | length')" 0
check "no video listed as a background"  "$(q '[.themes[].backgrounds[] | select(test("\\.(mp4|webm|mkv)$"))] | length')" 0

if (( HAVE_FFMPEG )); then
  echo "--- animated backgrounds (index)"
  check "vidgood: paired by stem"   "$(t vidgood '[.backgrounds, .bgVideos] | transpose | map(select(.[1] != "") | (.[0] | split("/")[-1]) + "->" + (.[1] | split("/")[-1])) | join(",")')" "clip.png->clip.mp4"
  check "vidsym: symlink refused"   "$(t vidsym '.bgVideos | map(select(. != "")) | length')" 0
  check "vidhuge: over ceiling"     "$(t vidhuge '.bgVideos | map(select(. != "")) | length')" 0
  check "vidnopair: orphan ignored" "$(t vidnopair '.bgVideos | map(select(. != "")) | length')" 0
  check "vidnopair: still is still a background" "$(t vidnopair '.backgrounds | map(split("/")[-1]) | join(",")')" "still.png"
  # These two are listed — the refusal is the decoder's to make, not the inventory's.
  check "vidfake: listed for probing" "$(t vidfake '.bgVideos | map(select(. != "")) | length')" 1
  check "vidlong: listed for probing" "$(t vidlong '.bgVideos | map(select(. != "")) | length')" 1
fi

echo "--- index.sh (warm)"
start=$SECONDS; idx2=$("$here/index.sh"); warm=$((SECONDS - start))
check "warm run identical"     "$(jq -S . <<<"$idx" | md5sum)" "$(jq -S . <<<"$idx2" | md5sum)"
echo "     cold ${cold}s, warm ${warm}s"

echo "--- stage size from the compositor"
sz="$(q '.stageW'),$(q '.stageH')"
check "no compositor here → default" "$sz" "2560,1440"
mkdir -p "$T/bin"
fake() { printf '#!/bin/bash\n%s\n' "$1" >"$T/bin/hyprctl"; chmod +x "$T/bin/hyprctl"; }
fake "echo '[{\"width\": 99999999, \"height\": 1}, \"junk\"]'"
check "absurd monitor → default"   "$(PATH=$T/bin:$PATH "$here/index.sh" | jq -r '"\(.stageW),\(.stageH)"')" "2560,1440"
fake "echo '[{\"width\": 3840, \"height\": 2160, \"scale\": 1.6}, {\"width\": 1920, \"height\": 1200}]'"
check "largest monitor wins"       "$(PATH=$T/bin:$PATH "$here/index.sh" | jq -r '"\(.stageW),\(.stageH)"')" "3840,2160"
fake "head -c 200000 /dev/zero | tr '\\0' x"
check "oversized compositor output → default" "$(PATH=$T/bin:$PATH "$here/index.sh" | jq -r '"\(.stageW),\(.stageH)"')" "2560,1440"
fake "sleep 30"
start=$SECONDS; check "hung compositor → default under deadline" "$(PATH=$T/bin:$PATH "$here/index.sh" | jq -r '"\(.stageW),\(.stageH)"'),$(( SECONDS - start < 8 ))" "2560,1440,1"
rm -rf "$T/bin"; "$here/index.sh" >/dev/null   # back to the default size for the thumbs checks
sw=2560; sh=1440

echo "--- thumbs.sh"
start=$SECONDS; "$here/thumbs.sh"; rc=$?; echo "     ${SECONDS-start}s rc=$rc"
D=$XDG_CACHE_HOME/omarchy/swatch/thumbs
k=$(t good '.bgKeys[1]'); pk=$(t good '.previewKey')
check "good: stage + thumb"    "$(ls "$D/stage-$k-${sw}x${sh}.jpg" "$D/bg-$k.jpg" "$D/bg-$pk.jpg" 2>/dev/null | wc -l)" 3
check "good: 1920x1080 source stays 1920x1080 (shrink only)" "$(vipsheader "$D/stage-$k-${sw}x${sh}.jpg" | sed 's/.*: //')" "1920x1080 uchar, 1 band, b-w, jpegload"
: >"$D/stage-${pk}-1280x720.jpg"; touch -d '-40 days' "$D/stage-${pk}-1280x720.jpg"; : >"$D/stage-${pk}-1920x1080.jpg"
for n in bomb fakepng; do
  k=$(t $n '.bgKeys[0]'); [[ -n $k && $k != null ]] || { [[ $n == fakepng && -z $svg ]] && continue; }
  check "$n: rejected, nothing decoded" "$(ls "$D/stage-$k-${sw}x${sh}.jpg" "$D/bg-$k.jpg" 2>/dev/null | wc -l),$([[ -e $D/reject-$k ]] && echo marked)" "0,marked"
done
missing=$(for k in $(q '[.themes[] | .previewKey, .bgKeys[]] | unique[]'); do [[ -e $D/stage-$k-${sw}x${sh}.jpg || -e $D/reject-$k ]] || echo "$k"; done)
check "every key has a stage or a reject" "${missing:-none}" none
check "rejects are only bomb/fakepng (+2 video)" "$(ls "$D"/reject-* | wc -l)" "$(( HAVE_FFMPEG ? 4 : 2 ))"

if (( HAVE_FFMPEG )); then
  echo "--- animated backgrounds (thumbs)"
  gk=$(t vidgood '.bgVideoKeys | map(select(. != ""))[0]')
  check "vidgood: derivative produced" "$([[ -f $D/vid-$gk.mp4 ]] && echo yes)" yes
  # The shell must decode our encoder's bytes, not the theme's: a transcode,
  # not a copy, and silent whatever the source carried.
  check "vidgood: transcoded, not copied" "$(cmp -s "$D/vid-$gk.mp4" "$U/vidgood/backgrounds/clip.mp4" && echo copy || echo transcoded)" transcoded
  check "vidgood: no audio stream" "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 -- "$D/vid-$gk.mp4" 2>/dev/null | wc -l)" 0
  check "vidgood: decodes clean" "$(ffmpeg -v error -i "$D/vid-$gk.mp4" -f null - 2>/dev/null && echo ok)" ok
  for n in vidfake vidlong; do
    vk=$(t $n '.bgVideoKeys | map(select(. != ""))[0]')
    check "$n: refused, no derivative" "$(ls "$D/vid-$vk.mp4" 2>/dev/null | wc -l),$([[ -e $D/reject-$vk ]] && echo marked)" "0,marked"
  done
fi

check "sweep: stale files gone" "$(ls "$D/stale.jpg" "$D/bg-ffffffffffffffff.jpg" 2>/dev/null | wc -l)" 0
check "only our patterns remain" "$(ls "$D" | grep -vcE '^(bg-[0-9a-f]{16}\.jpg|vid-[0-9a-f]{16}\.mp4|stage-[0-9a-f]{16}-[0-9]+x[0-9]+\.jpg|reject-[0-9a-f]{16})$')" 0
check "snapshots cleaned up"   "$(ls "$XDG_RUNTIME_DIR" | wc -l)" 0
echo "--- thumbs.sh again (idempotent)"
start=$SECONDS; "$here/thumbs.sh"; echo "     ${SECONDS-start}s"
check "other size expired after 30 days, recent one kept" "$([[ -e $D/stage-${pk}-1280x720.jpg ]] && echo old),$([[ -e $D/stage-${pk}-1920x1080.jpg ]] && echo recent)" ",recent"

echo "--- planted links cannot redirect writes"
victim=$T/victim; printf 'precious' >"$victim"
ln -sfn "$victim" "$XDG_CACHE_HOME/omarchy/swatch/thumbs.lock"         # legacy lock path
head -c 100 /dev/urandom >"$U/good/backgrounds/notimage.png"           # will be refused by the header check
idx3=$("$here/index.sh")
nk=$(jq -r '.themes[] | select(.name == "good") | .backgrounds as $b | .bgKeys as $k | ($b | to_entries[] | select(.value | endswith("notimage.png")) | .key) as $i | $k[$i]' <<<"$idx3")
ln -sfn "$T/victim2" "$D/reject-$nk"                                   # dangling link at the predictable marker path
"$here/thumbs.sh"
check "victim not truncated through lock path"  "$(cat "$victim")" precious
check "dangling reject link not followed"       "$([[ -e $T/victim2 ]] && echo created)" ""
check "refused image produced no derivatives"   "$(ls "$D/stage-$nk"-*.jpg "$D/bg-$nk.jpg" 2>/dev/null | wc -l)" 0
rm -f "$U/good/backgrounds/notimage.png" "$D/reject-$nk"

echo "--- apply.sh --pick"
d=$(mktemp -d); "$here/apply.sh" --pick "$d" good; check "pick writes selection+done" "$(cat "$d/selection"),$([[ -e $d/done ]] && echo done)" "good,done"
d2=$(mktemp -d); "$here/apply.sh" --pick "$d2" ""; check "cancel writes done only" "$([[ -e $d2/selection ]] && echo sel),$([[ -e $d2/done ]] && echo done)" ",done"
d3=$(mktemp -d); "$here/apply.sh" --pick "$d3" 'bad name'; check "invalid name not written" "$([[ -e $d3/selection ]] && echo sel),$([[ -e $d3/done ]] && echo done)" ",done"
ln -s /etc/hostname "$d3/done2" 2>/dev/null; rm -rf "$d" "$d2" "$d3"

(( fail == 0 )) && echo "ALL OK" || { echo "FAILURES"; exit 1; }
