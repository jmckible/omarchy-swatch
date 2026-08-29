# Swatch — working notes for agents

Omarchy shell plugin (Quickshell/QML + bash). Id `jmckible.swatch`, repo `jmckible/omarchy-swatch`, listed on omarchyplugins.com. The README is the user-facing contract; this file is the why behind the code.

## What matters

- **Everything in the preview looks like the theme.** The candidate's wallpaper fills the screen, the chrome is painted from its palette, and the real shell retints via `Color.loadColors` / `Color.loadShell` / `Style.scheduleRefresh` — the same calls `omarchy theme set` makes over `shell applyTheme` IPC. Preview is shell-only and reverted on cancel; nothing is written to disk until Enter runs the stock `omarchy-theme-set` (through `apply.sh`, argv only).
- **Instant at any collection size.** `index.sh` is incremental (per-theme signature → record reused, resolve loop stops at a 14 s budget and finishes next open), cards paint from palette before any image decodes, the filmstrip is a recycled `ListView`, and at most five screen-size wallpapers are resident (`slots` in `Swatch.qml`). Don't add anything to the open path that scales with theme count.
- **The shell never opens a theme file.** Every pixel the overlay shows is a derivative `thumbs.sh` produced in our cache (`stage-<key>-WxH.jpg` at the screen's size, `bg-<key>.jpg` for filmstrips); every byte `index.sh` parses came through `read_bounded`. See the security posture below — this is the whole reason for the design.
- **Never edit user configuration.** Routing the hotkey is a line the user adds to `~/.config/omarchy/extensions/omarchy-menu.jsonc` themselves. The plugin writes only `~/.cache/omarchy/swatch/`.
- **No dependencies beyond Omarchy's own** (`jq`, `vips`, `omarchy-theme-color`, `python3` — perl fallback — for the one syscall bash cannot make).

## Layout

- `Swatch.qml` — the overlay. Lifecycle contract with the shell: `open(payloadJson)`, `close()`, `opened` property. `shell`, `manifest`, `omarchyPath` are injected by the shell's Loader. `CacheImage` (inline component) is how every image is shown: a load that fails is retried on `cacheGen` ticks while `thumbs.sh` runs, declaratively, so bindings survive. Geometry goes through `root.sp()`/`root.fz.*`, frozen from `Style` at each `open()` — never `Style.space`/`Style.font` directly — so a candidate whose `shell.toml` sets `[spacing] scale` or font sizes re-lays out the real shell (faithful) but not the picker (see `freezeMetrics`).
- `SwatchModel.js` — pure functions (`.pragma library`), tested by `node test/model.test.js`. `keyAt`/`thumbPath`/`stagePath` map a selection to cache files.
- `lib.sh` — ceilings and `read_bounded`/`snapshot`, sourced by the scripts.
- `index.sh` → `~/.cache/omarchy/swatch/index.json` (`version: 2`, `thumbsDir`, `partial`, per-theme `previewKey`/`bgKeys`). `thumbs.sh` makes the derivatives, idempotent, runs every open, sweeps files whose key left the index. `apply.sh` is the only writer besides the cache: `apply.sh <theme> [bg]` applies, `apply.sh --pick <dir> [theme]` answers `pick.sh`, whose payload is `{dir}` (a `mktemp -d`; files are created noclobber). It sets the background **first** and then runs `omarchy-theme-set` under `OMARCHY_THEME_SKIP_BACKGROUND=1` — see the apply transition below.
- `test/hostile.sh` — the hostile-fixture check, isolated `HOME`. Run it after touching any script.

## Dev loop

```sh
ln -sfn "$PWD" ~/.config/omarchy/plugins/jmckible.swatch   # once
omarchy restart shell        # after ANY QML edit — see below
./index.sh | jq '.themes | length'
node test/model.test.js
bash test/hostile.sh
omarchy plugin validate .
```

- The shell's plugin hot-reload cannot load new QML: `Qt.clearComponentCache` is undefined in this engine, so "Local plugin changed, reloading" re-mounts the cached component. Only `omarchy restart shell` picks up QML changes. Scripts are read fresh on every open.
- Verify a build actually loaded with `omarchy-shell shell call jmckible.swatch <method> ''` — `ok` means the method exists on the mounted item; `unknown` means old code. `finishPick` exists only from 0.2.0.
- Don't open the picker on the user's screen or inject keys without asking; ask them to drive and read the shell log instead: `journalctl --user --since '-60s' | grep -i swatch`. During a cold cache expect `QML Image: Cannot open` lines — that is `CacheImage` retrying derivatives that don't exist yet.
- `qmllint -I ~/.local/share/omarchy/shell -I /usr/lib/qt6/qml Swatch.qml` catches syntax; import warnings for `qs.*` are expected.

## The apply transition

Enter is the one moment the preview has to become real without a seam, and stock leaves three ways for it to jar.

- **`omarchy-theme-set` picks its own background.** `choose_theme_background()` cycles to whatever follows the current link, so a theme applied with no background named lands on the wallpaper *after* the one the picker was showing — press Enter on the theme you are already using and your wallpaper advances by one. Naming the background afterwards is worse: `omarchy-theme-set` runs every retint hook and the selector cache warmup before it returns, so the second swap arrives seconds after the first. `apply.sh` sets the background first and passes `OMARCHY_THEME_SKIP_BACKGROUND=1`, so there is one swap and it is the previewed one. `Swatch.qml` therefore always names the background, never only when it differs from the first.
- **The current-background link points into the staged copy** (`~/.local/state/omarchy/current/theme/backgrounds/x.jpg`), not at the source file the index lists, so an exact path only matches a background set through `omarchy-theme-bg-set`. `Model.backgroundIndexOf` falls back to the file name, which the copy preserves — without it the picker opens on the theme's first wallpaper while the desktop shows its fourth. (We link to the source path, which the stock switchers never do; the cost is that the stock bg switcher won't preselect and the next stock `theme set` starts its cycle at the first background rather than advancing.)
- **The overlay used to vanish before the swap**, flashing the old desktop. It now dips through black. Chrome fades at `chromeOpacity`, then `dipDown` defocuses the stage (`MultiEffect` blur, live only while `applying`) into a full-screen `blackout` that covers the bar's band too; `liftUp` resolves it back out sharp and crossfades a cover that is by then identical to the desktop under it. Black is the point, not decoration: it is the one element that reads against a matching image, and *while it is up nothing can look wrong*, so the hold absorbs a late swap or a slow decode instead of us betting a constant on them. We lift on the landing signal — `readlink -f` saying the current-background link resolves to what we asked for, which `omarchy-theme-bg-set` writes before it asks the shell to swap — with `holdFloorMs` (140 ms) so the black registers as a beat, and `landDeadline` (3 s) to get out of the way regardless.
- **`setInstant` is load-bearing, not an optimisation.** Because we lift on the link rather than on a timer, the shell's own 420 ms reveal would still be mid-sweep when the cover comes off. `apply.sh` fires `background setInstant` before `omarchy-theme-bg-set`, whose own `background set` then early-returns on `finalPath === currentBackground`. Drop the `setInstant` line and the exit catches a half-finished barn-door wipe.
- **Scrubbing follows the axis you pressed.** Themes are a horizontal filmstrip, backgrounds a vertical one, so `move`/`jumpTo` record `scrubAxis = "theme"` and `moveBackground` records `"bg"`, and `startScrub` (on `shownKey`) gives the first a horizontal nudge plus `bladeEdge` — a bar of the candidate's accent crossing the wallpaper — and the second a quieter vertical nudge with no blade. A blade already in flight is left alone, so holding an arrow key thins the effect out instead of stacking it. `scrubArmed` swallows the first `shownKey` of an open, which is a landing, not a move.

