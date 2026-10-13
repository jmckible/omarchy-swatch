# Animated backgrounds

The attempt at commit `7f61216` (built on `fbe45f7`), in `main`'s own
history, is an older, different model. Do not revive it; this is what
replaced it and why.

## The model

A background may have an **intro**: a video sharing its stem, in an `intros/`
directory beside it.

```
backgrounds/3-sunset-lake.webp          the background
backgrounds/intros/3-sunset-lake.mp4    the same background, arriving
```

One background, two renderings. The still is canonical — it is what the desktop
rests on, and what the filmstrip and every derivative are built from. The video
is what the picker shows while that background is selected, and what Omarchy
plays on the desktop when you arrive on it.

This is upstream's layout and upstream's rule (#9639, below), adopted exactly
so that the picker never animates a background the desktop would not.

## Why not the intro model

That branch makes the video a property of the **theme** — one intro per theme,
played on arrival, handing off to a still that served as its poster. Three
mechanisms exist only to prop that framing up, and all three disappear here:

- `sort | head -n1` in `index.sh`, taking one video per theme. yamz8's footage
  already breaks this: tokyo-night has animated versions of two backgrounds
  (`3-sunset-lake`, `5-oma-cityscape`). Under the intro model that is a
  collision needing one clip parked. Here it is unremarkable.
- `videoStill`, the poster. Here the still *is* the background, so there is
  nothing to name separately.
- The `grep -vxF` that drops the poster from the selectable backgrounds, so it
  cannot double as a wallpaper. Here it is *supposed* to be selectable, so
  nothing is hidden.

`videoStillIndex` in `SwatchModel.js` also goes. It is dead on arrival on that
branch regardless — it does `backgrounds.indexOf(videoStill)` against the list
the still was just removed from, so it always returns `-1`.

The handoff goes too. No `videoTheme` replay-suppression state, no `EndOfMedia`
fade into the still. The scrub wipes stay exactly as built; only what the stage
renders changes. Apply-time motion→still is already covered by the exit through
black.

## Upstream intros (#9639)

The bet this document used to describe — that a per-background clip was ours to
define before Omarchy decided how the shell plays one — is settled. #9639 merged
on 2026-10-07 and ships intros in `themes/<theme>/backgrounds/intros/`; the
dev channel has trimmed that to at most one per theme (`32481c89`) without
changing the shape. Playback is not the shell's at all: **OWE** (`owe`, a
separate daemon) owns every video on the desktop, and the shell draws stills
only — `qs.Ui.BackgroundVideo` is gone and the shell no longer imports
QtMultimedia.

`omarchy-theme-bg-boot-intro --resolve-only <still>` is the resolver, and
`index.sh` reproduces it rather than approximating it:

- `<the still's own dir>/intros/<stem>.<ext>`, extensions tried in the order
  `mp4 m4v mov webm mkv avi`, matched case-sensitively. We stop before `avi`: a
  decoder we decline to reach for a container nobody ships.
- Only `jpg jpeg png bmp webp` stills resolve; a `gif` gets no intro.
- *Its own dir.* A stock still never reaches a clip under
  `~/.config/omarchy/backgrounds/<theme>/intros/`, and a still there never
  inherits a theme's clip by sharing its stem. This retired the old
  four-directory search (user `intros/` first, then the theme's, then clips
  beside stills) which existed to attach clips to root-owned stock themes —
  something that, under upstream's rule, only ever animated the preview.

It plays at login and on a theme switch to a *different* theme, unless
`~/.local/state/omarchy/toggles/background-intros-off` exists or Hyprland's
animations are off. Cycling backgrounds within a theme never plays one.

### Enter hands the switch to stock

`apply.sh` normally sets the background first and runs `omarchy-theme-set`
under `OMARCHY_THEME_SKIP_BACKGROUND=1` — one swap, the previewed one (see
CLAUDE.md, Transitions). That variable also skips the whole intro: theme-set
resolves, prepares and plays an intro only inside its own background path. So
when an intro *would* play — same four checks as theme-set, its own resolver
for the clip — `apply.sh` does not set the background. It pins it instead,
through the per-theme memory `choose_theme_background()` reads for a theme
being switched *to* (`~/.local/state/omarchy/theme-backgrounds/<theme>`), and
lets theme-set run unmodified. That memory only decides for a different theme;
for the same one it cycles from the current link — which is fine, since no
intro plays then either.

