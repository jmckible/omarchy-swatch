# Swatch — working notes for agents

Omarchy shell plugin (Quickshell/QML + bash). Id `jmckible.swatch`, repo `jmckible/omarchy-swatch`, listed on omarchyplugins.com. The README is the user-facing contract; this file is the why behind the code.

## What matters

- **Everything in the preview looks like the theme.** The candidate's wallpaper fills the screen, the chrome is painted from its palette, and the real shell retints via `Color.loadColors` / `Color.loadShell` / `Style.scheduleRefresh` — the same calls `omarchy theme set` makes over `shell applyTheme` IPC. Preview is shell-only and reverted on cancel; nothing is written to disk until Enter runs the stock `omarchy-theme-set`.
- **Instant at any collection size.** `index.sh` is incremental (per-theme signature → record reused), cards paint from palette before any image decodes, the filmstrip is a recycled `ListView`, and at most five screen-size wallpapers are resident (`slots` in `Swatch.qml`). Don't add anything to the open path that scales with theme count.
- **Never edit user configuration.** Routing the hotkey is a line the user adds to `~/.config/omarchy/extensions/omarchy-menu.jsonc` themselves. The plugin writes only `~/.cache/omarchy/swatch/`.
- **No dependencies beyond Omarchy's own** (`jq`, `vipsthumbnail`, `omarchy-theme-color`). `qt6-imageformats` is needed only for webp wallpapers and is the shell's problem, not ours.

## Layout

- `Swatch.qml` — the overlay. Lifecycle contract with the shell: `open(payloadJson)`, `close()`, `opened` property. `shell`, `manifest`, `omarchyPath` are injected by the shell's Loader.
- `SwatchModel.js` — pure functions (`.pragma library`), tested by `node test/model.test.js`.
- `index.sh` → `~/.cache/omarchy/swatch/index.json`. `thumbs.sh` makes 640×360 filmstrip thumbs, idempotent, runs every open. `pick.sh` is the CLI round-trip (prints the chosen name; applies nothing).

## Dev loop

```sh
ln -sfn "$PWD" ~/.config/omarchy/plugins/jmckible.swatch   # once
omarchy restart shell        # after ANY QML edit — see below
./index.sh | jq '.themes | length'
node test/model.test.js
omarchy plugin validate .
```

- The shell's plugin hot-reload cannot load new QML: `Qt.clearComponentCache` is undefined in this engine, so "Local plugin changed, reloading" re-mounts the cached component. Only `omarchy restart shell` picks up QML changes. Scripts are read fresh on every open.
- Verify a build actually loaded with `omarchy-shell shell call jmckible.swatch <method> ''` — `ok` means the method exists on the mounted item; `unknown` means old code.
- Don't open the picker on the user's screen or inject keys without asking; ask them to drive and read the shell log instead: `journalctl --user --since '-60s' | grep -i swatch`.
- `qmllint -I ~/.local/share/omarchy/shell -I /usr/lib/qt6/qml Swatch.qml` catches syntax; import warnings for `qs.*` are expected.

## Index rules

- Bump the `echo vN` line in `sig()` whenever `resolve()`'s record shape changes; that is what invalidates cached records.
- User themes shadow stock themes of the same name (`shadowsStock`), the way `omarchy-theme-set` overlays them.
- Video convention: `backgrounds/foo.mp4` is a theme intro. A still with the same stem (`foo.png`) is its poster, recorded as `videoStill` and **excluded** from selectable backgrounds. Stock tooling globs only images, so both are invisible to it. This is a proposal ahead of Omarchy 4.1; expect it to change.
- Test footage for the video path is local only (`~/.config/omarchy/themes/solitude-video`, yamzeight's teaser clip). Never commit it; credit it wherever it appears in motion.

## Security posture (keep it)

An installed theme is untrusted input — anyone can `omarchy theme install` a hostile repo — and the marketplace review (issue #1933) holds us to that. The rules, all in `index.sh` / `thumbs.sh`:

- A theme *directory* may be a symlink (that's how themes get developed). Nothing inside one is followed: `find -H`, `-type f`, and `safe_file()` require a regular non-symlink file whose `realpath` stays under the theme dir or `~/.config/omarchy/backgrounds/<name>`.
- Ceilings before anything is retained: 512 themes, 200 backgrounds per theme, 512-byte paths, 64 KB TOML files, 256 MB videos, 8 MB cached index (and it must parse as `{themes: []}`). Theme names must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` — they become thumb filenames and `omarchy-theme-set` arguments.
- The whole index run sits under a 20 s `timeout`.
- Before an image reaches vips: regular file, ≤ 64 MB, `vipsheader` loader in `jpegload|pngload|webpload|gifload`, ≤ 50 MP. Each decode is single-threaded, `timeout 20s`, `ulimit -v 2 GB`, parallelism ≤ 4, ≤ 512 jobs per run, and may only write under our thumbs dir.
- In QML, every `Image` sets `sourceSize`, so decodes are bounded to the display; Qt's own allocation limit covers the rest. Only the selected theme's video is opened.

When touching these scripts, re-run the hostile-fixture check: a theme with `colors.toml → /etc/passwd`, a >64 KB `shell.toml`, a symlinked background, 230 backgrounds, a 60 MP PNG, and a theme named `bad name` must yield: defaults palette, empty shell, no symlink in the list, 200 backgrounds, no thumb for the bomb, and no record for the bad name.

## Shell APIs relied on

`Color.loadColors/loadShell`, `Style.scheduleRefresh`, `Style.space/font/fontFamily`, `Util.fileUrl/alpha/shellQuote/editsFilter/editedFilter`, `shell.bar.position/barSize` (leaves the real bar's band unpainted so the live retint is visible), `shell.hide(id)`. If `Color.loadColors` moves, the fallback is `Quickshell.execDetached(["omarchy-shell","shell","applyTheme", b64(colors), b64(shell)])`.

## Releasing

The marketplace card pulls name/version/author/description from `manifest.json` and `preview.png`; bump `version` there. README media: `docs/screenshots/*.webp` at exactly 1600×900 (region grabs come out a few px short — crop-normalize with `vipsthumbnail --size 1600x900 --smartcrop=centre`), `demo.gif` under 8 MB (800 px, 10 fps, 128 colors was 7.6 MB).
