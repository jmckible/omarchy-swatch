import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "SwatchModel.js" as Model

// Swatch: try the theme on. The candidate's wallpaper fills the screen, the
// shell retints to its palette while you scrub, and a filmstrip running through
// a fixed gate is the only chrome that isn't the theme itself.
Item {
  id: root

  // Injected by the shell's plugin Loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false            // read by shell.isPluginOpen()

  readonly property string home: Quickshell.env("HOME")

  // Index and view state.
  property var preferences: ({version: 1, favorites: [], hidden: {}})
  property bool preferencesReady: false
  property real collectionOpacity: 1
  property real collectionOffset: 0
  property bool favoritesOnly: false
  property bool openingIndexReady: false
  property bool openingFavoritesSettled: false
  property bool showHidden: false
  readonly property int selectedHiddenCount: selected ? (selected.hiddenCount || 0) : 0
  readonly property int hiddenFooterHeight: selectedHiddenCount > 0 && !showHidden ? root.sp(30) : 0
  property string curationMessage: ""
  onCurationMessageChanged: if (curationMessage) curationNotice.restart()
  Timer { id: curationNotice; interval: 5000; onTriggered: root.curationMessage = "" }
  property var undoHide: null
  readonly property bool backgroundHidden: !!selected && Model.isHidden(preferences, selected.name, selectedBackground)
  property var curatedThemes: []
  property var themes: []
  property string loadedIndex: ""
  property var rows: []
  property bool searching: false
  property string filterText: ""
  property int selectedIndex: -1
  property int bgIndex: 0
  property string currentTheme: ""
  property string currentBackground: ""
  property string pickDir: ""
  property string thumbsDir: ""
  property int cacheGen: 0    // ticks while thumbs.sh lands derivatives; failed loads retry on it
  property bool applying: false
  property string applyTarget: ""   // the background we are waiting to see land

  // Exit: the preview defocuses into black, holds there while the real swap
  // lands underneath, then resolves back out sharp onto a desktop it already
  // matches. Black is the only element that reads against a matching image —
  // and while it is up nothing can look wrong, so the hold absorbs a late swap
  // or a slow decode instead of us betting a constant on them.
  property real exitBlur: 0
  property real blackout: 0
  property bool liftPending: false
  readonly property int holdFloorMs: 180

  // Which strip the last move was in, and which way. The transition follows the
  // axis you pressed: themes are a horizontal filmstrip, backgrounds a vertical
  // one, so the motion itself says which list you are moving through.
  property string scrubAxis: "theme"
  property int scrubDir: 1
  property bool scrubArmed: false
  property bool viewReady: false
  property bool rebuilding: false
  // True from open() until the first wallpaper has actually been shown, so
  // that one hand-off is a cut rather than a transition. See the slot Behavior.
  property bool landing: false
  property bool scrubQuick: false   // already mid-wipe: don't queue another

  // A luma wipe: one greyscale map, one threshold swept across it. The map is
  // what makes the look — a gradient is a hard-edged wipe, a radial one is an
  // iris, a noise field is a burn — so the effect is chosen by picking a map,
  // not by writing another animation. maskSpreadAtMin is the softness of the
  // leading edge, which is most of the difference between cheap and expensive.
  property string wipeFrom: ""
  property real wipeT: 0
  property bool wiping: false
  property string wipeMap: "gradient"        // gradient | iris | burn

  // The strip lands in 160 ms, and it is the thing your hand is driving, so a
  // wipe much longer than that stops being the same gesture and becomes an
  // animation you wait through. Duration tracks how fast you are moving, and
  // the edge softens as it shortens — a hard line at speed is a strobe, a wide
  // soft band at speed still reads as a sweep. Character comes from the edge,
  // not from the clock.
  property double lastMoveAt: 0
  property bool scrubRapid: false
  // Both axes wipe; the difference is the edge, not the mechanism. A theme is a
  // different world arriving, so it gets a defined edge. A background is the
  // same theme one frame further along its own strip, so it gets a wide soft
  // one that reads as a dissolve with a direction rather than as a cut.
  readonly property bool wipingBg: scrubAxis === "bg"
  readonly property int wipeMs: scrubRapid ? 140 : (wipingBg ? 220 : 240)
  readonly property real wipeSpread: wipeMap === "iris"
    ? (scrubRapid ? 0.34 : 0.16)
    : wipingBg ? (scrubRapid ? 0.42 : 0.34)
               : (scrubRapid ? 0.30 : 0.12)

  // A theme change is the bar's to make: the crossfade waits until the bar is
  // most of the way across and then happens fast enough to read as a cut. Held
  // arrow keys fall back to a plain quick blend — a bar per keypress is a mess.
  readonly property int fadeMs: scrubAxis === "bg" ? 150 : (scrubQuick ? 110 : 90)
  readonly property int fadeDelayMs: (scrubAxis === "bg" || scrubQuick) ? 0 : 170
  // Everything that isn't the wallpaper. It goes the moment a choice is
  // committed, leaving the candidate's wallpaper and the real bar — which is
  // the desktop that is a moment away. Instant on open (the Behavior is armed
  // only while applying) so the picker doesn't fade in over itself.
  property real chromeOpacity: 1
  Behavior on chromeOpacity { enabled: root.applying; NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }
  // Written by syncVideoMoving, which the slots call when their own motion
  // changes — a root binding cannot reach into a Repeater delegate.
  property bool videoMoving: false
  property bool previewsQuiet: false
  onVideoMovingChanged: {
    previewsQuiet = false
    if (videoMoving) previewQuietDelay.restart()
    else previewQuietDelay.stop()
  }
  Timer {
    id: previewQuietDelay
    interval: 1000
    onTriggered: root.previewsQuiet = root.videoMoving
  }
  property bool livePreview: true

  readonly property var selected: (selectedIndex >= 0 && selectedIndex < rows.length) ? rows[selectedIndex] : null
  readonly property string selectedBackground: Model.backgroundAt(selected, bgIndex)
  readonly property string selectedKey: Model.keyAt(selected, bgIndex)

  // Animated backgrounds. Playback begins while the wipe that revealed the
  // background is still running — it is not a dwell you wait out. That matters
  // most for an ARRIVE clip, whose still IS its final frame: wait, and you are
  // shown the ending before the animation starts from the beginning.
  //
  // Clips are held open per background rather than opened on arrival — see
  // videoSlots below, which is what lets the arm delay be skipped outright for a
  // clip already in a slot. The delay remains for the clip that is not: a
  // debounce sized to outlast key auto-repeat (~40 ms), far below wipeMs, so a
  // held arrow opens nothing and a deliberate landing on a cold clip still has
  // it moving by the time the wipe finishes.
  readonly property string selectedVideoKey: Model.videoKeyAt(selected, bgIndex)
  readonly property bool videoAvailable: selectedVideoKey !== "" && !applying && opened && viewReady
  property bool videoArmed: false
  readonly property int videoArmDelayMs: 120

  // One player per clip: the selected background, its two neighbours on the
  // background axis, and whichever clip is still fading out. This is what takes
  // the still out from between two animations.
  //
  // The old single player had to re-open on every move, and although the ~115 ms
  // open ran underneath the 120 ms arm delay rather than after it, the incoming
  // clip could still only *begin* once both had elapsed — by which time the
  // outgoing clip's 140 ms fade-out was over and the still underneath had the
  // screen to itself for about 100 ms. Keeping a player per clip means the one
  // you land on is already open, so arming can skip its debounce entirely
  // (`disarmVideo`) and the incoming fade-in runs against the outgoing fade-out
  // instead of after it.
  //
  // Keyed by video key, the way the wallpaper slots are keyed by image key, so a
  // slot already holding a wanted clip keeps its loaded player rather than
  // re-opening it. ±1 is the whole win: it covers a deliberate step either way,
  // and anything faster is suppressed by scrubRapid rather than preloaded for.
  readonly property int videoSlotCount: 4
  property var videoSlots: ["", "", "", ""]
  // The clip being handed away, kept slotted so it still has a frame to hold
  // while it fades. Without it a theme jump evicts the outgoing player, and a
  // torn-down VideoOutput is blank — a black hole exactly where the cross-fade
  // is supposed to be seamless.
  property string videoPrevKey: ""
  // The live key as stageVideo last staged it, so it can tell a real hand-off
  // from being called again about the same background.
  property string videoLiveKey: ""
  // A hand-off is in flight, so the outgoing clip keeps the screen opaque under
  // the incoming one. Sized to outlast the longer of the wipe and the off-wipe
  // fade, plus the worst case where the incoming clip was cold and had to open
  // first; releasing early would put the still back exactly where it was.
  property bool videoHandoff: false
  // Neighbours open under the same burst suppression as the live clip: a held
  // arrow preloads nothing, since every background it crosses would want a
  // different pair.
  readonly property bool videoSlotsLoadable: opened && viewReady && !applying && !scrubRapid
  readonly property var ansi: Model.ansi(selected)
  readonly property color bg: selected ? selected.colors.background || "#101315" : "#101315"
  readonly property color fg: selected ? selected.colors.foreground || "#cacccc" : "#cacccc"
  readonly property color accent: selected ? selected.colors.accent || fg : fg

  // Wallpaper slots: the selected background plus its neighbours stay
  // decoded in fixed Image items (the pixmap cache won't hold screen-size
  // images for us), so scrubbing never waits on a decode it already did.
  // Slots hold cache keys; what they show is the stage copy thumbs.sh made.
  readonly property int slotCount: 5
  property var slots: ["", "", "", "", ""]
  property var slotAge: [0, 0, 0, 0, 0]
  property int tick: 0
  property string shownKey: ""

  // Metrics are frozen per open. A candidate's shell.toml may carry a spacing
  // scale or font sizes; the live preview applies them and the shell around
  // the picker re-lays out — that is the honest preview of apply — but the
  // picker's own geometry must not jump under the cursor while scrubbing.
  // Colours and the font family stay live, so it still looks like the theme.
  property real metricScale: 1
  property var fz: ({ caption: 10, body: 12, subtitle: 13, title: 14, heading: 16 })
  function freezeMetrics() {
    var m = Number(Style.effectiveSpacingScale)
    metricScale = m > 0 ? m : 1
    samplePx = Math.max(1, Math.round(Style.fontBaseSize))
    fz = { caption: root.fz.caption, body: root.fz.body, subtitle: root.fz.subtitle, title: root.fz.title, heading: root.fz.heading }
  }
  function sp(px) { var n = px * metricScale; return n <= 0 ? 0 : Math.max(1, Math.round(n)) }

  // One shear for the whole overlay. Every parallelogram on screen — the theme
  // cards, the background cards, the sample panels, the gate — leans by this
  // fraction of its own height, so every slanted edge is parallel to every
  // other one and nothing can read as pointing the other way. Anything that
  // instead took a fixed offset, or turned the shape to follow its own strip's
  // axis, ends up raking against its neighbours: a shear leaves horizontals
  // horizontal, and only the vertical edges move.
  readonly property real rake: 0.19

  // Reading content scales with the screen above a 1440-wide baseline, so a
  // 13" laptop keeps Style's sizes and a 4K desk doesn't get 13 px samples.
  readonly property real k: panel.width > 0 ? Math.max(1, Math.min(1.8, panel.width / 1440)) : 1
  readonly property int metaPx: Math.round(root.fz.body * k)
  // Native shell text size, captured on open. No presentation enlargement,
  // and no resizing as candidate themes retint the shell while browsing.
  property int samplePx: 12

  // Stage copies are made at the largest monitor's physical size, measured by
  // index.sh. The shell never decodes a theme's own file; everything it shows
  // is a derivative from our cache.
  property int stageW: 2560
  property int stageH: 1440

  function scriptPath(name) { return Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "") }

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var args = {}
    try { args = JSON.parse(payloadJson || "{}") || {} } catch (e) { args = {} }
    pickDir = String(args.dir || "")
    cancelExit()
    resetCollectionTransition()
    applying = false
    applyTarget = ""
    chromeOpacity = 1
    previewsQuiet = false
    exitBlur = 0
    blackout = 0
    liftPending = false
    scrubArmed = false
    scrubQuick = false
    scrubRapid = false   // a stale burst flag would suppress the first clip load
    // Nothing carries across opens: the slots are re-filled by the landing's own
    // stageVideo, and a key left over from last time would hold a player open
    // for a background this open may never reach.
    videoSlots = ["", "", "", ""]
    videoPrevKey = ""
    videoLiveKey = ""
    videoMoving = false
    videoHandoff = false
    videoHandoffHold.stop()
    viewReady = false
    landing = true       // the first wallpaper of this open is a cut, not a fade
    wipeRun.stop(); wiping = false; wipeFrom = ""
    stage.opacity = 0
    wallpaperLayer.scale = 1
    freezeMetrics()
    searching = false
    filterText = ""
    showHidden = false
    openingIndexReady = false
    openingFavoritesSettled = false
    // Use cached state for the first frame, then reconcile both async reads.
    favoritesOnly = preferences.favorites.indexOf(currentTheme) !== -1
    curatedThemes = Model.curate(themes, preferences, false, showHidden)
    curationMessage = ""
    readPreferences()
    opened = true
    // Land on the current theme from the previous open's index before asking
    // for a fresh one. selectedIndex survives close(), and indexProc is async,
    // so without this the overlay paints the last session's highlight until
    // index.sh returns — long enough to read as "it opened on the wrong
    // theme", and long enough for that stale selection to start playing its
    // clip. Runs after `opened` so the dwell arms against the real landing.
    if (themes.length) rebuild(true)
    if (themes.length) selectionProc.running = true
    else indexProc.running = true
    openingDeadline.restart()
    openingPoll.start()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    resetCollectionTransition()
    if (!applying && livePreview) revertPreview()
    if (pickDir && !applying) finishPick("")
    cancelExit()
    opened = false
    openingPoll.stop()
    openingDeadline.stop()
    viewReady = false
  }

  function dismiss() {
    if (shell && manifest) shell.hide(manifest.id)
    else close()
  }

  // ---------------------------------------------------------------- index

  // index.sh bounds its own output (8 MB, refused rather than truncated), so
  // this collector never holds more than that.
  Process {
    id: indexProc
    command: [root.scriptPath("index.sh"), "--cached"]
    onExited: { if (!refreshProc.running) refreshProc.running = true }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.loadIndex(text) }
  }

  Process {
    id: selectionProc
    command: [root.scriptPath("index.sh"), "--selection"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state
        try { state = JSON.parse(text) } catch (e) { indexProc.running = true; return }
        var theme = Model.findByName(root.themes, state.currentTheme)
        if (!theme || (state.currentBackground && Model.backgroundIndexOf(theme, state.currentBackground) < 0)) {
          if (!refreshProc.running) refreshProc.running = true
          return
        }
        root.currentTheme = state.currentTheme
        root.currentBackground = state.currentBackground
        root.openingIndexReady = true
        root.settleOpeningFavorites()
        root.curatedThemes = Model.curate(root.themes, root.preferences, false, root.showHidden)
        root.rebuild(true)
        if (!refreshProc.running) refreshProc.running = true
      }
    }
  }

  Process {
    id: refreshProc
    command: [root.scriptPath("index.sh")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.loadIndex(text, true) }
  }

  // Keep the desktop visible until both lists and the full-size still are in
  // place. Only the opening acknowledgement is visible during preparation.
  Timer {
    id: openingPoll
    interval: 16
    repeat: true
    onTriggered: root.revealOpening(false)
  }
  Timer { id: openingDeadline; interval: 5000; onTriggered: root.revealOpening(true) }
  function revealOpening(fallback) {
    if (!opened || viewReady) return
    var slot = slots.indexOf(selectedKey)
    var item = slot < 0 ? null : wallpapers.itemAt(slot)
    if (!fallback && (!openingIndexReady || !preferencesReady || rebuilding
        || (selectedKey && (!item || !item.fullReady)))) return
    strip.forceLayout()
    bgStrip.forceLayout()
    if (selectedIndex >= 0) strip.positionViewAtIndex(selectedIndex, ListView.Center)
    if (bgIndex >= 0) bgStrip.positionViewAtIndex(bgIndex, ListView.Beginning)
    if (item && item.ready) setShown(selectedKey)
    Qt.callLater(function() {
      if (!root.opened) return
      stage.opacity = 1
      root.viewReady = true
      root.landing = false
      root.scrubArmed = true
      openingPoll.stop()
      openingDeadline.stop()
    })
  }

  function readPreferences() {
    if (preferencesProc.running) return
    preferencesReady = false
    preferencesProc.nextUndo = undoHide
    preferencesProc.successMessage = ""
    preferencesProc.command = ["python3", scriptPath("preferences.py"), "read"]
    preferencesProc.running = true
  }

  Process {
    id: preferencesProc
    property var nextUndo: null
    property string successMessage: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!text) return
        try {
          root.preferences = JSON.parse(text)
          root.preferencesReady = true
          var landed = root.settleOpeningFavorites()
          root.curatedThemes = Model.curate(root.themes, root.preferences, false, root.showHidden)
          root.undoHide = preferencesProc.nextUndo
          root.curationMessage = preferencesProc.successMessage
          root.scrubQuick = true
          if (preferencesProc.command[2] === "favorite" && root.favoritesOnly && !root.filterText) root.transitionCollection()
          else root.rebuild(landed)
        } catch (e) { root.curationMessage = "Could not read saved choices" }
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.curationMessage = "Could not save or read choices; preferences left unchanged"
    }
  }

  function saveChoice(action, name, value, background, undo, message) {
    if (!preferencesReady || preferencesProc.running) return
    var args = ["python3", scriptPath("preferences.py"), action, name, value ? "true" : "false"]
    if (action === "hidden") args.push(background)
    preferencesProc.nextUndo = undo
    preferencesProc.successMessage = message
    preferencesProc.command = args
    preferencesProc.running = true
  }

  function toggleFavorite() {
    if (!selected) return
    saveChoice("favorite", selected.name, !selected.favorite, "", undoHide, "")
  }

  function toggleBackgroundHidden() {
    if (!selected || !selected.backgrounds.length) return
    var hidden = backgroundHidden
    var original = Model.findByName(themes, selected.name)
    var visibleCount = original.backgrounds.filter(function(path) {
      return !Model.isHidden(root.preferences, original.name, path)
    }).length
    if (!hidden && visibleCount <= 1) {
      curationMessage = "Keep one background visible for this theme"
      return
    }
    var key = Model.backgroundId(selectedBackground)
    saveChoice("hidden", selected.name, !hidden, key,
               hidden ? null : {name: selected.name, key: key},
               "")
  }

  function restoreLastHidden() {
    if (undoHide) saveChoice("hidden", undoHide.name, false, undoHide.key, null, "")
  }

  function curationStatus() { return JSON.stringify({available: true, ready: preferencesReady, favorites: preferences.favorites.length, viewReady: viewReady}) }

  // Side-effect-free, like curationStatus. Whether a clip plays inside the wipe
  // or after it is not visible in any log, and the difference is one frame of
  // arming state — so it has to be inspectable from outside while the picker is
  // open, or the only way to check a change here is to trust your eyes.
  function videoStatus() {
    var out = []
    for (var i = 0; i < videoSlotCount; i++) {
      var l = videoStages.itemAt(i)
      var key = videoSlots[i]
      out.push({
        key: key ? key.slice(0, 8) : "",
        live: key !== "" && key === selectedVideoKey,
        open: !!(l && l.status === Loader.Ready && l.item && l.item.active),
        loaded: !!(l && l.status === Loader.Ready && l.item && l.item.loaded),
        showing: !!(l && l.status === Loader.Ready && l.item && l.item.showing),
        framed: !!(l && l.status === Loader.Ready && l.item && l.item.framed),
        opacity: l ? Math.round(l.opacity * 100) / 100 : 0
      })
    }
    return JSON.stringify({
      armed: videoArmed, moving: videoMoving, rapid: scrubRapid,
      wiping: wiping, handoff: videoHandoff, live: selectedVideoKey.slice(0, 8),
      prev: videoPrevKey.slice(0, 8), slots: out
    })
  }

  function recurate() {
    curatedThemes = Model.curate(themes, preferences, false, showHidden)
    transitionCollection()
  }

  function resetCollectionTransition() {
    collectionOut.stop()
    collectionIn.stop()
    collectionOpacity = 1
    collectionOffset = 0
  }

  function transitionCollection() {
    scrubQuick = true
    if (!opened || applying) { rebuild(false); return }
    collectionIn.stop()
    collectionOut.restart()
  }

  // The model is replaced only while the cards are invisible. Keep the gate
  // stationary and let the existing wallpaper transition handle a new theme.
  SequentialAnimation {
    id: collectionOut
    NumberAnimation { target: root; property: "collectionOpacity"; to: 0; duration: 90; easing.type: Easing.InQuad }
    ScriptAction {
      script: {
        root.rebuild(false, true)
        root.collectionOffset = root.sp(6)
        // rebuild queues centering first; reveal only after that settles.
        Qt.callLater(function() {
          if (root.opened && !root.applying && !collectionOut.running && root.collectionOpacity === 0)
            collectionIn.restart()
        })
      }
    }
  }
  ParallelAnimation {
    id: collectionIn
    NumberAnimation { target: root; property: "collectionOpacity"; to: 1; duration: 190; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "collectionOffset"; to: 0; duration: 190; easing.type: Easing.OutCubic }
  }

  function settleOpeningFavorites() {
    if (openingFavoritesSettled || !openingIndexReady || !preferencesReady) return false
    openingFavoritesSettled = true
    favoritesOnly = preferences.favorites.indexOf(currentTheme) !== -1
    return true
  }

  function toggleFavoritesOnly() {
    if (searching) return
    // A deliberate toggle wins over a late index/preferences response.
    openingFavoritesSettled = true
    favoritesOnly = !favoritesOnly
    recurate()
  }
  function toggleShowHidden() { showHidden = !showHidden; recurate() }

  Process {
    id: thumbsProc
    command: [root.scriptPath("thumbs.sh")]
    onExited: root.cacheGen += 1
  }
  // Derivatives land while thumbs.sh runs; tick so images that were missing retry.
  Timer { running: thumbsProc.running; interval: 2000; repeat: true; onTriggered: root.cacheGen += 1 }

  function loadIndex(raw, refresh) {
    if (!raw) return
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { console.warn("swatch: index parse failed:", e); return }
    var changed = raw !== loadedIndex
    loadedIndex = raw
    thumbsDir = String(parsed.thumbsDir || "")
    var w = Number(parsed.stageW), h = Number(parsed.stageH)
    if (w >= 320 && w <= 7680 && h >= 200 && h <= 4320) { stageW = Math.round(w); stageH = Math.round(h) }
    currentTheme = parsed.currentTheme || ""
    currentBackground = parsed.currentBackground || ""
    if (changed) themes = parsed.themes || []
    openingIndexReady = true
    settleOpeningFavorites()
    curatedThemes = Model.curate(themes, preferences, false, showHidden)
    rebuild(!refresh || !opened || !viewReady)
    stageBackground()
    if (!thumbsProc.running) thumbsProc.running = true
  }

  // Re-derive rows and, on first load per open, land on the current theme and
  // its current background so the first frame is the desktop you already have.
  function rebuild(landOnCurrent, transitioning) {
    if (!transitioning) resetCollectionTransition()
    rebuilding = true
    var keep = selected ? selected.name : ""
    var keepBackground = selectedBackground
    rows = Model.browse(curatedThemes, filterText, "all", favoritesOnly)
    var target = landOnCurrent && currentTheme ? currentTheme : keep
    var i = Model.indexOf(rows, target)
    if (i === -1) i = rows.length ? 0 : -1
    selectedIndex = i
    if (landOnCurrent) {
      var t = rows[i]
      var bi = Model.backgroundIndexOf(t, currentBackground)
      bgIndex = bi === -1 ? 0 : bi
    } else {
      var nextTheme = rows[i]
      var nextBackground = nextTheme && keep === nextTheme.name ? Model.backgroundIndexOf(nextTheme, keepBackground) : -1
      bgIndex = nextBackground === -1 ? 0 : nextBackground
    }
    Qt.callLater(function() {
      strip.forceLayout()
      bgStrip.forceLayout()
      if (selectedIndex >= 0) strip.positionViewAtIndex(selectedIndex, ListView.Center)
      if (!viewReady && bgIndex >= 0) bgStrip.positionViewAtIndex(bgIndex, ListView.Beginning)
      rebuilding = false
      stageBackground()
    })
  }

  // ---------------------------------------------------------------- navigation

  // Every move is classified here: which strip, which way, and whether it is a
  // deliberate press or one of a burst.
  function noteMove(axis, dir) {
    var now = Date.now()
    scrubRapid = (now - lastMoveAt) < 420
    lastMoveAt = now
    scrubAxis = axis
    scrubDir = dir
    scrubQuick = wiping
    disarmVideo()
  }

  // Any movement kills the clip immediately. Letting it run under a wipe would
  // put motion behind the mask that the wipe is trying to reveal past.
  //
  // The condition is spelled out rather than reading videoAvailable, and that
  // is not a style choice. This runs from onSelectedVideoKeyChanged, where the
  // key itself is already current but every binding *derived* from it — which
  // videoAvailable is — has not been re-evaluated yet. Reading it here gets
  // the previous value, so arming would be inverted: a background that has a
  // clip would see the old `false` and never start the timer, while one that
  // does not would see the old `true` and start a useless one. The raw
  // properties are all current.
  function disarmVideo() {
    previewsQuiet = false
    previewQuietDelay.stop()
    videoArmed = false
    videoArm.stop()
    if (selectedVideoKey === "" || applying || !opened) return
    // Already open in its own slot: arm on this frame, so the clip plays against
    // the outgoing one rather than after it. The debounce below exists to absorb
    // an open, and a preloaded clip is not paying for one — waiting out 120 ms
    // here is what let the still through between two animations.
    if (!scrubRapid && videoSlotReady(selectedVideoKey)) videoArmed = true
    else videoArm.restart()
  }

  Timer {
    id: videoArm
    interval: root.videoArmDelayMs
    onTriggered: {
      // This timer only fires once movement has stopped — every move restarts
      // it — so reaching here is the definition of the burst being over.
      // scrubRapid records that the *last* move was part of one, and nothing
      // else ever clears it, so leaving it set would keep videoSlotsLoadable
      // false for the rest of the session: clips would play on the background
      // you opened onto and never on one you scrubbed to.
      scrubRapid = false
      if (root.videoAvailable) root.videoArmed = true
      // Clearing the burst flag is what lets the slots open at all, so the
      // neighbours have to be restaged once movement has actually stopped —
      // otherwise nothing preloads until the *next* move and every landing
      // after a fast scrub pays for its own open.
      stageVideo()
    }
  }

  // Every route to a different background ends here, not just the arrow keys:
  // filtering and the landing on open change the selection without going
  // through noteMove, and each of those should re-start the dwell too.
  // Slots are restaged before arming, so videoSlotReady sees the new key's slot
  // and not the one it is replacing. stageVideo owns the hand-off bookkeeping.
  onSelectedVideoKeyChanged: {
    stageVideo()
    disarmVideo()
  }

  // The neighbours depend on bgIndex, not only on the live key: stepping between
  // two still-only backgrounds never changes selectedVideoKey, so without this
  // the preloads would go stale and the next clip you reach would pay for its
  // own open again.
  onBgIndexChanged: if (opened) stageVideo()

  // Also arm when availability itself flips — reopening on the background you
  // left on does not change selectedVideoKey, so the key handler never runs and
  // nothing would ever start the timer. That is the whole reason a clip played
  // on a fresh scrub but never on a reopen.
  onVideoAvailableChanged: disarmVideo()

  // The exit owns the screen from the moment Enter is pressed. A clip still
  // running under the defocus would be motion inside the blur, and the lift
  // resolves back to a still desktop that has no video in it.
  // The hold goes too: a clip pinned opaque over its successor would still be
  // on screen when the defocus starts, which is the one thing this handler is
  // here to prevent.
  onApplyingChanged: if (applying) {
    videoArmed = false
    videoArm.stop()
    videoHandoff = false
    videoHandoffHold.stop()
  }

  function beginSearch() {
    searching = true
    keys.forceActiveFocus()
  }

  function endSearch() {
    searching = false
    setFilter("")
  }

  function setFilter(text) { scrubQuick = true; filterText = text; rebuild(false) }

  // Single steps wrap around the ends; page jumps and Home/End clamp.
  function move(delta, wrap) {
    if (!rows.length) return
    var next = wrap ? Model.wrap(selectedIndex + delta, rows.length) : Model.clamp(selectedIndex + delta, rows.length)
    if (next === selectedIndex) return
    noteMove("theme", delta < 0 ? -1 : 1)
    selectedIndex = next
    bgIndex = 0
  }

  function jumpTo(index) {
    if (!rows.length) return
    var next = Model.clamp(index, rows.length)
    if (next === selectedIndex) return
    noteMove("theme", next < selectedIndex ? -1 : 1)
    selectedIndex = next
    bgIndex = 0
  }

  function moveBackground(delta) {
    var t = selected
    if (!t || !t.backgrounds || t.backgrounds.length < 2) return
    noteMove("bg", delta < 0 ? -1 : 1)
    bgIndex = (bgIndex + delta + t.backgrounds.length) % t.backgrounds.length
  }

  onSelectedIndexChanged: {
    if (!opened) return
    previewDebounce.restart()
    strip.currentIndex = selectedIndex
  }

  // ---------------------------------------------------------------- wallpaper

  onSelectedKeyChanged: if (opened) stageBackground()

  function stageBackground() {
    var want = [selectedKey]
    for (var d = 1; d <= 2; d++) {
      if (rows[selectedIndex + d]) want.push(Model.keyAt(rows[selectedIndex + d], 0))
      if (rows[selectedIndex - d]) want.push(Model.keyAt(rows[selectedIndex - d], 0))
    }
    var s = slots.slice(), age = slotAge.slice()
    tick += 1
    for (var w = 0; w < want.length; w++) {
      var path = want[w]
      if (!path) continue
      var at = s.indexOf(path)
      if (at === -1) {
        // Evict the slot that is neither wanted, nor on screen, nor recently
        // used. "On screen" has to be part of it: a slot keeps painting for up
        // to fadeDelayMs + fadeMs after it stops being the outgoing side of a
        // wipe, and reusing it inside that window swaps the picture under a
        // running fade — so you watch a theme two places away fade out, having
        // never selected it.
        var victim = -1, oldest = Infinity, i
        for (i = 0; i < s.length; i++) {
          if (want.indexOf(s[i]) !== -1) continue
          if (s[i] && (s[i] === shownKey || s[i] === wipeFrom)) continue
          if (age[i] < oldest) { oldest = age[i]; victim = i }
        }
        // Nothing spare: take the oldest unwanted one even if it is still
        // fading, rather than leaving the selected background unstaged.
        if (victim === -1) {
          oldest = Infinity
          for (i = 0; i < s.length; i++) {
            if (want.indexOf(s[i]) !== -1) continue
            if (age[i] < oldest) { oldest = age[i]; victim = i }
          }
        }
        if (victim === -1) break
        s[victim] = path
        at = victim
      }
      age[at] = tick + (want.length - w)
    }
    slots = s
    slotAge = age
    var slot = slots.indexOf(selectedKey)
    var item = slot === -1 ? null : wallpapers.itemAt(slot)
    if (item && item.ready) setShown(selectedKey)
  }

  function slotReady(key) { if (key && key === selectedKey) setShown(key) }

  // ------------------------------------------------------------------- clips

  // Assign the wanted clips into slots, preserving any slot that already holds
  // one: that preservation is the entire mechanism, since a kept slot keeps its
  // open player. Priority order matters only when there are more wanted clips
  // than slots, which ±1 plus the outgoing one cannot exceed.
  function stageVideo() {
    var t = selected
    var n = t && t.backgrounds ? t.backgrounds.length : 0
    // Derived from bgIndex here rather than read off selectedVideoKey, because
    // this is called from onBgIndexChanged too and the two handlers can run in
    // either order: reading the derived key would get the previous one, stage
    // the new background's *neighbours* around the old live clip, and evict the
    // very preload this exists to keep. Recomputing from raw properties makes
    // both entry points produce the same answer whichever runs first.
    var liveKey = Model.videoKeyAt(t, bgIndex)
    // Track the hand-off here as well, for the same reason: doing it in the key
    // handler meant a later stageVideo saw prev already advanced to the new key
    // and dropped the outgoing clip's player while it was still fading.
    if (liveKey !== videoLiveKey) {
      videoPrevKey = videoLiveKey
      videoLiveKey = liveKey
      // Only a real hand-off between two clips needs the hold. Arriving from a
      // still-only background has nothing to hold, and leaving for one should
      // let the outgoing clip go rather than pinning it over its successor.
      if (videoPrevKey !== "" && liveKey !== "") {
        videoHandoff = true
        videoHandoffHold.restart()
      } else {
        videoHandoff = false
        videoHandoffHold.stop()
      }
    }
    var want = []
    function add(k) { if (k && want.indexOf(k) === -1) want.push(k) }
    add(liveKey)
    add(videoPrevKey)
    if (n > 0) {
      add(Model.videoKeyAt(t, Model.wrap(bgIndex + 1, n)))
      add(Model.videoKeyAt(t, Model.wrap(bgIndex - 1, n)))
    }
    var s = videoSlots.slice(), i
    for (i = 0; i < s.length; i++) if (want.indexOf(s[i]) === -1) s[i] = ""
    for (var w = 0; w < want.length; w++) {
      if (s.indexOf(want[w]) !== -1) continue
      var free = s.indexOf("")
      if (free === -1) break
      s[free] = want[w]
    }
    videoSlots = s
  }

  Timer {
    id: videoHandoffHold
    interval: 320
    onTriggered: root.videoHandoff = false
  }

  // videoMoving is an OR across the slots. A root binding cannot depend on a
  // delegate's property, so each slot reports its own change in instead.
  function syncVideoMoving() {
    var any = false
    for (var i = 0; i < videoSlotCount; i++) {
      var l = videoStages.itemAt(i)
      if (l && l.motion) { any = true; break }
    }
    videoMoving = any
  }

  // Whether the clip for `key` is open and could start on the next frame. Reads
  // the raw slot array and the item directly, never a derived binding: this is
  // called from onSelectedVideoKeyChanged, where anything derived from the key
  // is still one step behind — the trap that cost three rounds of this feature.
  function videoSlotReady(key) {
    if (!key) return false
    for (var i = 0; i < videoSlotCount; i++) {
      if (videoSlots[i] !== key) continue
      var l = videoStages.itemAt(i)
      return !!(l && l.status === Loader.Ready && l.item && l.item.loaded)
    }
    return false
  }

  // The wipe needs both sides for its whole run, so the key being replaced is
  // held rather than left to the slot bindings to forget. The decision is taken
  // here, before shownKey moves: set `wiping` afterwards and the incoming slot
  // gets one unmasked frame, which is the whole effect given away.
  function setShown(key) {
    if (!key || key === shownKey) return
    var prev = shownKey
    wipeFrom = prev
    var moving = opened && viewReady && !applying && scrubArmed && !!prev
    var wipe = moving && !scrubQuick && !wiping
    if (wipe) {
      wipeT = 1 + wipeSpread
      wipeSweep.to = -wipeSpread
      wipeSweep.duration = wipeMs
      wiping = true
    }
    // A move arriving mid-wipe ends it rather than redirecting it: the sweep
    // would otherwise carry on revealing a frame it never started on.
    else if (wiping) { wipeRun.stop(); wiping = false; wipeFrom = "" }
    shownKey = key
    scrubArmed = true          // the first key of an open is a landing, not a move
    // Cleared only after the instant swap has been applied, so the very next
    // move animates normally.
    if (landing && viewReady) Qt.callLater(function() { root.landing = false })
    if (wipe) wipeRun.restart()
  }

  // ---------------------------------------------------------------- preview

  Timer { id: previewDebounce; interval: 120; onTriggered: root.previewSelected() }

  function previewSelected() {
    var t = selected
    if (!t || !livePreview || !opened || !viewReady) return
    applyPalette(t.colorsToml, t.shellToml)
  }

  function revertPreview() {
    var t = Model.findByName(themes, currentTheme)
    if (t) applyPalette(t.colorsToml, t.shellToml)
  }

  // The cheap half of omarchy-theme-set (what `shell applyTheme` IPC does),
  // without the subprocess. Bar, menus, notifications, and this overlay follow.
  function applyPalette(colors, shellToml) {
    Color.loadColors(colors || "")
    Color.loadShell(shellToml || "")
    Style.scheduleRefresh()
  }

  // ---------------------------------------------------------------- apply

  function apply() {
    var t = selected
    if (!t || applying) return
    resetCollectionTransition()
    applying = true
    chromeOpacity = 0
    if (pickDir) { finishPick(t.name); dismiss(); return }

    // argv only, through apply.sh — nothing is composed into a shell string.
    // The background is always named: apply.sh pins it so omarchy-theme-set
    // cannot cycle to the next one, which is not what the picker was showing.
    var bg = t.backgrounds && t.backgrounds.length ? selectedBackground : ""
    var args = [scriptPath("apply.sh"), t.name]
    if (bg) args.push(bg)
    applyTarget = bg
    Quickshell.execDetached(args)

    // Start the dip immediately; the swap gets to land inside the black.
    dipDown.restart()
    if (bg) { landPoll.restart(); landDeadline.restart() }
    else landed()   // no background to change; nothing to wait for
  }

  // omarchy-theme-bg-set writes the current-background symlink before it asks
  // the shell to swap, so the link resolving to our choice is the go signal.
  // Nothing else about the swap is observable from out here — the decode and
  // the shell's own reveal both finish unseen, which is exactly what the black
  // is for. We lift on the signal, not on a guess.
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"

  Timer { id: landPoll; interval: 100; repeat: true; onTriggered: if (!landProc.running) landProc.running = true }
  Timer { id: landDeadline; interval: 3000; onTriggered: root.landed() }

  Process {
    id: landProc
    command: ["readlink", "-f", "--", root.backgroundLink, root.applyTarget]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.checkLanded(text) }
  }

  // The last two lines are this run's pair: what the desktop's link points at,
  // and what we asked for, both canonicalised — so this compares destinations,
  // not how either path happened to be spelled.
  function checkLanded(text) {
    if (!applying) return
    var lines = String(text || "").trim().split("\n")
    if (lines.length < 2) return
    if (lines[lines.length - 2] === lines[lines.length - 1]) landed()
  }

  function landed() {
    landPoll.stop()
    landDeadline.stop()
    requestLift()
  }

  // The lift can be asked for before the dip has finished — a background that
  // was already current answers on the first poll — so it queues behind it.
  function requestLift() {
    if (!applying || liftUp.running) return
    if (dipDown.running) { liftPending = true; return }
    liftUp.restart()
  }

  function cancelExit() {
    landPoll.stop(); landDeadline.stop()
    dipDown.stop(); liftUp.stop()
    liftPending = false
  }

  // The phases have to be separated in time or they cancel each other out: run
  // the blackout and the defocus on the same curve and the picture is already
  // dark before the blur is worth looking at, which leaves a plain dip to black.
  // So the defocus leads going down, and on the way back the black clears first
  // and the picture sharpens long after it — asymmetric, because a fast collapse
  // and a slow arrival is what makes it read as a decision rather than a fade.
  ParallelAnimation {
    id: dipDown
    NumberAnimation { target: root; property: "exitBlur"; to: 1; duration: 300; easing.type: Easing.InQuad }
    NumberAnimation { target: wallpaperLayer; property: "scale"; to: 1.10; duration: 460; easing.type: Easing.OutQuad }
    SequentialAnimation {
      PauseAnimation { duration: 200 }   // 200 ms of visible defocus before any black
      NumberAnimation { target: root; property: "blackout"; to: 1; duration: 260; easing.type: Easing.InQuad }
    }
    onFinished: if (root.liftPending) { root.liftPending = false; liftUp.restart() }
  }

  SequentialAnimation {
    id: liftUp
    PauseAnimation { duration: root.holdFloorMs }
    ParallelAnimation {
      NumberAnimation { target: root; property: "blackout"; to: 0; duration: 300; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "exitBlur"; to: 0; duration: 640; easing.type: Easing.OutCubic }
      NumberAnimation { target: wallpaperLayer; property: "scale"; to: 1; duration: 640; easing.type: Easing.OutCubic }
    }
    // The cover is sharp again and identical to the desktop under it, so this
    // last crossfade is invisible — the matching image finally paying off.
    NumberAnimation { target: stage; property: "opacity"; to: 0; duration: 160 }
    onFinished: root.dismiss()
  }

  // ---------------------------------------------------------------- scrubbing

  // Themes get the bar, which is the transition rather than a decoration over
  // one: the crossfade behind it is delayed and short enough that the wallpaper
  // changes while the bar is on top of the seam. Backgrounds get a quiet push
  // along their own vertical axis and no bar — the smaller move, kept smaller.
  //
  // Constant velocity on purpose. Easing in and out is what makes a wipe read
  // as a fade, and the bar starts and ends off-screen so there is nothing to
  // ease into.
  // The threshold runs from above the map's range to below it, so the reveal
  // starts with nothing and finishes with everything. Constant velocity: an
  // eased wipe reads as a fade.
  SequentialAnimation {
    id: wipeRun
    NumberAnimation { id: wipeSweep; target: root; property: "wipeT"; easing.type: Easing.Linear }
    ScriptAction { script: { root.wiping = false; root.wipeFrom = "" } }
  }

  // Answer pick.sh: the selection (empty on cancel) and the done marker.
  function finishPick(name) {
    if (!pickDir) return
    Quickshell.execDetached([scriptPath("apply.sh"), "--pick", pickDir, name])
    pickDir = ""
  }

  // ---------------------------------------------------------------- images

  // Every image the overlay shows is a derivative in our cache. One that is
  // not there yet fails to load and is retried on the next cache tick; a load
  // that succeeded is never disturbed. Declarative, so the source binding
  // survives the retry.
  component CacheImage: Image {
    property string path: ""
    property int failedAt: -1
    source: path && failedAt !== root.cacheGen ? Util.fileUrl(path) : ""
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    smooth: true
    onPathChanged: failedAt = -1
    onStatusChanged: if (status === Image.Error) failedAt = root.cacheGen
  }

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "swatch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    readonly property real dpr: screen ? screen.devicePixelRatio : 1

    // Full screen, bar band included. This used to carve out the bar's band so
    // the real bar showed through and retinted live — Swatch sits on
    // WlrLayer.Overlay, above the bar's Top, so a hole was the only way to see
    // it. But the carve-out is only honest when the bar paints that whole band,
    // and nothing Swatch can read says whether it does: shell.bar exposes
    // position, size, transparent and hidden, not what is actually painted. A
    // bar that fills its window only partly — a floating pill in a transparent
    // band, say — turned the rest of the band into a hole onto the wallpaper
    // being left, showing the old theme hard against the candidate's.
    //
    // So the wallpaper now runs to every edge and no bar is previewed. That
    // loses the live retint, which was a real thing to give up; it buys a stage
    // with no geometry that depends on another plugin's internals.
    Item {
      id: stage
      anchors.fill: parent
      clip: true

      // Only live during the exit: a layer on a screen-size item costs a render
      // target, and there is nothing to defocus while you are still choosing.
      layer.enabled: root.applying
      layer.effect: MultiEffect {
        blurEnabled: true
        blur: root.exitBlur
        // Proportional, not constant: a blur radius is in pixels, so the same
        // number is a far weaker effect on a large screen than on a small one.
        blurMax: Math.min(64, Math.max(28, Math.round(stage.width * 0.035)))
      }

      Rectangle { anchors.fill: parent; color: root.bg }

      // Screen geometry, which the stage now also has. PreserveAspectCrop fits
      // the image to whatever rect it is handed, so this has to be the same
      // rect the desktop's own wallpaper is fitted to or the preview frames
      // every wallpaper slightly differently from the thing it is previewing —
      // and the hand-off at the end of the exit snaps. Kept explicit rather
      // than anchored to the stage so that stays true if the stage is ever
      // inset again.
      Item {
        id: wallpaperLayer
        width: panel.width
        height: panel.height

        // The map. A linear ramp makes the threshold sweep read as a straight
        // edge travelling across the screen; a radial one makes it an iris. It
        // is never drawn — MultiEffect samples it as a texture.
        //
        // The ramp has to be in ALPHA, not in grey: MultiEffect thresholds the
        // mask's alpha channel and ignores its colour. A black-to-white ramp is
        // opaque end to end, so the whole image flips the moment the threshold
        // crosses it — which looks like nothing happening. White throughout,
        // transparent to opaque.
        Item {
          id: wipeMask
          anchors.fill: parent
          visible: false
          layer.enabled: true

          Rectangle {
            anchors.fill: parent
            visible: root.wipeMap === "gradient"
            // Turns with the axis you pressed: across for themes, down the
            // screen for backgrounds. Position 0 is left, or top.
            gradient: Gradient {
              orientation: root.wipingBg ? Gradient.Vertical : Gradient.Horizontal
              GradientStop { position: 0.0; color: root.scrubDir > 0 ? "#00ffffff" : "#ffffffff" }
              GradientStop { position: 1.0; color: root.scrubDir > 0 ? "#ffffffff" : "#00ffffff" }
            }
          }

          Shape {
            anchors.fill: parent
            visible: root.wipeMap === "iris"
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              strokeColor: "transparent"
              fillGradient: RadialGradient {
                centerX: wipeMask.width / 2; centerY: wipeMask.height * 0.82
                centerRadius: Math.max(wipeMask.width, wipeMask.height) * 0.95
                focalX: wipeMask.width / 2; focalY: wipeMask.height * 0.82
                GradientStop { position: 0.0; color: "#ffffffff" }
                GradientStop { position: 1.0; color: "#00ffffff" }
              }
              startX: 0; startY: 0
              PathLine { x: wipeMask.width; y: 0 }
              PathLine { x: wipeMask.width; y: wipeMask.height }
              PathLine { x: 0; y: wipeMask.height }
              PathLine { x: 0; y: 0 }
            }
          }
        }

        Repeater {
          id: wallpapers
          model: root.slotCount
          Item {
            id: slotItem
            required property int index
            readonly property string key: root.slots[index]
            readonly property bool fullReady: stageImg.status === Image.Ready
            readonly property bool ready: stageImg.status === Image.Ready || softImg.status === Image.Ready
            readonly property bool incoming: key && key === root.shownKey
            readonly property bool outgoing: root.wiping && key && key === root.wipeFrom
            anchors.fill: parent
            // During a wipe both sides are opaque and the mask does the work;
            // otherwise this is the plain crossfade it always was.
            z: incoming ? 1 : 0
            opacity: incoming || outgoing ? 1 : 0
            // Not while landing. The first show of an open is arriving at the
            // desktop you already have, not moving between two candidates, and
            // the slot holding the theme you left on last time is still opaque.
            // Animating that hand-off holds the old wallpaper at full strength
            // for fadeDelayMs (170 ms on the theme axis) before it even starts
            // to fade — which reads as the picker opening on the wrong theme
            // and then correcting itself.
            Behavior on opacity {
              enabled: !root.wiping && !root.landing
              SequentialAnimation {
                PauseAnimation { duration: root.fadeDelayMs }
                NumberAnimation { duration: root.fadeMs; easing.type: Easing.InOutQuad }
              }
            }
            layer.enabled: root.wiping && incoming
            layer.effect: MultiEffect {
              maskEnabled: true
              maskSource: wipeMask
              maskThresholdMin: root.wipeT
              maskSpreadAtMin: root.wipeSpread
            }
            onReadyChanged: if (ready) root.slotReady(key)
            // The filmstrip thumb stands in, soft, until the stage copy exists.
            CacheImage {
              id: softImg
              anchors.fill: parent
              path: Model.thumbPath(root.thumbsDir, slotItem.key)
              sourceSize: Qt.size(640, 360)
              visible: stageImg.status !== Image.Ready
            }
            CacheImage {
              id: stageImg
              anchors.fill: parent
              path: Model.stagePath(root.thumbsDir, slotItem.key, root.stageW, root.stageH)
              sourceSize: Qt.size(root.stageW, root.stageH)
              cache: false
            }
          }
        }

        // The animated alternative, sitting over the still it belongs to.
        //
        // It fades rather than cuts only because the clip may not open on the
        // frame the still shows: where it does — an ARRIVE clip held on its
        // final frame — the cross-fade is a no-op between identical pictures,
        // which is the intended cheap case. The wipe and the exit blackout
        // already cover the seams at either end of a scrub, so nothing here
        // needs to coordinate with them beyond getting out of the way.
        //
        // One slot per clip (see videoSlots): the live one plus its neighbours
        // and whichever is still fading out. Only the live slot ever plays or is
        // seen; the rest are open and paused, which is the whole point of them.
        // On a machine without qt6-multimedia every one of these Loaders lands
        // in Loader.Error with a null `item` — every guard below is then false
        // and the picker shows stills.
        Repeater {
          id: videoStages
          model: root.videoSlotCount
          Loader {
            id: videoSlot
            required property int index
            readonly property string key: root.videoSlots[index]
            readonly property bool live: key !== "" && key === root.selectedVideoKey
            readonly property bool motion: status === Loader.Ready && item
              && item.motionPlaying && live
            // The clip handing off. It has to keep the screen, opaque, until the
            // incoming one has it: two clips fading past each other at 0.5 leave
            // (1-0.5)*(1-0.5) = 25% of the still showing through at the midpoint,
            // which was the flash this whole change set out to remove and which a
            // dual fade cannot avoid — alpha never sums back to opaque. The still
            // slots have always known this: during a wipe both sides are opaque
            // and the mask does the work.
            readonly property bool outgoing: key !== "" && !live
              && key === root.videoPrevKey && root.videoHandoff
            anchors.fill: parent
            // The live clip paints over the one handing off to it, whichever
            // slot indices the two happen to occupy.
            z: live ? 3 : 2
            active: root.opened && key !== ""
            asynchronous: true
            source: "VideoStage.qml"
            opacity: status !== Loader.Ready || !item ? 0
              : live ? (item.showing ? 1 : 0)
                     : (outgoing && item.framed ? 1 : 0)
            visible: opacity > 0
            // Revealed by the same sweep as the still it belongs to, rather than
            // dissolved in after it. This is what the design note always claimed
            // happened — "the wipe masks a clip's start exactly as it masks a
            // still's" — and did not, because this layer was a sibling of the
            // slots with its own fade instead of a participant in theirs.
            layer.enabled: root.wiping && live
            layer.effect: MultiEffect {
              maskEnabled: true
              maskSource: wipeMask
              maskThresholdMin: root.wipeT
              maskSpreadAtMin: root.wipeSpread
            }
            // Short on purpose. This has to land inside the wipe that revealed
            // the background, not resolve lazily after it — otherwise the clip
            // arrives as its own separate event. It is also the seam the design
            // note warns about: on a DEPART clip it is a no-op between identical
            // frames, but on an ARRIVE clip it dissolves two different views of
            // one scene, and a long dissolve there ghosts anything moving.
            //
            // Only off the wipe's path: during a wipe the mask is the transition
            // and both sides are held opaque, so fading here would reintroduce
            // the bleed the mask exists to avoid. The outgoing slot never fades
            // either — it cuts once videoHandoff lapses, by which time the
            // incoming clip is opaque on top of it and the cut cannot be seen.
            Behavior on opacity {
              enabled: !root.wiping && videoSlot.live
              NumberAnimation { duration: 140; easing.type: Easing.InOutQuad }
            }
            onMotionChanged: root.syncVideoMoving()
            onLoaded: {
              item.source = Qt.binding(function() {
                return Util.fileUrl(Model.videoPath(root.thumbsDir, videoSlot.key))
              })
              item.active = Qt.binding(function() {
                return root.videoSlotsLoadable && videoSlot.key !== ""
              })
              item.playing = Qt.binding(function() {
                return videoSlot.live && root.videoArmed && root.videoAvailable
              })
              // Only the live clip's failure should disarm: a neighbour that
              // cannot open is a preload we simply do not get.
              item.failed.connect(function() { if (videoSlot.live) root.videoArmed = false })
            }
          }
        }
      }

      // The filter matched nothing. Dim the wallpaper rather than leaving the
      // last match sitting there full-strength looking like a result — the
      // stage is showing a theme that is no longer in the list.
      Rectangle {
        anchors.fill: parent
        color: root.bg
        opacity: root.rows.length === 0 && root.themes.length > 0 ? 0.72 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
      }

      // Scrims: a light lid at the top for the title, a heavier one at the
      // bottom for the strip. Both in the candidate's own background colour.
      Rectangle {
        opacity: root.chromeOpacity
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: Math.round(parent.height * 0.32)
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(root.bg, 0.55) }
          GradientStop { position: 1.0; color: Util.alpha(root.bg, 0.0) }
        }
      }
      Rectangle {
        opacity: root.chromeOpacity
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: Math.round(parent.height * 0.42)
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(root.bg, 0.0) }
          GradientStop { position: 1.0; color: Util.alpha(root.bg, 0.94) }
        }
      }

      MouseArea { anchors.fill: parent; enabled: !root.applying; onClicked: root.dismiss() }

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          event.accepted = true
          if (root.applying) return          // committed; the exit is running
          var k = event.key
          if (!root.viewReady) { if (k === Qt.Key_Escape) root.dismiss(); return }
          if (event.modifiers === Qt.ControlModifier && k === Qt.Key_F) root.toggleFavoritesOnly()
          else if (!root.searching && event.modifiers === Qt.NoModifier && k === Qt.Key_F) root.toggleFavorite()
          else if ((event.modifiers & Qt.ControlModifier) && k === Qt.Key_H) root.toggleShowHidden()
          else if ((event.modifiers & Qt.ControlModifier) && k === Qt.Key_Z) root.restoreLastHidden()
          else if (k === Qt.Key_Delete && !root.searching) root.toggleBackgroundHidden()
          else if (k === Qt.Key_Escape) { if (root.searching) root.endSearch(); else root.dismiss() }
          else if (!root.searching && event.modifiers === Qt.NoModifier && (k === Qt.Key_Space || k === Qt.Key_Slash)) root.beginSearch()
          else if (!root.searching && event.modifiers === Qt.NoModifier && k === Qt.Key_H) root.move(-1, true)
          else if (!root.searching && event.modifiers === Qt.NoModifier && k === Qt.Key_L) root.move(1, true)
          else if (!root.searching && event.modifiers === Qt.NoModifier && k === Qt.Key_K) root.moveBackground(-1)
          else if (!root.searching && event.modifiers === Qt.NoModifier && k === Qt.Key_J) root.moveBackground(1)
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.apply()
          else if (k === Qt.Key_Left) root.move(-1, true)
          else if (k === Qt.Key_Right) root.move(1, true)
          else if (k === Qt.Key_Up) root.moveBackground(-1)
          else if (k === Qt.Key_Down) root.moveBackground(1)
          else if (k === Qt.Key_PageUp) root.move(-5, false)
          else if (k === Qt.Key_PageDown) root.move(5, false)
          else if (k === Qt.Key_Home) root.jumpTo(0)
          else if (k === Qt.Key_End) root.jumpTo(root.rows.length - 1)
          else if (root.searching && Util.editsFilter(event, root.filterText)) root.setFilter(Util.editedFilter(event, root.filterText))
          else if (root.searching && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                   && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier))
            root.setFilter(root.filterText + event.text)
          else event.accepted = false
        }
      }

      // ---- title block
      Column {
        id: titleBlock
        opacity: root.chromeOpacity
        anchors { left: parent.left; top: parent.top; leftMargin: root.sp(56); topMargin: root.sp(52) }
        spacing: root.sp(12)
        visible: !!root.selected

        Row {
          spacing: root.sp(10)
          Text {
            id: titleName
            text: root.selected ? root.selected.name : ""
            textFormat: Text.PlainText
            color: root.selected && root.selected.mode === "light" ? root.fg : "#ffffff"
            font.family: Style.fontFamily
            font.pixelSize: Math.round(root.sp(44) * Math.sqrt(root.k))
            font.weight: Font.Bold
            font.letterSpacing: -1
            style: Text.Raised
            styleColor: Util.alpha(root.bg, 0.6)
          }
          Text {
            text: "★"
            anchors.verticalCenter: parent.verticalCenter
            color: titleName.color
            font.family: Style.fontFamily
            font.pixelSize: root.sp(28)
            opacity: root.selected && root.selected.favorite ? 1 : 0
            scale: opacity > 0 ? 1 : 0.65
            Behavior on opacity { NumberAnimation { duration: 150 } }
            Behavior on scale { enabled: root.viewReady && !root.rebuilding; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          }
        }
        Row {
          Repeater {
            model: root.ansi
            Rectangle { required property var modelData; width: root.paletteSwatchW; height: Math.round(root.sp(10) * Math.sqrt(root.k)); color: modelData }
          }
        }
        // Backgrounds: a vertical filmstrip under its own playhead. The theme
        // strip's gate would crowd a card this size, so here the line stays and
        // the border does the marking. Only when there is something to choose.
        Item {
          id: bgArea
          visible: !!root.selected && (root.selected.backgrounds.length > 1 || root.selectedHiddenCount > 0)
          width: root.bgThumbW + root.sp(120)
          height: root.bgStripH
          readonly property real selectedCenter: root.bgThumbH / 2
          // The theme card's own lean, taken off this card's height so the two
          // strips' edges come out parallel. A stack does not need the shape
          // turned to suit its axis — under one shear the tops and bottoms stay
          // level and only the sides move, whichever way the strip runs.
          readonly property int skew: Math.round(root.bgThumbH * root.rake)

          ListView {
            id: bgStrip
            width: root.bgThumbW
            height: root.bgStripH
            orientation: ListView.Vertical
            model: root.selected ? root.selected.backgrounds : []
            // A quiet end marker, part of the scrollable content. It is not
            // a selectable wallpaper or a control; Ctrl+H reveals hidden items.
            footer: Item {
              width: bgStrip.width
              height: root.hiddenFooterHeight
              visible: height > 0
              Accessible.role: Accessible.StaticText
              Accessible.name: root.selectedHiddenCount + " hidden backgrounds"
              Row {
                anchors.centerIn: parent
                spacing: root.sp(6)
                opacity: 0.4
                HiddenEye { width: root.sp(14); height: root.sp(14); anchors.verticalCenter: parent.verticalCenter }
                Text {
                  text: root.selectedHiddenCount + " hidden · Ctrl+H to show"
                  color: root.fg
                  font.family: Style.fontFamily
                  font.pixelSize: root.fz.caption
                }
              }
            }
            spacing: root.sp(8)
            clip: true
            currentIndex: root.bgIndex
            // A fixed top slot: the strip moves through it, while the label
            // and marker stay still. Strict range also holds the last item at
            // the top instead of pushing it down to fill the viewport.
            highlightRangeMode: ListView.StrictlyEnforceRange
            preferredHighlightBegin: 0
            preferredHighlightEnd: root.bgThumbH
            highlightMoveDuration: root.viewReady && !root.rebuilding ? 140 : 0
            cacheBuffer: root.bgThumbH * 8
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds
            onCurrentIndexChanged: {
              if (!root.rebuilding && root.viewReady && currentIndex >= 0 && currentIndex !== root.bgIndex) root.bgIndex = currentIndex
            }

            delegate: Item {
              id: bgCell
              required property int index
              required property var modelData
              readonly property bool sel: index === root.bgIndex
              readonly property bool hidden: !!root.selected && Model.isHidden(root.preferences, root.selected.name, modelData)
              z: sel ? 1 : 0
              readonly property string key: root.selected && root.selected.bgKeys ? (root.selected.bgKeys[index] || "") : ""
              width: root.bgThumbW
              height: root.bgThumbH

              Item {
                anchors.fill: parent
                opacity: bgCell.sel ? 1 : bgCell.hidden ? 0.3 : 0.72
                // The selected card fills the reserved frame; neighbors sit
                // back so enlargement cannot clip at the first or last row.
                transformOrigin: Item.Center
                scale: bgCell.sel ? 1.0 : 0.88
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on scale { enabled: root.viewReady && !root.rebuilding; NumberAnimation { duration: 120 } }

                Item {
                  anchors.fill: parent
                  layer.enabled: true
                  layer.smooth: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: bgCardMask
                    maskThresholdMin: 0.3
                    maskSpreadAtMin: 0.3
                  }
                  Rectangle {
                    anchors.fill: parent
                    color: Util.alpha(root.bg, 0.6)
                  }
                  CacheImage {
                    anchors.fill: parent
                    path: Model.thumbPath(root.thumbsDir, bgCell.key)
                    cache: true
                    sourceSize: Qt.size(Math.round(width * panel.dpr), Math.round(height * panel.dpr))
                    visible: status === Image.Ready
                  }
                }
                // The border is the marking here — a card this size has no gate
                // around it — so it is stroked outside the mask, where the soft
                // edge cannot eat half the accent.
                Shape {
                  anchors.fill: parent
                  antialiasing: true
                  preferredRendererType: Shape.CurveRenderer
                  ShapePath {
                    fillColor: "transparent"
                    strokeWidth: bgCell.sel ? root.sp(2) : 1
                    strokeColor: bgCell.sel ? root.accent : Util.alpha(root.fg, 0.22)
                    startX: bgArea.skew; startY: 0
                    PathLine { x: bgCell.width; y: 0 }
                    PathLine { x: bgCell.width - bgArea.skew; y: bgCell.height }
                    PathLine { x: 0; y: bgCell.height }
                    PathLine { x: bgArea.skew; y: 0 }
                  }
                }
              }
              Rectangle {
                anchors { right: parent.right; bottom: parent.bottom; margins: root.sp(8) }
                visible: bgCell.hidden
                width: root.sp(28)
                height: root.sp(28)
                radius: root.sp(4)
                color: Util.alpha(root.bg, 0.92)
                HiddenEye { anchors.centerIn: parent }

              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.bgIndex = bgCell.index
                onDoubleClicked: { root.bgIndex = bgCell.index; root.apply() }
              }
            }
          }

          // No painted edge fades: the wallpaper is visible through empty
          // space, so a theme-colored overlay would leave rectangular patches.
          // The playhead leans with the cards it marks. Under one shear a
          // vertical line is not vertical any more, and a straight one beside a
          // leaning card is the thing that would read as pointing elsewhere.
          Shape {
            id: playhead
            x: -root.sp(10)
            y: Math.round(bgArea.selectedCenter - height / 2)
            width: Math.round(height * root.rake)
            height: root.bgThumbH + root.sp(8)
            antialiasing: true
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              fillColor: "transparent"
              strokeColor: root.fg
              strokeWidth: root.sp(2)
              capStyle: ShapePath.FlatCap
              startX: playhead.width; startY: 0
              PathLine { x: 0; y: playhead.height }
            }
          }

          Column {
            anchors { left: bgStrip.right; leftMargin: root.sp(14) }
            y: Math.round(bgArea.selectedCenter - height / 2)
            spacing: root.sp(4)
            Text { text: root.selected ? (root.bgIndex + 1) + " / " + root.selected.backgrounds.length : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: root.fz.title; font.weight: Font.DemiBold }
            Text { text: "backgrounds"; color: root.fg; opacity: 0.7; font.family: Style.fontFamily; font.pixelSize: root.fz.caption }
            Text { text: "↑ ↓"; color: root.fg; opacity: 0.5; font.family: Style.fontFamily; font.pixelSize: root.fz.caption }
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            onWheel: function(w) { root.moveBackground(w.angleDelta.y < 0 ? 1 : -1); w.accepted = true }
          }
        }
      }

      // ---- samples: the palette doing its actual job
      // Two complementary clips reveal actual palette changes, including the
      // translucent grounds. Neither palette is painted under the other.
      Item {
        id: previews
        property var currentTheme: null
        property var previousTheme: null
        property real progress: 1
        property int direction: 1
        property int durationMs: 240
        property real travel: 0
        readonly property real seam: direction > 0 ? width * (1 - progress) : width * progress
        readonly property real drift: direction * travel * Math.pow(1 - progress, 3)
        width: incomingSamples.width + root.sp(32)
        height: incomingSamples.implicitHeight + root.sp(4)
        anchors { right: parent.right; top: parent.top; rightMargin: root.sp(40); topMargin: root.sp(52) }
        property real readingOpacity: root.previewsQuiet && !previewHover.hovered ? 0.32 : 1
        Behavior on readingOpacity {
          NumberAnimation { duration: root.previewsQuiet && !previewHover.hovered ? 500 : 120; easing.type: Easing.OutQuad }
        }
        opacity: root.chromeOpacity * readingOpacity
        HoverHandler { id: previewHover }
        visible: !!root.selected

        function reset() {
          paletteSweep.stop()
          currentTheme = root.selected
          previousTheme = null
          progress = 1
        }

        function updateTheme() {
          var next = root.selected
          if (next === currentTheme) return
          var animate = root.opened && !root.applying && !root.landing
            && currentTheme && next && currentTheme.name !== next.name
          paletteSweep.stop()
          previousTheme = currentTheme
          currentTheme = next
          if (!animate) { progress = 1; previousTheme = null; return }
          direction = root.scrubDir
          durationMs = root.scrubRapid || root.scrubQuick ? 140 : 240
          travel = root.sp(root.scrubRapid || root.scrubQuick ? 4 : 12)
          progress = 0
          paletteSweep.restart()
        }

        Connections {
          target: root
          // Let selection-derived bindings settle before taking the palette.
          function onSelectedChanged() { Qt.callLater(previews.updateTheme) }
          function onOpenedChanged() { previews.reset() }
          function onApplyingChanged() { if (root.applying) previews.reset() }
        }

        NumberAnimation {
          id: paletteSweep
          target: previews
          property: "progress"
          from: 0; to: 1
          duration: previews.durationMs
          easing.type: Easing.Linear
          onFinished: previews.previousTheme = null
        }

        Item {
          x: previews.direction > 0 ? previews.seam : 0
          width: previews.direction > 0 ? previews.width - previews.seam : previews.seam
          height: parent.height
          clip: true
          SamplePanels {
            id: incomingSamples
            x: root.sp(16) - parent.x
            y: 1
            theme: previews.currentTheme
            drift: previews.drift
          }
        }
        Item {
          x: previews.direction > 0 ? 0 : previews.seam
          width: previews.direction > 0 ? previews.seam : previews.width - previews.seam
          height: parent.height
          clip: true
          visible: previews.progress < 1
          SamplePanels {
            x: root.sp(16) - parent.x
            y: 1
            theme: previews.previousTheme
            drift: previews.drift
          }
        }
      }

      component SamplePanels: Column {
        id: samples
        property var theme: null
        property real drift: 0
        readonly property var ansi: Model.ansi(theme)
        readonly property color bg: theme ? theme.colors.background || "#101315" : "#101315"
        readonly property color fg: theme ? theme.colors.foreground || "#cacccc" : "#cacccc"
        readonly property color accent: theme ? theme.colors.accent || fg : fg
        // Two panels, one shear. Each leans by the rake taken off its own
        // height — so their edges are parallel to each other and to the cards —
        // and each is pushed right by however much shear has accumulated below
        // it, so the two left edges make one continuous line down the stack
        // instead of sawtoothing back out at the gap. The sizes come off the
        // panels' content and not their laid-out heights: a height that
        // included its own skew would define the skew in terms of itself.
        readonly property int gap: root.sp(10)
        readonly property int padding: root.sp(10)
        // Width between the slanted edges. Add each panel's own skew to its
        // bounding box so the taller code sample doesn't look narrower.
        readonly property int panelW: Math.ceil(Math.max(sample.implicitWidth, code.implicitWidth)) + padding * 2
        readonly property int hTerm: sample.implicitHeight + padding * 2
        readonly property int hCode: code.implicitHeight + padding * 2
        readonly property int skewTerm: Math.round(hTerm * root.rake)
        readonly property int skewCode: Math.round(hCode * root.rake)
        readonly property int xTerm: Math.round((gap + hCode) * root.rake)
        width: panelW + skewTerm + xTerm
        spacing: gap
        visible: !!samples.theme

      Item {
        id: termPanel
        transform: Translate { x: samples.drift }
        x: samples.xTerm
        width: samples.panelW + samples.skewTerm
        height: samples.hTerm
        visible: !!samples.theme

        // Filled and stroked as one path. No mask: the panel's ground is a flat
        // colour a Shape can lay down itself, and the text is inset clear of
        // both cut corners, so a layer per panel would buy nothing.
        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: Util.alpha(samples.bg, 0.88)
            strokeColor: samples.accent
            strokeWidth: 1
            startX: samples.skewTerm; startY: 0
            PathLine { x: termPanel.width; y: 0 }
            PathLine { x: termPanel.width - samples.skewTerm; y: termPanel.height }
            PathLine { x: 0; y: termPanel.height }
            PathLine { x: samples.skewTerm; y: 0 }
          }
        }

        Column {
          id: sample
          anchors { left: parent.left; top: parent.top; leftMargin: samples.padding + samples.skewTerm; topMargin: samples.padding }
          spacing: 0
          readonly property int px: root.samplePx
          readonly property string ff: Style.fontFamily
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: samples.fg
            text: '<span style="color:' + samples.accent + '">❯</span> <span style="color:' + samples.ansi[4] + '">~/dev/omarchy</span> <span style="color:' + samples.ansi[2] + '"> main</span>' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: samples.fg
            text: '<span style="color:' + samples.accent + '">❯</span> ls' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: samples.fg
            text: '<b><span style="color:' + samples.ansi[4] + '">bin/</span>&nbsp;&nbsp;<span style="color:' + samples.ansi[4] + '">shell/</span>&nbsp;&nbsp;<span style="color:' + samples.ansi[4] + '">themes/</span></b>&nbsp;&nbsp;README.md&nbsp;&nbsp;<span style="color:' + samples.ansi[2] + '">install.sh</span>' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: samples.fg
            text: '<span style="color:' + samples.accent + '">❯</span> git status --short' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: samples.fg
            text: '<span style="color:' + samples.ansi[1] + '">&nbsp;M</span> shell/plugins/swatch/Swatch.qml' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: samples.fg
            text: '<span style="color:' + samples.ansi[0] + '">??</span> index.sh <span style="color:' + samples.ansi[3] + '">→</span> <span style="color:' + samples.ansi[5] + '">thumbs.sh</span>' }
          Row { spacing: root.sp(6)
            Text { id: prompt; text: "❯"; color: samples.accent; font.family: sample.ff; font.pixelSize: sample.px }
            Rectangle { width: prompt.implicitWidth; height: prompt.implicitHeight; color: samples.accent; anchors.verticalCenter: parent.verticalCenter } }
        }
      }

      // A small Rails model, in homage to where Omarchy comes from.
      Item {
        id: codePanel
        transform: Translate { x: samples.drift * 0.55 }
        x: 0
        width: samples.panelW + samples.skewCode
        height: samples.hCode

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: Util.alpha(samples.bg, 0.88)
            strokeColor: Util.alpha(samples.fg, 0.35)
            strokeWidth: 1
            startX: samples.skewCode; startY: 0
            PathLine { x: codePanel.width; y: 0 }
            PathLine { x: codePanel.width - samples.skewCode; y: codePanel.height }
            PathLine { x: 0; y: codePanel.height }
            PathLine { x: samples.skewCode; y: 0 }
          }
        }

        Column {
          id: code
          anchors { left: parent.left; top: parent.top; leftMargin: samples.padding + samples.skewCode; topMargin: samples.padding }
          spacing: 0
          readonly property int px: root.samplePx
          readonly property string ff: Style.fontFamily
          readonly property string kw: samples.accent
          readonly property string kon: samples.ansi[1]
          readonly property string sym: samples.ansi[3]
          readonly property string str: samples.ansi[2]
          readonly property string meth: samples.ansi[4]
          readonly property string cm: Util.alpha(samples.fg, 0.5)
          readonly property string ind: "&nbsp;&nbsp;"

          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: '<span style="color:' + code.cm + '"># app/models/theme.rb</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: '<span style="color:' + code.kw + '">class</span> <span style="color:' + code.kon + '">Theme</span> &lt; <span style="color:' + code.kon + '">ApplicationRecord</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + '<span style="color:' + code.meth + '">belongs_to</span> <span style="color:' + code.sym + '">:author</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + '<span style="color:' + code.meth + '">has_many</span> <span style="color:' + code.sym + '">:backgrounds</span>, <span style="color:' + code.sym + '">dependent:</span> <span style="color:' + code.sym + '">:destroy</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + '<span style="color:' + code.meth + '">validates</span> <span style="color:' + code.sym + '">:name</span>, <span style="color:' + code.sym + '">presence:</span> <span style="color:' + code.kw + '">true</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + '<span style="color:' + code.meth + '">scope</span> <span style="color:' + code.sym + '">:dark</span>, -&gt; { <span style="color:' + code.meth + '">where</span>(<span style="color:' + code.sym + '">mode:</span> <span style="color:' + code.str + '">"dark"</span>) }' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg; text: "&nbsp;" }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + '<span style="color:' + code.kw + '">def</span> <span style="color:' + code.meth + '">apply!</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + code.ind + '<span style="color:' + code.kon + '">Shell</span>.<span style="color:' + code.meth + '">retint</span>(colors)' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + code.ind + 'backgrounds.<span style="color:' + code.meth + '">first</span>&amp;.<span style="color:' + code.meth + '">set!</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: code.ind + '<span style="color:' + code.kw + '">end</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: samples.fg
            text: '<span style="color:' + code.kw + '">end</span>' }
        }
      }
      }

      component HiddenEye: Item {
        id: hiddenEye
        property color ink: root.fg
        width: root.sp(18)
        height: root.sp(18)
        Shape {
          width: 24
          height: 24
          transform: Scale { xScale: hiddenEye.width / 24; yScale: hiddenEye.height / 24 }
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            strokeColor: hiddenEye.ink
            strokeWidth: 1.8
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: "M 2 12 C 6 3 18 3 22 12 C 18 21 6 21 2 12 Z M 15 12 A 3 3 0 1 1 9 12 A 3 3 0 1 1 15 12 M 3 3 L 21 21" }
          }
        }
      }

      // Scope lives inside the search field; theme stars only mark favorites.
      Rectangle {
        id: searchField
        width: root.sp(340)
        height: root.sp(36)
        opacity: root.chromeOpacity
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: root.sp(52) }
        radius: root.sp(3)
        color: Util.alpha(root.bg, root.searching ? 0.86 : 0.55)
        border.width: 1
        border.color: root.searching ? Util.alpha(root.accent, 0.8) : Util.alpha(root.fg, 0.16)
        Text {
          anchors { left: parent.left; right: searchHint.left; verticalCenter: parent.verticalCenter; leftMargin: root.sp(12); rightMargin: root.sp(12) }
          text: root.searching ? root.filterText + "▍" : "Search themes"
          textFormat: Text.PlainText
          elide: Text.ElideLeft
          color: root.fg
          opacity: root.searching ? 1 : 0.55
          font.family: Style.fontFamily
          font.pixelSize: root.fz.body
        }
        Text {
          id: searchHint
          anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: root.sp(12) }
          text: root.searching ? (root.filterText ? "All themes · Esc" : "Esc") : root.favoritesOnly ? "Favorites · Ctrl+F" : "/"
          color: root.fg
          opacity: 0.45
          font.family: Style.fontFamily
          font.pixelSize: root.fz.caption
        }
        MouseArea { anchors.fill: parent; onClicked: root.beginSearch() }
      }

      // Errors and constraints surface briefly; ordinary curation is visual.
      Text {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: stripArea.top; bottomMargin: root.sp(12) }
        text: root.curationMessage
        visible: text.length > 0
        opacity: root.chromeOpacity
        color: root.fg
        font.family: Style.fontFamily
        font.pixelSize: root.fz.caption
        style: Text.Outline
        styleColor: root.bg
      }

      // ---- empty state: the filter ate everything
      Column {
        opacity: root.chromeOpacity
        anchors.centerIn: parent
        spacing: root.sp(10)
        visible: root.rows.length === 0 && root.themes.length > 0

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.filterText ? "No themes match “" + root.filterText + "”" : root.favoritesOnly ? "No favorite themes yet" : "No themes available"
          textFormat: Text.PlainText
          color: root.fg
          font.family: Style.fontFamily
          font.pixelSize: Math.round(root.fz.heading * root.k)
          font.weight: Font.DemiBold
          style: Text.Outline
          styleColor: Util.alpha(root.bg, 0.7)
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.filterText ? "Esc clears search and returns to navigation" : root.favoritesOnly ? "Turn off Favorites to browse and star a theme" : "Install a theme to get started"
          color: root.fg
          opacity: 0.75
          font.family: Style.fontFamily
          font.pixelSize: root.metaPx
          style: Text.Outline
          styleColor: Util.alpha(root.bg, 0.7)
        }
      }

      // One mask per strip, shared by every card in it: the shape is identical
      // card to card and MultiEffect stretches its source over whatever it
      // masks, so a strip pays for a single mask texture however many cards are
      // in view. They sit outside the strips because both fade on
      // chromeOpacity, and a mask that stops being rendered takes with it every
      // card that reads from it.
      Item {
        id: cardMask
        width: root.thumbW
        height: root.thumbH
        visible: false
        layer.enabled: true
        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: stripArea.skew; startY: 0
            PathLine { x: cardMask.width; y: 0 }
            PathLine { x: cardMask.width - stripArea.skew; y: cardMask.height }
            PathLine { x: 0; y: cardMask.height }
            PathLine { x: stripArea.skew; y: 0 }
          }
        }
      }
      Item {
        id: bgCardMask
        width: root.bgThumbW
        height: root.bgThumbH
        visible: false
        layer.enabled: true
        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: bgArea.skew; startY: 0
            PathLine { x: bgCardMask.width; y: 0 }
            PathLine { x: bgCardMask.width - bgArea.skew; y: bgCardMask.height }
            PathLine { x: 0; y: bgCardMask.height }
            PathLine { x: bgArea.skew; y: 0 }
          }
        }
      }

      // ---- filmstrip running through a fixed gate
      Item {
        id: stripArea
        opacity: root.chromeOpacity
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: root.sp(44) }
        // Size for the enlarged card, plus room on both sides for its shadow
        // and gate. Every card shares the same vertical centerline.
        height: Math.ceil(thumbH * liveScale) + root.sp(52)

        readonly property int thumbW: root.thumbW
        readonly property int thumbH: root.thumbH
        readonly property real liveScale: 1.24
        readonly property real idleScale: 0.92
        // Match the cell to the resting artwork so spacing is the visible gap.
        readonly property int cellW: Math.round(thumbW * idleScale)
        // The cards are parallelograms, the way the stock image picker's slices
        // are: the top edge leads the bottom, so the gaps between cards become
        // parallel slanted bands and the strip reads as film running past
        // rather than a row of tiles.
        readonly property int skew: Math.round(root.thumbH * root.rake)

        ListView {
          id: strip
          anchors.fill: parent
          opacity: root.collectionOpacity
          transform: Translate { y: root.collectionOffset }
          orientation: ListView.Horizontal
          model: root.rows
          spacing: root.sp(4)
          clip: true
          currentIndex: root.selectedIndex
          highlightRangeMode: ListView.StrictlyEnforceRange
          preferredHighlightBegin: width / 2 - stripArea.cellW / 2
          preferredHighlightEnd: width / 2 + stripArea.cellW / 2
          highlightMoveDuration: root.viewReady && !root.rebuilding ? 160 : 0
          highlightFollowsCurrentItem: true
          cacheBuffer: stripArea.thumbW * 12
          reuseItems: true
          boundsBehavior: Flickable.StopAtBounds
          onCurrentIndexChanged: if (!root.rebuilding && root.viewReady && currentIndex !== root.selectedIndex && currentIndex >= 0) { root.selectedIndex = currentIndex; root.bgIndex = 0 }

          delegate: Item {
            id: cell
            required property int index
            required property var modelData
            readonly property bool selected: index === root.selectedIndex
            readonly property int pad: Math.ceil((stripArea.thumbW * stripArea.liveScale - stripArea.cellW) / 2) + root.sp(24)
            width: stripArea.cellW
            height: strip.height
            z: selected ? 2 : 0          // the lifted card, and its shadow, over its neighbours

            // A padded box the layer can put the shadow in — the delegate is
            // exactly a card wide, and a layer only renders what it covers. It
            // is live on the selected cell alone, so the strip carries one
            // shadow render target however many themes are in it.
            Item {
              id: lifted
              x: -cell.pad
              width: cell.width + cell.pad * 2
              height: cell.height
              layer.enabled: cell.selected
              layer.effect: MultiEffect {
                shadowEnabled: true
                shadowBlur: 1.0
                blurMax: 20
                shadowVerticalOffset: root.sp(6)
                shadowColor: "#000000"
                shadowOpacity: 0.55
              }

              Item {
                id: card
                x: cell.pad + (cell.width - width) / 2
                y: (lifted.height - height) / 2
                width: stripArea.thumbW
                height: stripArea.thumbH
                transformOrigin: Item.Center
                scale: cell.selected ? stripArea.liveScale : stripArea.idleScale
                Behavior on scale { enabled: root.viewReady && !root.rebuilding; NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

                // Everything the card is made of goes through the mask, so the
                // artwork stays upright inside a slanted frame — shearing the
                // card would lean the wallpaper, the palette bar and the name
                // along with it. The outline is stroked outside this layer,
                // where the mask's soft edge cannot eat half of it.
                Item {
                  id: cardFill
                  anchors.fill: parent
                  layer.enabled: true
                  layer.smooth: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: cardMask
                    maskThresholdMin: 0.3
                    maskSpreadAtMin: 0.3
                  }

                  Rectangle {
                    anchors.fill: parent
                    color: cell.modelData.colors.background || "#000"
                  }

                  // Painted card: instant, zero I/O. The thumb lands on top.
                  // Held clear of the cut corner, or the bars come out chopped.
                  Column {
                    anchors { left: parent.left; top: parent.top; topMargin: root.sp(10); leftMargin: root.sp(10) + stripArea.skew }
                    spacing: root.sp(5)
                    Rectangle { width: cell.width * 0.55; height: root.sp(5); color: cell.modelData.colors.accent || "#888" }
                    Rectangle { width: cell.width * 0.8; height: root.sp(5); color: cell.modelData.colors.foreground || "#ccc"; opacity: 0.8 }
                    Rectangle { width: cell.width * 0.4; height: root.sp(5); color: cell.modelData.colors.green || "#8c8" }
                  }
                  CacheImage {
                    anchors.fill: parent
                    path: Model.thumbPath(root.thumbsDir, cell.modelData.previewKey)
                    cache: true
                    sourceSize: Qt.size(Math.round(width * panel.dpr), Math.round(height * panel.dpr))
                    visible: status === Image.Ready
                  }
                  // Neighbours sit under a veil of the candidate's own background,
                  // so the falling-back is palette-driven like everything else
                  // here. The palette bar and the name stay above it, legible.
                  Rectangle {
                    anchors.fill: parent
                    color: root.bg
                    opacity: cell.selected ? 0 : 0.18
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                  }
                  Row {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: root.sp(4)
                    Repeater {
                      model: Model.ansi(cell.modelData)
                      Rectangle {
                        required property var modelData
                        width: card.width / 6
                        height: root.sp(4)
                        color: modelData
                      }
                    }
                  }
                  Text {
                    anchors { left: parent.left; bottom: parent.bottom; leftMargin: root.sp(8); bottomMargin: root.sp(9) }
                    text: (cell.modelData.favorite ? "★ " : "") + cell.modelData.name
                    textFormat: Text.PlainText
                    color: cell.modelData.colors.foreground || "#fff"
                    font.family: Style.fontFamily
                    font.pixelSize: root.fz.caption
                    style: Text.Outline
                    styleColor: Util.alpha(cell.modelData.colors.background || "#000", 0.9)
                  }
                }

                // A hairline, never an accent border: the gate does the marking,
                // so the live card can keep its artwork unframed.
                Shape {
                  anchors.fill: parent
                  antialiasing: true
                  preferredRendererType: Shape.CurveRenderer
                  ShapePath {
                    fillColor: "transparent"
                    strokeWidth: 1
                    strokeColor: Util.alpha(cell.modelData.colors.foreground || "#fff", cell.selected ? 0.3 : 0.18)
                    startX: stripArea.skew; startY: 0
                    PathLine { x: card.width; y: 0 }
                    PathLine { x: card.width - stripArea.skew; y: card.height }
                    PathLine { x: 0; y: card.height }
                    PathLine { x: stripArea.skew; y: 0 }
                  }
                }
              }
            }
            MouseArea {
              width: cell.selected ? card.width * card.scale : cell.width
              height: parent.height
              anchors.centerIn: parent
              onClicked: { root.selectedIndex = cell.index; root.bgIndex = 0 }
              onDoubleClicked: { root.selectedIndex = cell.index; root.apply() }
            }
          }
        }

        // Edge fades.
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: root.sp(140)
          gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: Util.alpha(root.bg, 0.9) } GradientStop { position: 1; color: Util.alpha(root.bg, 0) } } }
        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: root.sp(140)
          gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: Util.alpha(root.bg, 0) } GradientStop { position: 1; color: Util.alpha(root.bg, 0.9) } } }

        // The gate. The marker is fixed hardware and the film runs through it,
        // which is the one arrangement that can't be misread as a divider
        // between two cards. Corner brackets only, so nothing boxes in the
        // candidate's artwork, in its own accent over a keyline of its own
        // background — the colour guaranteed to separate that accent from the
        // wallpaper behind it, including the themes whose accent is their
        // foreground. Position and depth carry the marking; the accent is the
        // part that is allowed to be weak.
        Item {
          id: gate
          visible: root.rows.length > 0
          width: Math.round(stripArea.thumbW * stripArea.liveScale) + root.sp(20)
          height: Math.round(stripArea.thumbH * stripArea.liveScale) + root.sp(20)
          x: Math.round((stripArea.width - width) / 2)
          y: Math.round((stripArea.height - height) / 2)

          readonly property int t: root.sp(2)
          readonly property int armW: root.sp(26)
          readonly property int armH: root.sp(18)
          readonly property color keyline: Util.alpha(root.bg, 0.75)
          // The brackets lean with the cards: the shear off the gate's own
          // height, so the gate looks cut from the same film.
          readonly property real skew: gate.height * root.rake

          Repeater {
            model: 4
            Shape {
              id: corner
              required property int index
              readonly property bool onRight: index === 1 || index === 3
              readonly property bool onBottom: index > 1
              // The corner itself, then one step along each of the two edges
              // that meet there — along the top or bottom, and down or up the
              // slant.
              readonly property real vx: onRight ? (onBottom ? gate.width - gate.skew : gate.width) : (onBottom ? 0 : gate.skew)
              readonly property real vy: onBottom ? gate.height : 0
              readonly property real hx: vx + (onRight ? -gate.armW : gate.armW)
              readonly property real sx: vx + (onBottom ? 1 : -1) * gate.skew * gate.armH / gate.height
              readonly property real sy: onBottom ? gate.height - gate.armH : gate.armH

              anchors.fill: parent
              antialiasing: true
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                fillColor: "transparent"
                strokeColor: gate.keyline
                strokeWidth: gate.t + 2
                capStyle: ShapePath.FlatCap
                joinStyle: ShapePath.MiterJoin
                startX: corner.hx; startY: corner.vy
                PathLine { x: corner.vx; y: corner.vy }
                PathLine { x: corner.sx; y: corner.sy }
              }
              ShapePath {
                fillColor: "transparent"
                strokeColor: root.accent
                strokeWidth: gate.t
                capStyle: ShapePath.FlatCap
                joinStyle: ShapePath.MiterJoin
                startX: corner.hx; startY: corner.vy
                PathLine { x: corner.vx; y: corner.vy }
                PathLine { x: corner.sx; y: corner.sy }
              }
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          onWheel: function(w) { root.move(w.angleDelta.y < 0 || w.angleDelta.x < 0 ? 1 : -1, true); w.accepted = true }
        }
      }

      // ---- footer
      Text {
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: root.sp(56); bottomMargin: root.sp(14) }
        text: root.rows.length ? (root.selectedIndex + 1) + " / " + root.rows.length + (root.rows.length !== root.themes.length ? "  (" + root.themes.length + " total)" : "") : "no themes match"
        color: root.fg; opacity: 0.75 * root.chromeOpacity
        font.family: Style.fontFamily; font.pixelSize: root.fz.caption
      }
      Row {
        opacity: root.chromeOpacity
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: root.sp(56); bottomMargin: root.sp(14) }
        spacing: root.sp(18)
        Repeater {
          model: ["h/l theme", "j/k background", "/ search", "Ctrl+F favorites", "⏎ apply", "Esc cancel"]
          Text { required property string modelData; text: modelData; color: root.fg; opacity: 0.75; font.family: Style.fontFamily; font.pixelSize: root.fz.caption }
        }
      }
    }

    // Acknowledge the shortcut on the first frame, independently of the index
    // and image decoders. No minimum hold or animation delays the ready view.
    Item {
      anchors.fill: parent
      visible: root.opened && !root.viewReady
      Rectangle {
        anchors.fill: parent
        color: Util.alpha(Color.background, 0.22)
      }
      // Invisible picker controls must not receive clicks during preparation.
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
      Rectangle {
        anchors {
          horizontalCenter: parent.horizontalCenter
          bottom: parent.bottom
          bottomMargin: root.sp(70)
        }
        width: openingLabel.implicitWidth + root.sp(40)
        height: root.sp(44)
        radius: root.sp(8)
        color: Color.background
        border.color: Util.alpha(Color.accent, 0.5)
        border.width: 1
        Text {
          id: openingLabel
          anchors.centerIn: parent
          text: "Opening Swatch…"
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: root.fz.body
        }
      }
    }

    // Outside the stage so it is unaffected by the stage's blur layer: the
    // black is the cut itself, not something being defocused along with the
    // picture underneath it.
    Rectangle {
      anchors.fill: parent
      color: "black"
      opacity: root.blackout
      visible: opacity > 0
    }
  }

  readonly property int thumbW: root.sp(188)
  readonly property int thumbH: root.sp(106)
  readonly property int paletteSwatchW: Math.round(root.sp(38) * Math.sqrt(root.k))
  // The label starts on the palette's right edge, leaving its usual text gap.
  readonly property int bgThumbW: paletteSwatchW * 6 - root.sp(14)
  readonly property int bgThumbH: Math.round(bgThumbW * 9 / 16)
  // Whole cards only, with a gap before the bottom theme strip. Reduce the
  // visible count on shorter screens instead of slicing through a thumbnail.
  readonly property int bgVisibleCount: Math.max(1, Math.min(3,
    selected ? selected.backgrounds.length : 1,
    Math.floor((stripArea.y - root.sp(24) - (titleBlock.y + bgArea.y) + root.sp(8))
      / (bgThumbH + root.sp(8)))))
  // Short collections need enough viewport for their end marker. Longer
  // collections reveal it naturally as the final wallpaper reaches the top.
  readonly property int bgStripH: Math.min(
    bgThumbH * bgVisibleCount + root.sp(8) * (bgVisibleCount - 1)
      + (selected && selected.backgrounds.length <= bgVisibleCount ? hiddenFooterHeight : 0),
    Math.max(bgThumbH, stripArea.y - root.sp(24) - (titleBlock.y + bgArea.y)))

  // Keep the index warm so the first open doesn't wait on a cold walk.
  Component.onCompleted: { freezeMetrics(); readPreferences(); indexProc.running = true }
}
