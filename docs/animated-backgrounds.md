# Animated backgrounds

The attempt at commit `7f61216` (built on `fbe45f7`), in `main`'s own
history, is an older, different model. Do not revive it; this is what
replaced it and why.

## The model

A background may have an **animated alternative**: a video sharing its stem, at
any extension.

```
backgrounds/3-sunset-lake.webp   the background
backgrounds/3-sunset-lake.mp4    the same background, animated
```

One background, two renderings. The still is canonical — it is what the desktop
gets on apply, and what the filmstrip and every derivative are built from. The
video is what the *picker* shows while that background is selected.

That last point is the whole design: an animated background is a preview
affordance, not a boot sequence.

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

## Why this decouples us from Omarchy 4.1

"Boot intro" is a shell-owned concept — it concerns what happens when you land
or boot, so it has to wait for the shell to define playback. "Animated
alternative shown during preview" is entirely our own surface: it is what the
picker draws while scrubbing, which Swatch already owns outright.

CLAUDE.md used to gate this work on "after Omarchy 4.1 defines how the shell
plays them". That was a gate on the *intro* framing and does not bind this
model; nothing blocks it now, `qt6-multimedia` below having been settled
upstream.

The bet held. Omarchy has since defined shell playback both ways — looping video
wallpapers (#6792, merged) and per-boot intros (#9639, open) — and neither
touches this surface. Upstream's intro is keyed per background and paired by
stem, the same two choices made here, which is reassuring rather than
competitive: it plays once when you boot, this plays whenever you scrub. The two
can hold the same file and mean different things by it. What upstream's framing
does buy it is a cross-fade at the end, and that is the one place its clips and
ours diverge — see Direction below.

## qt6-multimedia is optional, and the isolation stays

`MediaPlayer` lives in `qt6-multimedia`. Quickshell does **not** pull it:

```
quickshell → qt6-base, qt6-declarative, qt6-svg, qt6-wayland
```

Omarchy did not declare it either when this was written, which was the whole
argument for isolating the import. **That changed**: native video wallpaper
support (upstream #6792, merged 2026-09-06) added `qt6-multimedia` and
`qt6-multimedia-ffmpeg` to `omarchy-base.packages` and back-filled existing
installs through migration `1786609204.sh`. On a current Omarchy the module is
guaranteed, and the shell's own `qs.Ui.BackgroundVideo` depends on it.

The isolation is still not optional, for two reasons that outlive the
dependency: an install that predates that migration still lacks the module, and
Swatch is a Quickshell plugin that nothing stops from being mounted outside
Omarchy. `import QtMultimedia` is a hard error at component load, so either case
would take the whole overlay down rather than degrade.

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

`sig()` is at `v8` for this shape; bump it whenever `resolve()`'s record
changes. It also stats both `intros/` dirs, or a clip added to the directory
clips now live in would not invalidate the record that omits it.

## Direction: which end holds the still

A clip meets its still at exactly one end, and which end is a property of the
footage, not a convention we pick. Across the 77 clips now installed every one
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

**An upstream clip is not guaranteed to have a seam at all.** Omarchy's boot
intros cross-fade into the still over their final 750 ms, so they are authored
without needing either end to be pixel-exact, and `solitude/1-on-pole` is one
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

No footage ships in this repo, and none will. The clips in the README and the
demo are [@yamzeight](https://x.com/yamzeight)'s work; crediting him is not the
same as being licensed to redistribute him, so you fetch your own copy. If you
use his footage anywhere public, credit him there too — it is the whole reason
the feature has anything to demonstrate.

**Upstream is now the place to fetch it from.** yamz8 has contributed 55
photographic intros (#9639) and 20 generated wordmark intros (#11906) to Omarchy
under its MIT license, as `themes/<theme>/intros/<background stem>.mp4` — the
same stem pairing this document describes, arrived at independently. Both were
still open drafts against `quattro` when this was written, so they are fetched
from the PR head rather than found on disk; if they merge, every Omarchy install
has a stem-matched clip for most stock backgrounds and the picker can animate
with no setup at all. That is a far better default than a scrape: these are the
authored edits at full length, where a scrape is typically truncated. It is not
uniformly higher quality, though — the packaged set is compressed to fit in the
repo, so a 1080p scrape can carry five times the bitrate of its 720p counterpart.
Measure both and keep the better file per clip.

The plugin has no opinion about where a clip came from. Any video you hold the
rights to becomes an animated background the moment it is named after a still
and dropped in the theme's `intros/` directory under
`~/.config/omarchy/backgrounds/`:

```sh
mkdir -p ~/.config/omarchy/backgrounds/retro-82/intros
ffmpeg -i your-clip.mp4 -c:v copy -an \
  ~/.config/omarchy/backgrounds/retro-82/intros/2-dusk-guardian.mp4
```

**`intros/`, not the background dir itself.** Since #6792 stock globs every
background dir for video as well as stills, so a clip sitting beside its still
becomes a second selectable wallpaper — `Super + Ctrl + Space` in a fully covered
theme cycles twice the entries it should, every other one a loop. A subdirectory
is invisible to those `-maxdepth 1` globs. A clip left in the old location still
works, and `index.sh` prefers `intros/` when both exist, so moving a collection is
just `mkdir intros && mv *.mp4 intros/` per theme.

**The stem is the pairing.** `2-dusk-guardian.mp4` attaches to the background
whose own file is `2-dusk-guardian.webp`, wherever that background lives — which
is why this directory and not the theme's: a stock theme is root-owned under
`/usr/share/omarchy`, and a user theme is often a git checkout whose upstream
would clobber anything you wrote inside it. Where a theme ships no still by that
name, put one in the theme's background dir — **not** in `intros/`, which exists
precisely to be invisible to the background globs — and it becomes a real,
selectable background with a clip attached.

Open the picker once afterwards and `thumbs.sh` transcodes what it finds, so the
shell's decoder only ever sees bytes our encoder wrote. It drops audio, metadata
and subtitles in the process; the `-an` above is only so the file you keep is as
small as the one we use.

## Test footage

yamz8's, local only, never committed — see `CLAUDE.md` for where it lives and
the credit rule.
