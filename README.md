# Swatch

A theme picker for [Omarchy](https://omarchy.org) that tries the theme on.

The candidate's wallpaper fills the screen. The shell — bar, menus, notifications, the picker itself — retints to its palette as you scrub. When a theme ships a video background, it plays. The only chrome that isn't the theme is a filmstrip under a fixed playhead.

Built to stay instant at any collection size: an incremental index of every `colors.toml`, cards painted from the palette before any image decodes, a recycled filmstrip, and at most five screen-size wallpapers resident at once.

Plugin id `jmckible.swatch`. MIT. Not affiliated with Omarchy or 37signals.

<p align="center"><img src="docs/screenshots/demo.gif" alt="Scrubbing through themes full-screen, then a theme's video intro playing and settling into its wallpaper" width="900"></p>
<p align="center"><sub>Theme intro in the demo: <a href="https://x.com/yamzeight/status/2089340897326469186">Omarchy 4.1 video-background teaser by @yamzeight</a> — local test footage, not included in this repo.</sub></p>

| Preview | Backgrounds | Filter |
|---|---|---|
| [![Swatch previewing Tokyo Night full-screen](docs/screenshots/hero.webp)](docs/screenshots/hero.webp) | [![A theme's backgrounds as a vertical filmstrip](docs/screenshots/backgrounds.webp)](docs/screenshots/backgrounds.webp) | [![Dark filter chip active with the strip narrowed](docs/screenshots/filter.webp)](docs/screenshots/filter.webp) |

## Install

```sh
omarchy plugin add https://github.com/jmckible/omarchy-swatch.git --enable
```

Then route the theme hotkey (`Super+Shift+Ctrl+Space`) and _Style > Theme_ to Swatch by adding to `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"style.theme": {"action": "omarchy-shell shell toggle jmckible.swatch"}
```

Remove that line to get the stock picker back. Swatch never edits your config.

Requires `jq` and `vipsthumbnail` (both ship with Omarchy). For webp backgrounds the shell needs `qt6-imageformats`.

## Keys

| Key | Action |
|---|---|
| `←` `→` | Previous / next theme |
| `↑` `↓` | Cycle the theme's backgrounds |
| `PgUp` `PgDn` `Home` `End` | Jump |
| type | Filter by name |
| `Tab` | Cycle the filter chips: All → Dark → Light → Installed → Stock (or click one) |
| `Enter` / double-click | Apply (`omarchy theme set`, plus `bg set` if you picked a background) |
| `Esc` | Clear filter, then cancel — the shell reverts |

Scroll the filmstrip with the wheel; click a card to select it.

## Scripting

`pick.sh` opens Swatch and prints the chosen theme name without applying it, the same contract as `omarchy-theme-switcher`:

```sh
theme=$(~/.config/omarchy/plugins/jmckible.swatch/pick.sh) && omarchy theme set "$theme"
```

## How it works

- `index.sh` walks `~/.config/omarchy/themes` and the stock themes, resolves each `colors.toml` through `omarchy-theme-color` (so legacy keys and aliases match what `theme set` produces), and writes `~/.cache/omarchy/swatch/index.json`. Records are reused when a theme's signature (dir mtime + `colors.toml`/`shell.toml`/preview stat) is unchanged; only changed themes are re-resolved.
- `thumbs.sh` makes 640×360 filmstrip thumbs for any record that lacks one. It runs on every open and does nothing when nothing is missing.
- Live preview is the same call `omarchy theme set` makes over IPC (`shell applyTheme`) — shell-only, reverted on cancel, never written to disk. Terminal palettes and Hyprland borders change on apply, not during preview.
- Video: `backgrounds/foo.mp4` is a theme intro. It plays once, muted, when you arrive on the theme, then dissolves into the selected background. A still with the same stem (`foo.png`) is its poster frame and is not offered as a wallpaper. Stock tooling never globs videos, so this is invisible to `omarchy theme set`. Only the selected theme's video is opened. (Convention proposed ahead of Omarchy 4.1; expect it to change.)
- Themes are treated as untrusted input. Inside a theme, symlinks are never followed and every file must be a regular file under that theme's directory, within size and count ceilings (64 KB TOML, 64 MB / 50 MP images, 200 backgrounds, 512 themes). Image decoding runs single-threaded under a timeout and memory limit, at most four at a time, and only ever writes to `~/.cache/omarchy/swatch/`.

## Remove

```sh
omarchy plugin remove jmckible.swatch --yes
```

Then delete the `"style.theme"` line you added to `~/.config/omarchy/extensions/omarchy-menu.jsonc` to restore the stock picker, and optionally the cache at `~/.cache/omarchy/swatch/`. Swatch writes nothing else.

## Develop

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/jmckible.swatch
omarchy-shell shell rescanPlugins && omarchy plugin enable jmckible.swatch
./index.sh | jq '.themes | length'
node test/model.test.js
```

After editing QML, `omarchy restart shell`. The shell's plugin hot-reload re-mounts the cached component (the engine has no `Qt.clearComponentCache`), so edits don't land without a restart. Scripts are read fresh every open.

Bump the `v2` line in `sig()` whenever `resolve()`'s record shape changes; that's what invalidates cached records.