## Index rules

- Bump the `echo vN` line in `sig()` whenever `resolve()`'s record shape changes; that is what invalidates cached records.
- User themes shadow stock themes of the same name (`shadowsStock`), the way `omarchy-theme-set` overlays them.
- An image's cache key is md5(path, size:mtime)[:16]; a replaced file gets new derivatives and the old ones are swept. The stage size is the largest connected monitor in physical pixels, from `hyprctl monitors -j` in `index.sh` (`stageW/H` in the index; Qt rounds `devicePixelRatio` under fractional scaling, so QML cannot know it — 3840×2160 @ 1.6 came out as 4800×2700). It is part of the filename, never upscaled (`WxH>`), and a size unused for 30 days expires.
- Video intros are not in this branch. The implementation (`backgrounds/foo.mp4` as intro, same-stem still as poster) is bookmarked on the `video` branch at `7f61216`; revive it only with a snapshot + `ffprobe` gate in front of `MediaPlayer`, after Omarchy 4.1 defines how the shell plays them. The test footage (`~/.config/omarchy/themes/solitude-video`, yamzeight's teaser) is local only; never commit it, credit it wherever it appears in motion.

## Security posture (keep it)

An installed theme is untrusted input — anyone can `omarchy theme install` a hostile repo — and the marketplace review (issue #1933) holds us to that with a fixed rubric: the long-lived shell must be unaffected by anything a same-user file swap can do. Arguing threat model gets nowhere; conform to the rubric and reply in its vocabulary (descriptor-bound, no-follow, overflow rejection, producer-side ceiling, exclusive create, deadline).

- **One trust decision, on a descriptor.** `read_bounded` (lib.sh) opens with `O_NOFOLLOW|O_NONBLOCK`, `fstat`s that descriptor (regular, ≤ cap, resolved under the theme dir when roots are given), reads through it with one-byte-past-the-ceiling rejection. Nothing checks a pathname and then opens the pathname again. No owner/mode check — stock themes are root-owned under `/usr/share/omarchy`, the un-swappable case.
- **Consumers read snapshots.** TOML → run-private scratch → `omarchy-theme-color` / `jq --rawfile`. Images → snapshot → `vipsheader` (loader allowlist, ≤ 50 MP) → `vipsthumbnail` on the same snapshot, single-threaded, `timeout`, `ulimit -v 2 GB`, ≤ 4 parallel, output checked (vips exits 0 on garbage). A refused source gets a `reject-<key>` marker so it isn't copied again every open. The QML only ever loads derivatives; the index paths it holds are for `omarchy-theme-bg-set` and matching, never for pixels.
- **Ceilings before retention, producer-side.** 512 themes, 200 backgrounds, 4096 readdir entries per dir, 64-byte names matching `^[A-Za-z0-9][A-Za-z0-9._-]*$`, 512-byte paths, 32 KB TOML, 16 KB palette, 64 MB images, 8 MB index (refused, not truncated, on both write and read). Every external producer has its own `timeout`; `index.sh` runs under 20 s, `thumbs.sh` under 600 s.
- **Writes.** Only under `~/.cache/omarchy/swatch/` and a `pick.sh` dir: `mktemp` siblings + `mv`, noclobber for the pick files and reject markers (exclusive create, never a truncating redirect to a predictable name). The thumbs.sh run lock is a read-only descriptor of the script's own file — nothing is created or truncated to take it. Palette values are shaped to `#rrggbb[aa]` in jq before they can reach a `<span style>`; theme names render `Text.PlainText`.

`bash test/hostile.sh` encodes all of this (symlinked/FIFO/oversize TOML, symlinked and out-of-tree backgrounds, 230 backgrounds, a 60 MP PNG, an SVG named `.png`, a 70 MB file, an invalid name, hostile colour values, a corrupt cache, stale cache files). Keep it green.

## Shell APIs relied on

`Color.loadColors/loadShell`, `Style.scheduleRefresh`, `Style.effectiveSpacingScale/font/fontFamily` (read once per open), `Util.fileUrl/alpha/editsFilter/editedFilter`, `shell.bar.position/barSize/transparent/barHidden` (leaves the real bar's band unpainted so the live retint is visible — but only while the bar paints its own background: a transparent bar is a hole onto the wallpaper being left, a hidden bar a hole onto nothing, so `barInset` drops the carve-out in both cases and the candidate's wallpaper runs edge to edge), `shell.hide(id)`. If `Color.loadColors` moves, the fallback is `Quickshell.execDetached(["omarchy-shell","shell","applyTheme", b64(colors), b64(shell)])`.

## Releasing

The marketplace card pulls name/version/author/description from `manifest.json` and `preview.png`; bump `version` there. README media: `docs/screenshots/*.webp` at exactly 1600×900 (region grabs come out a few px short — crop-normalize with `vipsthumbnail --size 1600x900 --smartcrop=centre`), `demo.gif` under 8 MB (800 px, 10 fps, 128 colors was 7.6 MB).
