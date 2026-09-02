# Animated backgrounds

The attempt on `origin/video` (`7f61216`, built on `fbe45f7`) is an older,
different model. Do not revive it; this is what replaced it and why.

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
model; what remains blocking is `qt6-multimedia` below, which is ours to
resolve rather than the shell's.

## qt6-multimedia is optional, by construction

`MediaPlayer` lives in `qt6-multimedia`. Quickshell does **not** pull it:

```
quickshell → qt6-base, qt6-declarative, qt6-svg, qt6-wayland
```

Nor does `omarchy` declare it. Where it is present it arrived via something
unrelated (mpv, kdenlive), so it cannot be assumed — and `import QtMultimedia`
is a hard error at component load, which would take the whole overlay down on a
machine without it.

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
and the 600 s budget still holds: eight 720p clips take about 1.5 s wall.

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

`sig()` is at `v7` for this shape; bump it whenever `resolve()`'s record
changes.

## Direction: which end holds the still

A clip meets its still at exactly one end, and which end is a property of the
footage, not a convention we pick. Measured against yamz8's seven:

- **DEPART** — the still is frame 0; the clip moves away from it.
  `gruvbox/1-the-backwater` (3.58), `gruvbox/3-village-square` (2.58),
  `nord/1-city-view` (7.19).
- **ARRIVE** — the still is the final frame; the clip lands on it.
  `last-horizon/omarchy` (0.00), `tokyo-night/5-oma-cityscape` (3.63),
  `retro-82/2-dusk-guardian` (4.88), `tokyo-night/3-sunset-lake` (5.42).

Scores are mean absolute difference of 64×36 signatures; a true match is under
about 8, and the other end of the same clip scores 16–55. Detect it by comparing
both ends to the still rather than assuming — assuming the last frame is what
produced a wrong reading of `3-village-square` once already.

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

It plays once and holds on its final frame rather than looping. Four of the
eight clips are ARRIVE, so their final frame *is* the still: holding there is
already the right resting state, and the hand-off back is a no-op. A loop would
jump-cut exactly those four every time it wrapped.

Still open: whether DEPART clips should loop instead, since they end away from
their still and so have nowhere natural to rest.

## Test footage

yamz8's, local only, never committed — see `CLAUDE.md` for where it lives and
the credit rule.
