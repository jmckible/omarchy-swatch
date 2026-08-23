// Pure functions over the index. No QML here so `node test/model.test.js` can
// cover them.
.pragma library

function norm(s) { return String(s || "").toLowerCase() }

function matches(theme, text, mode) {
  if (mode === "dark" && theme.mode !== "dark") return false
  if (mode === "light" && theme.mode !== "light") return false
  if (mode === "installed" && theme.source !== "user") return false
  if (mode === "stock" && theme.source !== "stock") return false
  if (!text) return true
  var needle = norm(text)
  return norm(theme.name).indexOf(needle) !== -1 || norm(theme.label).indexOf(needle) !== -1
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

// Background shown for a theme at bgIndex; falls back to the preview image.
function backgroundAt(theme, bgIndex) {
  if (!theme) return ""
  var bgs = theme.backgrounds || []
  if (bgs.length === 0) return theme.preview || ""
  return bgs[clamp(bgIndex, bgs.length)]
}

// Where selection lands within a theme's backgrounds: on the video's paired
// still when there is one, so the clip settles into what stays on screen.
function defaultBgIndex(theme) {
  if (!theme || !theme.video || !theme.videoStill) return 0
  var i = (theme.backgrounds || []).indexOf(theme.videoStill)
  return i === -1 ? 0 : i
}

function ansi(theme) {
  var c = theme && theme.colors ? theme.colors : {}
  return [c.red, c.yellow, c.green, c.cyan, c.blue, c.magenta].map(function(x) { return x || "#808080" })
}

if (typeof module !== "undefined") {
  module.exports = { matches: matches, filter: filter, nextMode: nextMode, indexOf: indexOf, findByName: findByName, clamp: clamp, wrap: wrap, backgroundAt: backgroundAt, defaultBgIndex: defaultBgIndex, ansi: ansi, MODES: MODES }
}
