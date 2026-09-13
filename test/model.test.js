// node test/model.test.js
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// SwatchModel.js carries a `.pragma library` line for QML; strip it for node.
const src = fs.readFileSync(path.join(__dirname, "..", "SwatchModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const m = { exports: {} }
new Function("module", "exports", src)(m, m.exports)
const Model = m.exports

const T = [
  { name: "tokyo-night", label: "Tokyo Night", mode: "dark", source: "stock", preview: "/p/t.png", previewKey: "aaaaaaaaaaaaaaaa", backgrounds: ["/b/1.jpg", "/b/2.jpg"], bgKeys: ["1111111111111111", "2222222222222222"], colors: { red: "#1", yellow: "#2", green: "#3", cyan: "#4", blue: "#5", magenta: "#6" } },
  { name: "rose-pine", label: "Rose Pine", mode: "light", source: "stock", preview: "", backgrounds: [], colors: {} },
  { name: "last-call", label: "Last Call", mode: "dark", source: "user", preview: "/p/l.png", previewKey: "cccccccccccccccc", backgrounds: [], colors: {} },
]

assert.deepEqual(Model.filter(T, "", "all").map((t) => t.name), ["tokyo-night", "rose-pine", "last-call"])
assert.deepEqual(Model.filter(T, "ro", "all").map((t) => t.name), ["rose-pine"])
assert.deepEqual(Model.filter(T, "", "light").map((t) => t.name), ["rose-pine"])
assert.deepEqual(Model.filter(T, "", "installed").map((t) => t.name), ["last-call"])
assert.deepEqual(Model.filter(T, "", "stock").map((t) => t.name), ["tokyo-night", "rose-pine"])
assert.deepEqual(Model.filter(T, "Tokyo", "dark").map((t) => t.name), ["tokyo-night"])

// Fuzzy: typed characters match as an in-order subsequence, gaps allowed.
assert.deepEqual(Model.filter(T, "tkn", "all").map((t) => t.name), ["tokyo-night"])
assert.deepEqual(Model.filter(T, "rpine", "all").map((t) => t.name), ["rose-pine"])
assert.deepEqual(Model.filter(T, "LC", "all").map((t) => t.name), ["last-call"])   // via the label, case-folded
assert.deepEqual(Model.filter(T, "nkt", "all").map((t) => t.name), [])             // out of order stays a miss
assert.deepEqual(Model.filter(T, "tokyoz", "all").map((t) => t.name), [])

assert.equal(Model.nextMode("all"), "dark")
assert.equal(Model.nextMode("installed"), "stock")
assert.equal(Model.nextMode("stock"), "all")

assert.equal(Model.indexOf(T, "last-call"), 2)
assert.equal(Model.indexOf(T, "nope"), -1)
assert.equal(Model.findByName(T, "rose-pine").label, "Rose Pine")

assert.equal(Model.clamp(5, 3), 2)
assert.equal(Model.clamp(-2, 3), 0)
assert.equal(Model.clamp(0, 0), -1)

assert.equal(Model.wrap(3, 3), 0)
assert.equal(Model.wrap(-1, 3), 2)
assert.equal(Model.wrap(1, 3), 1)
assert.equal(Model.wrap(0, 0), -1)

assert.equal(Model.backgroundAt(T[0], 1), "/b/2.jpg")
assert.equal(Model.backgroundAt(T[0], 9), "/b/2.jpg")
assert.equal(Model.backgroundAt(T[2], 0), "/p/l.png")
assert.equal(Model.backgroundAt(null, 0), "")

assert.deepEqual(Model.ansi(T[0]), ["#1", "#2", "#3", "#4", "#5", "#6"])
assert.equal(Model.ansi(T[1]).length, 6)


assert.equal(Model.keyAt(T[0], 1), "2222222222222222")
assert.equal(Model.keyAt(T[0], 9), "2222222222222222")
assert.equal(Model.keyAt(T[2], 0), "cccccccccccccccc")   // no backgrounds: the preview's key
assert.equal(Model.keyAt(T[1], 0), "")
assert.equal(Model.keyAt(null, 0), "")

// The current-background link resolves into the staged copy, so only the file
// name matches what the index lists.
assert.equal(Model.backgroundIndexOf(T[0], "/b/2.jpg"), 1)
assert.equal(Model.backgroundIndexOf(T[0], "/home/u/.local/state/omarchy/current/theme/backgrounds/2.jpg"), 1)
assert.equal(Model.backgroundIndexOf(T[0], "/elsewhere/3.jpg"), -1)
assert.equal(Model.backgroundIndexOf(T[0], ""), -1)
assert.equal(Model.backgroundIndexOf(T[1], "/b/1.jpg"), -1)
assert.equal(Model.backgroundIndexOf(null, "/b/1.jpg"), -1)

assert.equal(Model.thumbPath("/c", "1111111111111111"), "/c/bg-1111111111111111.jpg")
assert.equal(Model.thumbPath("", "1111111111111111"), "")
assert.equal(Model.stagePath("/c", "1111111111111111", 2560, 1440), "/c/stage-1111111111111111-2560x1440.jpg")
assert.equal(Model.stagePath("/c", "", 2560, 1440), "")
assert.equal(Model.stagePath("/c", "1111111111111111", 0, 1440), "")

// Animated backgrounds. bgVideoKeys is parallel to backgrounds with a blank
// wherever a background is still-only, so position is the pairing: a miss at
// index 0 must not shift index 1's clip onto index 0.
const V = { name: "gruvbox", label: "Gruvbox", mode: "dark", source: "stock",
  backgrounds: ["/b/1.jpg", "/b/2.jpg", "/b/3.jpg"],
  bgKeys: ["1111111111111111", "2222222222222222", "3333333333333333"],
  bgVideos: ["", "/b/2.mp4", ""],
  bgVideoKeys: ["", "2222222222222222", ""] }

assert.equal(Model.videoKeyAt(V, 1), "2222222222222222")
assert.equal(Model.videoKeyAt(V, 0), "")
assert.equal(Model.videoKeyAt(V, 2), "")
assert.equal(Model.hasVideo(V, 1), true)
assert.equal(Model.hasVideo(V, 0), false)
// Out-of-range clamps like keyAt does, rather than returning undefined.
assert.equal(Model.videoKeyAt(V, 99), "")
assert.equal(Model.videoKeyAt(V, -5), "")
// A theme predating the field, and no theme at all.
assert.equal(Model.videoKeyAt(T[0], 0), "")
assert.equal(Model.hasVideo(T[0], 0), false)
assert.equal(Model.videoKeyAt(null, 0), "")
assert.equal(Model.hasVideo(null, 0), false)

assert.equal(Model.videoPath("/c", "2222222222222222"), "/c/vid-2222222222222222.mp4")
assert.equal(Model.videoPath("/c", ""), "")
assert.equal(Model.videoPath("", "2222222222222222"), "")

console.log("ok")

// Curation preserves the source index and video alignment, across cache changes.
const prefs = { favorites: ['gruvbox'], hidden: { gruvbox: ['theme:1.jpg'] } }
const curated = Model.curate([V], prefs, true, false)[0]
assert.deepEqual(curated.backgrounds, ['/b/2.jpg', '/b/3.jpg'])
assert.deepEqual(curated.bgVideoKeys, ['2222222222222222', ''])
assert.equal(Model.backgroundAt(curated, 0), '/b/2.jpg')
assert.equal(Model.hasVideo(curated, 0), true)
assert.equal(V.backgrounds.length, 3)
assert.equal(Model.curate([V], {favorites: [], hidden: {}}, true, false).length, 0)
assert.equal(Model.curate([V], prefs, false, true)[0].backgrounds.length, 3)
assert.equal(Model.isHidden(prefs, 'gruvbox', '/different/root/1.jpg'), true)
assert.equal(Model.backgroundId('/home/u/.config/omarchy/backgrounds/gruvbox/1.jpg'), 'extra:1.jpg')
assert.equal(Model.isHidden(prefs, 'gruvbox', '/home/u/.config/omarchy/backgrounds/gruvbox/1.jpg'), false)
assert.equal(Model.isHidden({hidden: {}}, 'constructor', '/b/1.jpg'), false)
const allHidden = {favorites: [], hidden: {gruvbox: ['theme:1.jpg', 'theme:2.jpg', 'theme:3.jpg']}}
assert.deepEqual(Model.curate([V], allHidden, false, false)[0].backgrounds, ['/b/1.jpg'])
const previewHidden = {...V, preview: '/b/1.jpg', previewKey: 'old'}
assert.equal(Model.curate([previewHidden], prefs, false, false)[0].previewKey, '2222222222222222')
assert.equal(Model.filter(Model.curate([V, ...T], prefs, true, false), '', 'light').length, 0)

// Name searches bypass both browsing filters without losing hidden backgrounds.
const searchCollection = Model.curate(T, {
  favorites: ['tokyo-night'], hidden: {'tokyo-night': ['theme:1.jpg']}
}, false, false)
assert.deepEqual(Model.browse(searchCollection, 'rose', 'dark', true).map(t => t.name), ['rose-pine'])
assert.deepEqual(Model.browse(searchCollection, 'last', 'stock', true).map(t => t.name), ['last-call'])
assert.deepEqual(Model.browse(searchCollection, '', 'dark', true).map(t => t.name), ['tokyo-night'])
assert.deepEqual(Model.browse(searchCollection, 'tokyo', 'light', false)[0].backgrounds, ['/b/2.jpg'])
assert.deepEqual(Model.browse(searchCollection, '', 'light', true), [])
