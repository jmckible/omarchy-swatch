// Pure functions over the index. No QML here so `node test/model.test.js` can
// cover them.
.pragma library

function norm(s) { return String(s || "").toLowerCase() }

// Subsequence match: the typed characters appear in order, gaps allowed, so
// "catl" finds "catppuccin-latte". A substring hit is the gapless case.
function fuzzy(haystack, needle) {
  var i = 0
  for (var j = 0; j < haystack.length && i < needle.length; j++)
    if (haystack[j] === needle[i]) i++
  return i === needle.length
}

function matches(theme, text, mode) {
  if (mode === "dark" && theme.mode !== "dark") return false
  if (mode === "light" && theme.mode !== "light") return false
  if (mode === "installed" && theme.source !== "user") return false
  if (mode === "stock" && theme.source !== "stock") return false
  if (!text) return true
  var needle = norm(text)
  return fuzzy(norm(theme.name), needle) || fuzzy(norm(theme.label), needle)
}

function filter(themes, text, mode) {
  var out = []
  for (var i = 0; i < themes.length; i++) if (matches(themes[i], text, mode)) out.push(themes[i])
  return out
}

var MODES = ["all", "dark", "light", "installed", "stock"]

function nextMode(mode) {
  var i = MODES.indexOf(mode)
  return MODES[(i + 1) % MODES.length]
}

function indexOf(rows, name) {
  for (var i = 0; i < rows.length; i++) if (rows[i].name === name) return i
  return -1
}

function findByName(themes, name) {
  var i = indexOf(themes, name)
  return i === -1 ? null : themes[i]
}

function clamp(i, n) {
  if (n <= 0) return -1
  return Math.max(0, Math.min(n - 1, i))
}

function wrap(i, n) {
  if (n <= 0) return -1
  return ((i % n) + n) % n
}

// Background path for a theme at bgIndex; falls back to the preview image.
// This is the theme's file — used to match the current background and to
// hand to omarchy-theme-bg-set, never to load pixels from.
function backgroundAt(theme, bgIndex) {
  if (!theme) return ""
  var bgs = theme.backgrounds || []
  if (bgs.length === 0) return theme.preview || ""
  return bgs[clamp(bgIndex, bgs.length)]
}

// Where the desktop's current background sits in a theme's list. The current
// background link points into the staged copy omarchy-theme-set makes
// (~/.local/state/omarchy/current/theme/backgrounds/x.jpg), not at the source
// file this index lists, so an exact path only matches a background the user
// set themselves through omarchy-theme-bg-set. The copy keeps the file name, so
// that is the fallback -- without it the picker opens on the theme's first
// wallpaper while the desktop is showing its fourth.
function backgroundIndexOf(theme, path) {
  var bgs = theme && theme.backgrounds ? theme.backgrounds : []
  if (!path || bgs.length === 0) return -1
  var exact = bgs.indexOf(path)
  if (exact !== -1) return exact
  var base = baseName(path)
  for (var i = 0; i < bgs.length; i++) if (baseName(bgs[i]) === base) return i
  return -1
}

function baseName(path) {
  var s = String(path || "")
  return s.slice(s.lastIndexOf("/") + 1)
}

// Cache key of that same image. Every pixel the overlay shows comes from a
// derivative thumbs.sh produced under this key.
function keyAt(theme, bgIndex) {
  if (!theme) return ""
  var keys = theme.bgKeys || []
  if (keys.length === 0) return theme.previewKey || ""
  return keys[clamp(bgIndex, keys.length)] || ""
}

function thumbPath(dir, key) { return dir && key ? dir + "/bg-" + key + ".jpg" : "" }
function stagePath(dir, key, w, h) { return dir && key && w > 0 && h > 0 ? dir + "/stage-" + key + "-" + w + "x" + h + ".jpg" : "" }

// The animated alternative of the background at bgIndex, or "" when that
// background does not move. bgVideoKeys is parallel to backgrounds, with a
// blank at every still-only position -- so a miss is a blank entry, not a
// short array, and the index is never shifted by earlier misses.
function videoKeyAt(theme, bgIndex) {
  if (!theme) return ""
  var keys = theme.bgVideoKeys || []
  if (keys.length === 0) return ""
  var i = clamp(bgIndex, keys.length)
  return i === -1 ? "" : (keys[i] || "")
}

function videoPath(dir, key) { return dir && key ? dir + "/vid-" + key + ".mp4" : "" }

// Whether a background has an animated alternative at all. The QML asks this
// before arming the dwell timer, so a still-only background costs nothing.
function hasVideo(theme, bgIndex) { return videoKeyAt(theme, bgIndex) !== "" }

function ansi(theme) {
  var c = theme && theme.colors ? theme.colors : {}
  return [c.red, c.yellow, c.green, c.cyan, c.blue, c.magenta].map(function(x) { return x || "#808080" })
}

if (typeof module !== "undefined") {
  module.exports = { matches: matches, filter: filter, nextMode: nextMode, indexOf: indexOf, findByName: findByName, clamp: clamp, wrap: wrap, backgroundAt: backgroundAt, backgroundIndexOf: backgroundIndexOf, keyAt: keyAt, thumbPath: thumbPath, stagePath: stagePath, videoKeyAt: videoKeyAt, videoPath: videoPath, hasVideo: hasVideo, ansi: ansi, MODES: MODES }
}
