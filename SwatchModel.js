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

function ansi(theme) {
  var c = theme && theme.colors ? theme.colors : {}
  return [c.red, c.yellow, c.green, c.cyan, c.blue, c.magenta].map(function(x) { return x || "#808080" })
}

if (typeof module !== "undefined") {
  module.exports = { matches: matches, filter: filter, nextMode: nextMode, indexOf: indexOf, findByName: findByName, clamp: clamp, wrap: wrap, backgroundAt: backgroundAt, keyAt: keyAt, thumbPath: thumbPath, stagePath: stagePath, ansi: ansi, MODES: MODES }
}
