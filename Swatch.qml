import QtQuick
import QtQuick.Effects
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
  property var themes: []
  property string loadedIndex: ""
  property var rows: []
  property string filterText: ""
  property string modeFilter: "all"
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
  readonly property int holdFloorMs: 140

  // Which strip the last move was in, and which way. The transition follows the
  // axis you pressed: themes are a horizontal filmstrip, backgrounds a vertical
  // one, so the motion itself says which list you are moving through.
  property string scrubAxis: "theme"
  property int scrubDir: 1
  property bool scrubArmed: false
  // Everything that isn't the wallpaper. It goes the moment a choice is
  // committed, leaving the candidate's wallpaper and the real bar — which is
  // the desktop that is a moment away. Instant on open (the Behavior is armed
  // only while applying) so the picker doesn't fade in over itself.
  property real chromeOpacity: 1
  Behavior on chromeOpacity { enabled: root.applying; NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }
  property bool livePreview: true

  readonly property var selected: (selectedIndex >= 0 && selectedIndex < rows.length) ? rows[selectedIndex] : null
  readonly property string selectedBackground: Model.backgroundAt(selected, bgIndex)
  readonly property string selectedKey: Model.keyAt(selected, bgIndex)
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
    fz = { caption: root.fz.caption, body: root.fz.body, subtitle: root.fz.subtitle, title: root.fz.title, heading: root.fz.heading }
  }
  function sp(px) { var n = px * metricScale; return n <= 0 ? 0 : Math.max(1, Math.round(n)) }

  // Reading content scales with the screen above a 1440-wide baseline, so a
  // 13" laptop keeps Style's sizes and a 4K desk doesn't get 13 px samples.
  readonly property real k: panel.width > 0 ? Math.max(1, Math.min(1.8, panel.width / 1440)) : 1
  readonly property int metaPx: Math.round(root.fz.body * k)
  readonly property int samplePx: Math.round(root.fz.subtitle * k)

  readonly property string barPosition: shell && shell.bar && shell.bar.position ? shell.bar.position : "top"
  readonly property int barSize: shell && shell.bar && shell.bar.barSize ? shell.bar.barSize : 0
  // The carve-out below is only honest while the bar paints its own background.
  // A transparent bar is a hole onto the wallpaper we are leaving; a hidden bar
  // is a hole onto nothing. Either way the band shows the old theme hard against
  // the candidate's, so cover it and let the scrim run to the screen edge.
  readonly property bool barOpaque: !!(shell && shell.bar) && !shell.bar.transparent && !shell.bar.barHidden
  readonly property int barInset: barOpaque ? barSize : 0

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
    applying = false
    applyTarget = ""
    chromeOpacity = 1
    exitBlur = 0
    blackout = 0
    liftPending = false
    scrubArmed = false
    stage.opacity = 1
    wallpaperLayer.scale = 1
    freezeMetrics()
    filterText = ""
    modeFilter = "all"
    opened = true
    indexProc.running = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    if (!applying && livePreview) revertPreview()
    if (pickDir && !applying) finishPick("")
    cancelExit()
    opened = false
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
    command: [root.scriptPath("index.sh")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.loadIndex(text) }
  }

  Process {
    id: thumbsProc
    command: [root.scriptPath("thumbs.sh")]
    onExited: root.cacheGen += 1
  }
  // Derivatives land while thumbs.sh runs; tick so images that were missing retry.
  Timer { running: thumbsProc.running; interval: 2000; repeat: true; onTriggered: root.cacheGen += 1 }

  function loadIndex(raw) {
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
    rebuild(true)
    if (!thumbsProc.running) thumbsProc.running = true
  }

  // Re-derive rows and, on first load per open, land on the current theme and
  // its current background so the first frame is the desktop you already have.
  function rebuild(landOnCurrent) {
    var keep = selected ? selected.name : ""
    rows = Model.filter(themes, filterText, modeFilter)
    var target = landOnCurrent && currentTheme ? currentTheme : keep
    var i = Model.indexOf(rows, target)
    if (i === -1) i = rows.length ? 0 : -1
    selectedIndex = i
    if (landOnCurrent) {
      var t = selected
      var bi = Model.backgroundIndexOf(t, currentBackground)
      bgIndex = bi === -1 ? 0 : bi
    } else if (keep !== (selected ? selected.name : "")) {
      bgIndex = 0
    }
    Qt.callLater(function() { if (selectedIndex >= 0) strip.positionViewAtIndex(selectedIndex, ListView.Center) })
  }

  // ---------------------------------------------------------------- navigation

  function setFilter(text) { filterText = text; rebuild(false) }
  function cycleMode() { modeFilter = Model.nextMode(modeFilter); rebuild(false) }

  // Single steps wrap around the ends; page jumps and Home/End clamp.
  function move(delta, wrap) {
    if (!rows.length) return
    var next = wrap ? Model.wrap(selectedIndex + delta, rows.length) : Model.clamp(selectedIndex + delta, rows.length)
    if (next === selectedIndex) return
    scrubAxis = "theme"; scrubDir = delta < 0 ? -1 : 1
    selectedIndex = next
    bgIndex = 0
  }

  function jumpTo(index) {
    if (!rows.length) return
    var next = Model.clamp(index, rows.length)
    if (next === selectedIndex) return
    scrubAxis = "theme"; scrubDir = next < selectedIndex ? -1 : 1
    selectedIndex = next
    bgIndex = 0
  }

  function moveBackground(delta) {
    var t = selected
    if (!t || !t.backgrounds || t.backgrounds.length < 2) return
    scrubAxis = "bg"; scrubDir = delta < 0 ? -1 : 1
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
        // Evict the slot that is neither wanted nor recently used.
        var victim = -1, oldest = Infinity
        for (var i = 0; i < s.length; i++) {
          if (want.indexOf(s[i]) !== -1) continue
          if (age[i] < oldest) { oldest = age[i]; victim = i }
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
    if (item && item.ready) shownKey = selectedKey
  }

  function slotReady(key) { if (key && key === selectedKey) shownKey = key }

  // ---------------------------------------------------------------- preview

  Timer { id: previewDebounce; interval: 120; onTriggered: root.previewSelected() }

  function previewSelected() {
    var t = selected
    if (!t || !livePreview || !opened) return
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

  ParallelAnimation {
    id: dipDown
    NumberAnimation { target: root; property: "blackout"; to: 1; duration: 300; easing.type: Easing.InQuad }
    NumberAnimation { target: root; property: "exitBlur"; to: 1; duration: 340; easing.type: Easing.InQuad }
    NumberAnimation { target: wallpaperLayer; property: "scale"; to: 1.035; duration: 440; easing.type: Easing.OutQuad }
    onFinished: if (root.liftPending) { root.liftPending = false; liftUp.restart() }
  }

  SequentialAnimation {
    id: liftUp
    PauseAnimation { duration: root.holdFloorMs }
    ParallelAnimation {
      NumberAnimation { target: root; property: "blackout"; to: 0; duration: 320; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "exitBlur"; to: 0; duration: 420; easing.type: Easing.OutCubic }
      NumberAnimation { target: wallpaperLayer; property: "scale"; to: 1; duration: 420; easing.type: Easing.OutCubic }
    }
    // The cover is sharp again and identical to the desktop under it, so this
    // last crossfade is invisible — the matching image finally paying off.
    NumberAnimation { target: stage; property: "opacity"; to: 0; duration: 140 }
    onFinished: root.dismiss()
  }

  // ---------------------------------------------------------------- scrubbing

  onShownKeyChanged: {
    if (!opened || applying || !shownKey) return
    if (!scrubArmed) { scrubArmed = true; return }   // the first frame of an open
    startScrub()
  }

  // Themes get a blade across the horizontal axis they live on; backgrounds get
  // a quieter push along their vertical one. A blade already in flight is left
  // alone, so holding an arrow key thins the effect out instead of stacking it.
  function startScrub() {
    if (scrubAxis === "bg") {
      wallpaperLayer.nudgeX = 0
      nudgeY.stop()
      nudgeY.from = scrubDir * panel.height * 0.055
      nudgeY.to = 0
      nudgeY.start()
      return
    }
    wallpaperLayer.nudgeY = 0
    nudgeX.stop()
    nudgeX.from = scrubDir * panel.width * 0.045
    nudgeX.to = 0
    nudgeX.start()
    if (bladeRun.running) return
    bladeRun.from = scrubDir > 0 ? -bladeEdge.width : panel.width
    bladeRun.to = scrubDir > 0 ? panel.width : -bladeEdge.width
    bladeRun.restart()
  }

  NumberAnimation { id: nudgeX; target: wallpaperLayer; property: "nudgeX"; duration: 240; easing.type: Easing.OutCubic }
  NumberAnimation { id: nudgeY; target: wallpaperLayer; property: "nudgeY"; duration: 200; easing.type: Easing.OutCubic }
  NumberAnimation { id: bladeRun; target: bladeEdge; property: "x"; duration: 260; easing.type: Easing.InOutQuad }

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

    // Everything lives inside this item, which leaves the band where the real
    // bar sits unpainted — so the bar you see retinting is the actual bar. Only
    // while that band is opaque: see barInset.
    Item {
      id: stage
      anchors.fill: parent
      anchors.topMargin: root.barPosition === "top" ? root.barInset : 0
      anchors.bottomMargin: root.barPosition === "bottom" ? root.barInset : 0
      anchors.leftMargin: root.barPosition === "left" ? root.barInset : 0
      anchors.rightMargin: root.barPosition === "right" ? root.barInset : 0
      clip: true

      // Only live during the exit: a layer on a screen-size item costs a render
      // target, and there is nothing to defocus while you are still choosing.
      layer.enabled: root.applying
      layer.effect: MultiEffect {
        blurEnabled: true
        blur: root.exitBlur
        blurMax: 40
      }

      Rectangle { anchors.fill: parent; color: root.bg }

      Item {
        id: wallpaperLayer
        anchors.fill: parent
        // Anchored, so the scrub's travel goes through a transform rather than x/y.
        property real nudgeX: 0
        property real nudgeY: 0
        transform: Translate { x: wallpaperLayer.nudgeX; y: wallpaperLayer.nudgeY }

        Repeater {
          id: wallpapers
          model: root.slotCount
          Item {
            id: slotItem
            required property int index
            readonly property string key: root.slots[index]
            readonly property bool ready: stageImg.status === Image.Ready || softImg.status === Image.Ready
            anchors.fill: parent
            opacity: key && key === root.shownKey ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.InOutQuad } }
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

      // The blade: a bar of the candidate's accent crossing the wallpaper when
      // the theme changes. Above the scrims so it stays crisp, below the chrome
      // so the name and the strip keep their contrast.
      Item {
        id: bladeBand
        anchors.fill: parent
        visible: bladeRun.running
        Rectangle {
          id: bladeEdge
          width: Math.round(parent.width * 0.15)
          height: parent.height * 1.4
          y: -parent.height * 0.2
          transform: Rotation { origin.x: bladeEdge.width / 2; origin.y: bladeEdge.height / 2; angle: 6 }
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Util.alpha(root.accent, 0) }
            GradientStop { position: 0.74; color: Util.alpha(root.accent, 0.34) }
            GradientStop { position: 0.96; color: Util.alpha(root.fg, 0.8) }
            GradientStop { position: 1.0; color: Util.alpha(root.accent, 0) }
          }
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
          if (k === Qt.Key_Escape) { if (root.filterText) root.setFilter(""); else root.dismiss() }
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.apply()
          else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) root.cycleMode()
          else if (k === Qt.Key_Left) root.move(-1, true)
          else if (k === Qt.Key_Right) root.move(1, true)
          else if (k === Qt.Key_Up) root.moveBackground(-1)
          else if (k === Qt.Key_Down) root.moveBackground(1)
          else if (k === Qt.Key_PageUp) root.move(-5, false)
          else if (k === Qt.Key_PageDown) root.move(5, false)
          else if (k === Qt.Key_Home) root.jumpTo(0)
          else if (k === Qt.Key_End) root.jumpTo(root.rows.length - 1)
          else if (Util.editsFilter(event, root.filterText)) root.setFilter(Util.editedFilter(event, root.filterText))
          else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                   && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier))
            root.setFilter(root.filterText + event.text)
          else event.accepted = false
        }
      }

      // ---- title block
      Column {
        opacity: root.chromeOpacity
        anchors { left: parent.left; top: parent.top; leftMargin: root.sp(56); topMargin: root.sp(52) }
        spacing: root.sp(12)
        visible: !!root.selected

        Text {
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
        Row {
          spacing: root.sp(10)
          Text { text: root.selected ? (root.selected.mode === "light" ? "light" : "dark") : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: "·"; color: root.fg; opacity: 0.45; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: root.selected ? (root.selected.source === "user" ? "installed" : "stock") + (root.selected.shadowsStock ? " (shadows stock)" : "") : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: "·"; color: root.fg; opacity: 0.45; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: root.selected ? root.selected.backgrounds.length + " background" + (root.selected.backgrounds.length === 1 ? "" : "s") : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { visible: root.selected && root.selected.name === root.currentTheme; text: "· current"; color: root.fg; opacity: 0.7; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
        }
        Row {
          Repeater {
            model: root.ansi
            Rectangle { required property var modelData; width: Math.round(root.sp(38) * Math.sqrt(root.k)); height: Math.round(root.sp(10) * Math.sqrt(root.k)); color: modelData }
          }
        }
        // Backgrounds: a vertical filmstrip under its own playhead. The theme
        // strip's gate would crowd a card this size, so here the line stays and
        // the border does the marking. Only when there is something to choose.
        Item {
          id: bgArea
          visible: !!(root.selected && root.selected.backgrounds.length > 1)
          width: root.bgThumbW + root.sp(120)
          height: root.bgStripH

          ListView {
            id: bgStrip
            width: root.bgThumbW
            height: parent.height
            orientation: ListView.Vertical
            model: root.selected ? root.selected.backgrounds : []
            spacing: root.sp(8)
            clip: true
            currentIndex: root.bgIndex
            highlightRangeMode: ListView.StrictlyEnforceRange
            preferredHighlightBegin: height / 2 - root.bgThumbH / 2
            preferredHighlightEnd: height / 2 + root.bgThumbH / 2
            highlightMoveDuration: 140
            cacheBuffer: root.bgThumbH * 8
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds
            onCurrentIndexChanged: if (currentIndex >= 0 && currentIndex !== root.bgIndex) root.bgIndex = currentIndex

            delegate: Item {
              id: bgCell
              required property int index
              required property var modelData
              readonly property bool sel: index === root.bgIndex
              readonly property string key: root.selected && root.selected.bgKeys ? (root.selected.bgKeys[index] || "") : ""
              width: root.bgThumbW
              height: root.bgThumbH

              Rectangle {
                anchors.fill: parent
                color: Util.alpha(root.bg, 0.6)
                opacity: bgCell.sel ? 1 : 0.72
                scale: bgCell.sel ? 1.0 : 0.94
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on scale { NumberAnimation { duration: 120 } }
                clip: true
                CacheImage {
                  anchors.fill: parent
                  path: Model.thumbPath(root.thumbsDir, bgCell.key)
                  cache: true
                  sourceSize: Qt.size(Math.round(width * panel.dpr), Math.round(height * panel.dpr))
                  visible: status === Image.Ready
                }
                Rectangle {
                  anchors.fill: parent
                  color: "transparent"
                  border.width: bgCell.sel ? root.sp(2) : 1
                  border.color: bgCell.sel ? root.accent : Util.alpha(root.fg, 0.22)
                }
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.bgIndex = bgCell.index
                onDoubleClicked: { root.bgIndex = bgCell.index; root.apply() }
              }
            }
          }

          // Edge fades, playhead, and the count.
          Rectangle { anchors { top: parent.top; left: parent.left } width: root.bgThumbW; height: root.sp(40)
            gradient: Gradient { GradientStop { position: 0; color: Util.alpha(root.bg, 0.75) } GradientStop { position: 1; color: Util.alpha(root.bg, 0) } } }
          Rectangle { anchors { bottom: parent.bottom; left: parent.left } width: root.bgThumbW; height: root.sp(40)
            gradient: Gradient { GradientStop { position: 0; color: Util.alpha(root.bg, 0) } GradientStop { position: 1; color: Util.alpha(root.bg, 0.75) } } }
          Rectangle { x: -root.sp(10); anchors.verticalCenter: parent.verticalCenter; width: root.sp(2); height: root.bgThumbH + root.sp(8); color: root.fg; opacity: 0.9 }

          Column {
            anchors { left: bgStrip.right; leftMargin: root.sp(14); verticalCenter: parent.verticalCenter }
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
      Column {
        opacity: root.chromeOpacity
        anchors { right: parent.right; top: parent.top; rightMargin: root.sp(56); topMargin: root.sp(52) }
        spacing: root.sp(14)
        visible: !!root.selected

      Rectangle {
        width: Math.round(root.sp(500) * root.k)
        height: sample.implicitHeight + root.sp(28)
        color: Util.alpha(root.bg, 0.88)
        border.width: 1
        border.color: root.accent
        visible: !!root.selected

        Column {
          id: sample
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.sp(14) }
          spacing: root.sp(4)
          readonly property int px: root.samplePx
          readonly property string ff: Style.fontFamily
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: root.fg
            text: '<span style="color:' + root.accent + '">❯</span> <span style="color:' + root.ansi[4] + '">~/dev/omarchy</span> <span style="color:' + root.ansi[2] + '"> main</span>' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: root.fg
            text: '<span style="color:' + root.accent + '">❯</span> ls' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: root.fg
            text: '<b><span style="color:' + root.ansi[4] + '">bin/</span>&nbsp;&nbsp;<span style="color:' + root.ansi[4] + '">shell/</span>&nbsp;&nbsp;<span style="color:' + root.ansi[4] + '">themes/</span></b>&nbsp;&nbsp;README.md&nbsp;&nbsp;<span style="color:' + root.ansi[2] + '">install.sh</span>' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: root.fg
            text: '<span style="color:' + root.accent + '">❯</span> git status --short' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: root.fg
            text: '<span style="color:' + root.ansi[1] + '">&nbsp;M</span> shell/plugins/swatch/Swatch.qml' }
          Text { textFormat: Text.RichText; font.family: sample.ff; font.pixelSize: sample.px; color: root.fg
            text: '<span style="color:' + root.ansi[0] + '">??</span> index.sh <span style="color:' + root.ansi[3] + '">→</span> <span style="color:' + root.ansi[5] + '">thumbs.sh</span>' }
          Row { spacing: root.sp(6)
            Text { text: "❯"; color: root.accent; font.family: sample.ff; font.pixelSize: sample.px }
            Rectangle { width: root.sp(8); height: sample.px + 2; color: root.accent; anchors.verticalCenter: parent.verticalCenter } }
        }
      }

      // A small Rails model, in homage to where Omarchy comes from.
      Rectangle {
        width: Math.round(root.sp(500) * root.k)
        height: code.implicitHeight + root.sp(28)
        color: Util.alpha(root.bg, 0.88)
        border.width: 1
        border.color: Util.alpha(root.fg, 0.35)

        Column {
          id: code
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.sp(14) }
          spacing: root.sp(4)
          readonly property int px: root.samplePx
          readonly property string ff: Style.fontFamily
          readonly property string kw: root.accent
          readonly property string kon: root.ansi[1]
          readonly property string sym: root.ansi[3]
          readonly property string str: root.ansi[2]
          readonly property string meth: root.ansi[4]
          readonly property string cm: Util.alpha(root.fg, 0.5)
          readonly property string ind: "&nbsp;&nbsp;"

          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: '<span style="color:' + code.cm + '"># app/models/theme.rb</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: '<span style="color:' + code.kw + '">class</span> <span style="color:' + code.kon + '">Theme</span> &lt; <span style="color:' + code.kon + '">ApplicationRecord</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + '<span style="color:' + code.meth + '">belongs_to</span> <span style="color:' + code.sym + '">:author</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + '<span style="color:' + code.meth + '">has_many</span> <span style="color:' + code.sym + '">:backgrounds</span>, <span style="color:' + code.sym + '">dependent:</span> <span style="color:' + code.sym + '">:destroy</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + '<span style="color:' + code.meth + '">validates</span> <span style="color:' + code.sym + '">:name</span>, <span style="color:' + code.sym + '">presence:</span> <span style="color:' + code.kw + '">true</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + '<span style="color:' + code.meth + '">scope</span> <span style="color:' + code.sym + '">:dark</span>, -&gt; { <span style="color:' + code.meth + '">where</span>(<span style="color:' + code.sym + '">mode:</span> <span style="color:' + code.str + '">"dark"</span>) }' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg; text: "&nbsp;" }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + '<span style="color:' + code.kw + '">def</span> <span style="color:' + code.meth + '">apply!</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + code.ind + '<span style="color:' + code.kon + '">Shell</span>.<span style="color:' + code.meth + '">retint</span>(colors)' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + code.ind + 'backgrounds.<span style="color:' + code.meth + '">first</span>&amp;.<span style="color:' + code.meth + '">set!</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: code.ind + '<span style="color:' + code.kw + '">end</span>' }
          Text { textFormat: Text.RichText; font.family: code.ff; font.pixelSize: code.px; color: root.fg
            text: '<span style="color:' + code.kw + '">end</span>' }
        }
      }
      }

      // ---- mode chips (Tab cycles, click selects) and the typed filter
      Column {
        opacity: root.chromeOpacity
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: root.sp(52) }
        spacing: root.sp(10)

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: root.sp(6)
          Repeater {
            model: Model.MODES
            Rectangle {
              id: chip
              required property string modelData
              readonly property bool on: modelData === root.modeFilter
              height: root.sp(24)
              width: chipLabel.implicitWidth + root.sp(20)
              color: on ? Util.alpha(root.fg, 0.92) : Util.alpha(root.bg, 0.55)
              border.width: 1
              border.color: on ? root.fg : Util.alpha(root.fg, 0.35)
              Text {
                id: chipLabel
                anchors.centerIn: parent
                text: chip.modelData.charAt(0).toUpperCase() + chip.modelData.slice(1)
                color: chip.on ? root.bg : root.fg
                font.family: Style.fontFamily
                font.pixelSize: root.fz.caption
                font.weight: chip.on ? Font.DemiBold : Font.Normal
              }
              MouseArea { anchors.fill: parent; onClicked: { root.modeFilter = chip.modelData; root.rebuild(false) } }
            }
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.filterText.length > 0
          text: root.filterText + "▍"
          color: root.fg
          font.family: Style.fontFamily
          font.pixelSize: root.fz.heading
          style: Text.Outline
          styleColor: Util.alpha(root.bg, 0.7)
        }
      }

      // ---- empty state: the filter ate everything
      Column {
        opacity: root.chromeOpacity
        anchors.centerIn: parent
        spacing: root.sp(10)
        visible: root.rows.length === 0 && root.themes.length > 0

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.filterText ? "No themes match “" + root.filterText + "”" : "No " + root.modeFilter + " themes"
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
          text: root.filterText ? "Esc clears the filter" : "Tab cycles the filter"
          color: root.fg
          opacity: 0.75
          font.family: Style.fontFamily
          font.pixelSize: root.metaPx
          style: Text.Outline
          styleColor: Util.alpha(root.bg, 0.7)
        }
      }

      // ---- filmstrip running through a fixed gate
      Item {
        id: stripArea
        opacity: root.chromeOpacity
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: root.sp(44) }
        // Slack above and below the cards: the live one lifts out of the strip
        // and the gate sits around it, and the ListView clips, so this is what
        // keeps the scaled card and its shadow whole.
        height: root.thumbH + root.sp(52)

        readonly property int thumbW: root.thumbW
        readonly property int thumbH: root.thumbH
        readonly property real liveScale: 1.06
        readonly property int lift: root.sp(7)

        ListView {
          id: strip
          anchors.fill: parent
          orientation: ListView.Horizontal
          model: root.rows
          spacing: root.sp(12)
          clip: true
          currentIndex: root.selectedIndex
          highlightRangeMode: ListView.StrictlyEnforceRange
          preferredHighlightBegin: width / 2 - stripArea.thumbW / 2
          preferredHighlightEnd: width / 2 + stripArea.thumbW / 2
          highlightMoveDuration: 160
          highlightFollowsCurrentItem: true
          cacheBuffer: stripArea.thumbW * 12
          reuseItems: true
          boundsBehavior: Flickable.StopAtBounds
          onCurrentIndexChanged: if (currentIndex !== root.selectedIndex && currentIndex >= 0) { root.selectedIndex = currentIndex; root.bgIndex = 0 }

          delegate: Item {
            id: cell
            required property int index
            required property var modelData
            readonly property bool selected: index === root.selectedIndex
            readonly property int pad: root.sp(22)
            width: stripArea.thumbW
            height: strip.height
            z: selected ? 2 : 0          // the lifted card, and its shadow, over its neighbours

            // A padded box the layer can put the shadow in — the delegate is
            // exactly a card wide, and a layer only renders what it covers. It
            // is live on the selected cell alone, so the strip carries one
            // render target however many themes are in it.
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

              Rectangle {
                id: card
                x: cell.pad
                y: Math.round((lifted.height - height) / 2) - (cell.selected ? stripArea.lift : 0)
                width: stripArea.thumbW
                height: stripArea.thumbH
                color: cell.modelData.colors.background || "#000"
                scale: cell.selected ? stripArea.liveScale : 0.92
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
                Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
                clip: true

                // Painted card: instant, zero I/O. The thumb lands on top.
                Column {
                  anchors { left: parent.left; top: parent.top; margins: root.sp(10) }
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
                  opacity: cell.selected ? 0 : 0.42
                  Behavior on opacity { NumberAnimation { duration: 140 } }
                }
                Row {
                  anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                  height: root.sp(4)
                  Repeater { model: Model.ansi(cell.modelData); Rectangle { required property var modelData; width: cell.width / 6; height: root.sp(4); color: modelData } }
                }
                Text {
                  anchors { left: parent.left; bottom: parent.bottom; leftMargin: root.sp(8); bottomMargin: root.sp(9) }
                  text: cell.modelData.name
                  textFormat: Text.PlainText
                  color: cell.modelData.colors.foreground || "#fff"
                  font.family: Style.fontFamily
                  font.pixelSize: root.fz.caption
                  style: Text.Outline
                  styleColor: Util.alpha(cell.modelData.colors.background || "#000", 0.9)
                }
                // A hairline, never an accent border: the gate does the marking,
                // so the live card can keep its artwork unframed.
                Rectangle {
                  anchors.fill: parent
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(cell.modelData.colors.foreground || "#fff", cell.selected ? 0.3 : 0.18)
                }
              }
            }
            MouseArea {
              anchors.fill: parent
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
          y: Math.round((stripArea.height - height) / 2) - stripArea.lift

          readonly property int t: root.sp(2)
          readonly property int armW: root.sp(26)
          readonly property int armH: root.sp(18)
          readonly property color keyline: Util.alpha(root.bg, 0.75)

          Repeater {
            model: 4
            Item {
              id: corner
              required property int index
              readonly property bool onRight: index === 1 || index === 3
              readonly property bool onBottom: index > 1
              readonly property int ax: onRight ? width - gate.t : 0
              readonly property int ay: onBottom ? height - gate.t : 0
              width: gate.armW
              height: gate.armH
              x: onRight ? gate.width - width : 0
              y: onBottom ? gate.height - height : 0

              Rectangle { x: -1; y: corner.ay - 1; width: corner.width + 2; height: gate.t + 2; color: gate.keyline }
              Rectangle { x: corner.ax - 1; y: -1; width: gate.t + 2; height: corner.height + 2; color: gate.keyline }
              Rectangle { x: 0; y: corner.ay; width: corner.width; height: gate.t; color: root.accent }
              Rectangle { x: corner.ax; y: 0; width: gate.t; height: corner.height; color: root.accent }
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
          model: ["← → theme", "↑ ↓ background", "type to filter", "Tab filter", "⏎ apply", "Esc cancel"]
          Text { required property string modelData; text: modelData; color: root.fg; opacity: 0.75; font.family: Style.fontFamily; font.pixelSize: root.fz.caption }
        }
      }
    }

    // Outside the stage, so the black takes the bar's band too: a cut should be
    // a cut, not a dark screen with a lit strip along one edge.
    Rectangle {
      anchors.fill: parent
      color: "black"
      opacity: root.blackout
      visible: opacity > 0
    }
  }

  readonly property int thumbW: root.sp(188)
  readonly property int thumbH: root.sp(106)
  readonly property int bgThumbW: root.sp(150)
  readonly property int bgThumbH: root.sp(84)
  readonly property int bgStripH: root.sp(84) * 4 + root.sp(8) * 3

  // Keep the index warm so the first open doesn't wait on a cold walk.
  Component.onCompleted: { freezeMetrics(); indexProc.running = true }
}
