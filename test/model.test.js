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

assert.equal(Model.thumbPath("/c", "1111111111111111"), "/c/bg-1111111111111111.jpg")
assert.equal(Model.thumbPath("", "1111111111111111"), "")
assert.equal(Model.stagePath("/c", "1111111111111111", 2560, 1440), "/c/stage-1111111111111111-2560x1440.jpg")
assert.equal(Model.stagePath("/c", "", 2560, 1440), "")
assert.equal(Model.stagePath("/c", "1111111111111111", 0, 1440), "")

console.log("ok")