On the way out the overlay cannot lift on the link any more. theme-set calls
`prepareThemeIntro`, which holds a cover of the *outgoing* wallpaper, sets the
link, starts OWE on the clip's first frame, and only once the clip is advancing
fades that cover over 420 ms. Lifting on the link would uncover the old
wallpaper. So `land.sh` also asks `omarchy-shell shell themeIntroStatus
<token>` — the probe theme-set itself polls, the token being the staged theme
dir's `%d:%i`, asked of `next-theme` and `current/theme` because `mv` keeps the
inode across the swap — and while it answers `pending` the black holds (8 s
ceiling; the shell's own fallback is 10 s). Then the stage is dropped and the
black lifts straight onto the playing clip; our still is the clip's *last*
frame, so crossfading it over a clip that has just started would be the seam.

Plugins get a scoped `shell` facade, not the shell root, so `shell.bootIntro`
is not reachable from here; the IPC is the contract.

### The memory theme-set files under the wrong theme

`remember_current_theme_background()` records the outgoing theme's wallpaper
from the current link before anything else. Setting the background first has
already moved that link, so every cross-theme apply through Swatch used to file
the *incoming* theme's wallpaper under the *outgoing* one, and the next stock
switch back landed on it. The skip path now puts back what the outgoing theme
was showing after theme-set returns. The intro path never moves the link early
and needs no repair.

## qt6-multimedia is optional, and the isolation stays

`MediaPlayer` lives in `qt6-multimedia`. Quickshell does **not** pull it:

```
quickshell → qt6-base, qt6-declarative, qt6-svg, qt6-wayland
```

Omarchy has declared it in `omarchy-base.packages` since #6792 and back-filled
existing installs through migration `1786609204.sh` — but its own shell no
longer uses it: OWE plays desktop video, and the shell draws stills only.
That makes Swatch the module's one consumer in the shell process, which is all
the more reason not to assume it.

The isolation is not optional: an install that predates that migration lacks
the module, a future one may stop declaring it now that nothing in the shell
needs it, and Swatch is a Quickshell plugin that nothing stops from being
mounted outside Omarchy. `import QtMultimedia` is a hard error at component
load, so any of those would take the whole overlay down rather than degrade.

Hence `VideoStage.qml`. It is the only file that imports QtMultimedia, and
`Swatch.qml` reaches it through a `Loader`. A missing module lands that Loader
in `Loader.Error` with a null `item`; every guard that reads `item` is then
false and the picker shows stills. **Nothing else may import QtMultimedia** —
doing so moves the failure back out into the overlay.

ffprobe, by contrast, is free:

```
qt6-multimedia → qt6-multimedia-ffmpeg → ffmpeg
```

Playback cannot exist without ffmpeg installed, so the snapshot + probe gate
costs no dependency beyond the one playback already forces. `thumbs.sh` still
checks for both binaries and skips the clip rather than assuming.

## Security posture still applies

Unchanged, and it is the reason the gate is not optional: the shell never opens
a theme file. A video is untrusted input exactly like an image, so it needs a
`read_bounded` snapshot and its own ceiling before anything decodes it, an
`ffprobe` check on that snapshot (container, codec, dimensions, duration) before
it reaches `MediaPlayer`, and a `reject-<key>` marker when refused so it is not
re-copied every open.

The cache holds a **transcode, not a validated copy**. This is the one decision
worth not reopening: a copy would still hand the shell's long-lived decoder
attacker-shaped bytes, and ffprobe agreeing that a file looks like H.264 is not
the same as the file being safe to decode. Re-encoding means the bytes the
shell decodes were written by our encoder, which is exactly the guarantee the
JPEG path already gives. The probe only decides *whether to transcode*.

Audio, subtitles, data streams and metadata are dropped at that transcode. A
theme picker that makes noise is a bug, and every stream not carried is a
decoder never reached.

The transcode runs after every still, so a clip can never delay a wallpaper,
and the 600 s budget still holds: eleven 720p clips take about 2 s wall.

## Index shape

Per-background rather than per-theme. The parallel-array style already used for
`bgKeys` extends directly:

```
backgrounds: [ ".../3-sunset-lake.webp", ".../5-oma-cityscape.jpg", ... ]
bgKeys:      [ "a1b2…",                  "c3d4…",                  ... ]
bgVideos:    [ ".../3-sunset-lake.mp4",  ".../5-oma-cityscape.mp4", ... ]
```

Empty string where a background has no animated alternative. Nothing is removed
from `backgrounds`, which is the point — and position *is* the pairing, so a
still-only background must leave a blank rather than being skipped. Skipping
would slide every later clip onto the wrong wallpaper. `videoKeyAt` and the
hostile suite both pin this.

`sig()` is at `v9` (the move to upstream's resolution rule); bump it whenever
`resolve()`'s record changes. It also stats both `intros/` dirs —
`<theme>/backgrounds/intros` and `~/.config/omarchy/backgrounds/<theme>/intros`
— or a clip added there would not invalidate the record that omits it.

## Direction: which end holds the still

A clip meets its still at exactly one end, and which end is a property of the
footage, not a convention we pick. Upstream now writes the convention down —
an intro "opens on its scene setup and ends on the matching still" — so every
clip it ships is meant to be ARRIVE. The measurements below were taken on a
personal 77-clip set (2026-09-15) that is no longer installed; the method is
what carries over. Across those 77 clips every one
lands under 8, and the set is overwhelmingly ARRIVE — 73 of 77, from
`last-horizon/omarchy` at 0.00 to `retro-82/1-in-the-groove` at 5.84. The four
exceptions are worth knowing by name:

- **DEPART** — the still is frame 0; the clip moves away from it.
  `osaka-jade/2-shaded-entrance` (1.62), `ristretto/2-coffee-beans` (2.33),
  `solitude/BG1` (3.25), `nord/1-city-view` (6.76).

Scores are mean absolute difference of 64×36 greyscale signatures; a true match
is under about 8, and the other end of the same clip scores 16–55.

**Crop the still to the clip's aspect before comparing, or the measurement
lies.** Stills run from 1.34 (`gruvbox/3-village-square`) to 3.03
(`retro-82/5-zen-boat`) while every clip is 16:9. Scaling both to 64×36 without
cropping squashes them by different factors, the content stops lining up, and the
score becomes noise: measured that way `solitude/BG1` read 34.81/47.09 — no match
at either end — and `3-village-square` read 18.02, when both in fact match at
3.25 and 2.51. Centre-crop the still to 16:9 first, which is what
`PreserveAspectCrop` does to it on screen anyway, and the numbers reproduce the
values filed here. Both times this bit, it inverted a direction rather than
merely blurring it.

Measure **both ends against every wallpaper the theme ships**, not the end
against a bundled still. `solitude/90-storm` was filed as ARRIVE onto a still
of its own only because its last frame was compared to the poster that shipped
with it; its first frame is `BG1` at 3.40, so it is DEPART from a wallpaper
solitude already had, and the extra background was never needed. Only
`last-horizon/omarchy` genuinely lands somewhere no theme ships — its best
shipped match is 16.57, comfortably outside the threshold.

**An upstream clip is not guaranteed to have a seam at all.** The draft-era
intros cross-faded into the still over their final 750 ms, so they were authored
without needing either end to be pixel-exact (since merging, OWE owns the hand
back to the still and upstream has been re-cutting clips to land exactly —
"Land the Kanagawa intro exactly on its wallpaper", `81504b08`). `solitude/1-on-pole` was one
that isn't: 45.61 first, 33.19 last, against a still its own theme ships. Swatch
has no cross-fade to hide that with by design (below), so measure an upstream
clip before adopting it rather than trusting that it was paired carefully — 74 of
the 75 offered do land, which is exactly what makes the one that doesn't easy to
miss.

This is the whole transition question. The seam is at the *opposite* end from
the still: a DEPART clip starts pixel-identical to what is already on screen and
jumps at its end; an ARRIVE clip jumps at its start and ends pixel-identical.

So **no cross-fade is wanted at either seam.** At the matching end it would be a
no-op — the two images are the same frame (`last-horizon` scores literally
0.00). At the jumping end it dissolves two genuinely different views of one
scene, which ghosts any moving subject; that is the same reason the scrub
transition is a masked wipe and not a dissolve.

The seams are also already covered. Scrubbing onto a background reveals the
incoming content through the wipe, which masks a clip's start exactly as it
masks a still's; leaving on apply goes through the blackout. Both existing
mechanisms sit precisely where the jumps are, so playing a clip needs no new
transition — only a decision about when it starts.

Reversing an ARRIVE clip turns it into a DEPART clip, which would make every
clip start seamlessly. Whether that is usable is content-dependent: a camera
push reversed is a pull and reads fine, but `last-horizon`'s wordmark would
un-assemble.

## The binding-order trap

Three separate bugs while wiring this up were all one mistake, so it is worth
naming: **inside a change handler, a property derived from the thing that
changed still holds its previous value.** The raw property is current; bindings
that depend on it have not re-evaluated yet.

It is nasty because it inverts behaviour rather than breaking it. `disarmVideo`
read `videoAvailable` — derived from `selectedVideoKey` — from inside
`onSelectedVideoKeyChanged`. Landing on a background *with* a clip read the
stale `false` and never armed; leaving one read the stale `true` and armed a
timer that fired against an empty key. Exactly backwards, and silent.

The same shape hid one level down in `VideoStage`. `player.source` is bound to
`active`, so `play()` from `onActiveChanged` ran against the old empty source
and did nothing; the clip then sat loaded on frame 0. For a DEPART clip frame 0
*is* its still, so the symptom was a picture identical to the working one — the
feature looked simply absent. `maybePlay()` is called from both sides and acts
whenever the last of them arrives.

The rule: in a handler, read raw properties, or move the decision into a
binding or a timer that evaluates later. Both fixes here do the latter.

## When a clip starts

On a dwell, not on landing: scrubbing lands a background every ~160 ms, and
starting a decode on each would thrash for nothing anyone could see. `Timer`
`videoDwell` (420 ms) arms it, every move disarms it, and `applying` kills it —
a clip still running under the exit defocus would be motion inside the blur.

It plays once and holds on its final frame rather than looping. 73 of the 77
clips are ARRIVE, so their final frame *is* the still: holding there is already
the right resting state, and the hand-off back is a no-op. A loop would jump-cut
the rest every time it wrapped.

The looping question is now narrow rather than open. 26 of the 77 match the
still at **both** ends, which makes them loop-safe for free — 19 of the 20
wordmarks, generated to return to where they started (`hackerman` is the one
that misses, at 9.40), plus seven filmed clips
(`osaka-jade/2-shaded-entrance`, `retro-82/7-the-journey`,
`lupine/04-elegant-blue-wave`, `matte-black/2-dot-hands`, `vantablack/0-dot-hands`,
`catppuccin/3-blue-eye`, `last-horizon/2-blink`). Only three clips genuinely have
nowhere to rest: `ristretto/2-coffee-beans`, `solitude/BG1` and
`nord/1-city-view` — DEPART clips whose last frame matches nothing. Any looping
decision is about those three, and a per-clip both-ends test decides it, so it
does not need a policy.

## Getting clips

**Omarchy ships them.** Since #9639 most stock themes carry an intro for one of
their backgrounds, and the picker animates those with no setup at all — the
footage is [@yamzeight](https://x.com/yamzeight)'s, contributed under Omarchy's
MIT license; if you show it anywhere public, credit him there. No footage ships
in *this* repo, and none will.

For your own, the still and the clip go together, because an intro belongs to
the directory its still is in:

```sh
mkdir -p ~/.config/omarchy/backgrounds/retro-82/intros
cp dusk.webp ~/.config/omarchy/backgrounds/retro-82/2-dusk-guardian.webp
ffmpeg -i your-clip.mp4 -c:v copy -an \
  ~/.config/omarchy/backgrounds/retro-82/intros/2-dusk-guardian.mp4
```

That still is a real, selectable background in the stock rotation, and both
Swatch and the desktop play its intro. A clip there named after a *stock* still
attaches to nothing: upstream resolves `intros/` beside the still, never across
directories, and Swatch follows it rather than animate a preview the desktop
will not match.

**`intros/`, not the background dir itself.** Stock globs every background dir
for video as well as stills (#6792), so a clip sitting beside its still is a
standalone looping wallpaper in the rotation, not an intro — Swatch does not
read it as one. A subdirectory is invisible to those `-maxdepth 1` globs.
Upstream's *user* intro path that nests a directory per background SHA-256
(`intros/<hash>/`) is ignored rather than tripped on.

Open the picker once afterwards and `thumbs.sh` transcodes what it finds, so the
shell's decoder only ever sees bytes our encoder wrote. It drops audio, metadata
and subtitles in the process; the `-an` above is only so the file you keep is as
small as the one we use. OWE plays your original file on the desktop; what it
does with untrusted bytes is upstream's posture, not ours.

## Test footage

yamz8's, local only, never committed — see `CLAUDE.md` for where it lives and
the credit rule.
