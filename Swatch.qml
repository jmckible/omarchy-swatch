import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "SwatchModel.js" as Model

// Swatch: try the theme on. The candidate's wallpaper fills the screen, the
// shell retints to its palette while you scrub, and a filmstrip under a fixed
// playhead is the only chrome that isn't the theme itself.
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
  property string selectionFile: ""
  property string doneFile: ""
  property bool applying: false
  property bool livePreview: true

  readonly property var selected: (selectedIndex >= 0 && selectedIndex < rows.length) ? rows[selectedIndex] : null
  readonly property string selectedBackground: Model.backgroundAt(selected, bgIndex)
  readonly property var ansi: Model.ansi(selected)
  readonly property color bg: selected ? selected.colors.background || "#101315" : "#101315"
  readonly property color fg: selected ? selected.colors.foreground || "#cacccc" : "#cacccc"
  readonly property color accent: selected ? selected.colors.accent || fg : fg

  // Wallpaper slots: the selected background plus its neighbours stay
  // decoded in fixed Image items (the pixmap cache won't hold screen-size
  // images for us), so scrubbing never waits on a decode it already did.
  readonly property int slotCount: 5
  property var slots: ["", "", "", "", ""]
  property var slotAge: [0, 0, 0, 0, 0]
  property int tick: 0
  property string shownBackground: ""

  // Reading content scales with the screen above a 1440-wide baseline, so a
  // 13" laptop keeps Style's sizes and a 4K desk doesn't get 13 px samples.
  readonly property real k: panel.width > 0 ? Math.max(1, Math.min(1.8, panel.width / 1440)) : 1
  readonly property int metaPx: Math.round(Style.font.body * k)
  readonly property int samplePx: Math.round(Style.font.subtitle * k)

  readonly property string barPosition: shell && shell.bar && shell.bar.position ? shell.bar.position : "top"
  readonly property int barSize: shell && shell.bar && shell.bar.barSize ? shell.bar.barSize : 0

  function scriptPath(name) { return Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "") }

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var args = {}
    try { args = JSON.parse(payloadJson || "{}") || {} } catch (e) { args = {} }
    selectionFile = String(args.selectionFile || "")
    doneFile = String(args.doneFile || "")
    applying = false
    filterText = ""
    modeFilter = "all"
    opened = true
    indexProc.running = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    if (!applying && livePreview) revertPreview()
    if (doneFile && !applying) finishDoneFile()
    player.stop()
    opened = false
  }

  function dismiss() {
    if (shell && manifest) shell.hide(manifest.id)
    else close()
  }

  // ---------------------------------------------------------------- index

  Process {
    id: indexProc
    command: [root.scriptPath("index.sh")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.loadIndex(text) }
  }

  Process {
    id: thumbsProc
    command: [root.scriptPath("thumbs.sh")]
    onExited: root.refreshRows()
  }

  function loadIndex(raw) {
    if (!raw) return
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { console.warn("swatch: index parse failed:", e); return }
    var changed = raw !== loadedIndex
    loadedIndex = raw
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
      var bi = t && t.backgrounds ? t.backgrounds.indexOf(currentBackground) : -1
      bgIndex = bi === -1 ? 0 : bi
    } else if (keep !== (selected ? selected.name : "")) {
      bgIndex = 0
    }
    Qt.callLater(function() { if (selectedIndex >= 0) strip.positionViewAtIndex(selectedIndex, ListView.Center) })
  }

  function refreshRows() {
    var copy = rows.slice()
    rows = copy   // new array → delegates re-bind and retry thumbs that just landed
  }

  // ---------------------------------------------------------------- navigation

  function setFilter(text) { filterText = text; rebuild(false) }
  function cycleMode() { modeFilter = Model.nextMode(modeFilter); rebuild(false) }

  // Single steps wrap around the ends; page jumps and Home/End clamp.
  function move(delta, wrap) {
    if (!rows.length) return
    var next = wrap ? Model.wrap(selectedIndex + delta, rows.length) : Model.clamp(selectedIndex + delta, rows.length)
    if (next === selectedIndex) return
    selectedIndex = next
    bgIndex = 0
  }

  function jumpTo(index) {
    if (!rows.length) return
    var next = Model.clamp(index, rows.length)
    if (next === selectedIndex) return
    selectedIndex = next
    bgIndex = 0
  }

  function moveBackground(delta) {
    var t = selected
    if (!t || !t.backgrounds || t.backgrounds.length < 2) return
    bgIndex = (bgIndex + delta + t.backgrounds.length) % t.backgrounds.length
  }

  onSelectedIndexChanged: {
    if (!opened) return
    previewDebounce.restart()
    strip.currentIndex = selectedIndex
  }

  // ---------------------------------------------------------------- wallpaper

  onSelectedBackgroundChanged: if (opened) stageBackground()

  function stageBackground() {
    var want = [selectedBackground]
    for (var d = 1; d <= 2; d++) {
      if (rows[selectedIndex + d]) want.push(Model.backgroundAt(rows[selectedIndex + d], 0))
      if (rows[selectedIndex - d]) want.push(Model.backgroundAt(rows[selectedIndex - d], 0))
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
    var slot = slots.indexOf(selectedBackground)
    var item = slot === -1 ? null : wallpapers.itemAt(slot)
    if (item && item.status === Image.Ready) shownBackground = selectedBackground
    stageVideo()
  }

  function stageVideo() {
    var t = selected
    var src = t && t.video ? Util.fileUrl(t.video) : ""
    if (String(player.source) === src && src) return
    player.stop()
    player.source = src
    if (src) player.play()
  }

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
    if (!t) return
    applying = true
    if (selectionFile) {
      Quickshell.execDetached(["bash", "-c",
        "printf '%s\\n' " + Util.shellQuote(t.name) + " > " + Util.shellQuote(selectionFile)
        + "; : > " + Util.shellQuote(doneFile)])
      selectionFile = ""; doneFile = ""
    } else {
      var cmd = Util.shellQuote(omarchyPath + "/bin/omarchy-theme-set") + " " + Util.shellQuote(t.name)
      var bg = selectedBackground
      if (bg && t.backgrounds && t.backgrounds.length > 1 && bg !== Model.backgroundAt(t, 0))
        cmd += " && " + Util.shellQuote(omarchyPath + "/bin/omarchy-theme-bg-set") + " " + Util.shellQuote(bg)
      Quickshell.execDetached(["bash", "-c", cmd])
    }
    dismiss()
  }

  function finishDoneFile() {
    if (!doneFile) return
    Quickshell.execDetached(["bash", "-c", ": > " + Util.shellQuote(doneFile)])
    selectionFile = ""; doneFile = ""
  }

  // ---------------------------------------------------------------- video

  MediaPlayer {
    id: player
    loops: MediaPlayer.Infinite
    videoOutput: video
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
    // bar sits unpainted — so the bar you see retinting is the actual bar.
    Item {
      id: stage
      anchors.fill: parent
      anchors.topMargin: root.barPosition === "top" ? root.barSize : 0
      anchors.bottomMargin: root.barPosition === "bottom" ? root.barSize : 0
      anchors.leftMargin: root.barPosition === "left" ? root.barSize : 0
      anchors.rightMargin: root.barPosition === "right" ? root.barSize : 0
      clip: true

      Rectangle { anchors.fill: parent; color: root.bg }

      Repeater {
        id: wallpapers
        model: root.slotCount
        Image {
          required property int index
          anchors.fill: parent
          source: root.slots[index] ? Util.fileUrl(root.slots[index]) : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          sourceSize: Qt.size(Math.round(stage.width * panel.dpr), Math.round(stage.height * panel.dpr))
          opacity: root.slots[index] && root.slots[index] === root.shownBackground ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.InOutQuad } }
          onStatusChanged: if (status === Image.Ready && root.slots[index] === root.selectedBackground) root.shownBackground = root.selectedBackground
        }
      }

      VideoOutput {
        id: video
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: player.playbackState === MediaPlayer.PlayingState ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 350 } }
      }

      // Scrims: a light lid at the top for the title, a heavier one at the
      // bottom for the strip. Both in the candidate's own background colour.
      Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: Math.round(parent.height * 0.32)
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(root.bg, 0.55) }
          GradientStop { position: 1.0; color: Util.alpha(root.bg, 0.0) }
        }
      }
      Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: Math.round(parent.height * 0.42)
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(root.bg, 0.0) }
          GradientStop { position: 1.0; color: Util.alpha(root.bg, 0.94) }
        }
      }

      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          event.accepted = true
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
        anchors { left: parent.left; top: parent.top; leftMargin: Style.space(56); topMargin: Style.space(52) }
        spacing: Style.space(12)
        visible: !!root.selected

        Text {
          text: root.selected ? root.selected.name : ""
          color: root.selected && root.selected.mode === "light" ? root.fg : "#ffffff"
          font.family: Style.fontFamily
          font.pixelSize: Math.round(Style.space(44) * Math.sqrt(root.k))
          font.weight: Font.Bold
          font.letterSpacing: -1
          style: Text.Raised
          styleColor: Util.alpha(root.bg, 0.6)
        }
        Row {
          spacing: Style.space(10)
          Text { text: root.selected ? (root.selected.mode === "light" ? "light" : "dark") : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: "·"; color: root.fg; opacity: 0.45; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: root.selected ? (root.selected.source === "user" ? "installed" : "stock") + (root.selected.shadowsStock ? " (shadows stock)" : "") : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: "·"; color: root.fg; opacity: 0.45; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { text: root.selected ? root.selected.backgrounds.length + " background" + (root.selected.backgrounds.length === 1 ? "" : "s") : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { visible: !!(root.selected && root.selected.video); text: "· video"; color: root.accent; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
          Text { visible: root.selected && root.selected.name === root.currentTheme; text: "· current"; color: root.fg; opacity: 0.7; font.family: Style.fontFamily; font.pixelSize: root.metaPx }
        }
        Row {
          Repeater {
            model: root.ansi
            Rectangle { required property var modelData; width: Math.round(Style.space(38) * Math.sqrt(root.k)); height: Math.round(Style.space(10) * Math.sqrt(root.k)); color: modelData }
          }
        }
        // Backgrounds: a vertical filmstrip under its own playhead, same
        // metaphor as the theme strip turned on its side. Only when there is
        // something to choose.
        Item {
          id: bgArea
          visible: !!(root.selected && root.selected.backgrounds.length > 1)
          width: root.bgThumbW + Style.space(120)
          height: root.bgStripH

          ListView {
            id: bgStrip
            width: root.bgThumbW
            height: parent.height
            orientation: ListView.Vertical
            model: root.selected ? root.selected.backgrounds : []
            spacing: Style.space(8)
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
              readonly property string thumb: root.selected && root.selected.bgThumbs && root.selected.bgThumbs[index] ? root.selected.bgThumbs[index] : ""
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
                Image {
                  anchors.fill: parent
                  source: bgCell.thumb ? Util.fileUrl(bgCell.thumb) : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  sourceSize: Qt.size(Math.round(width * panel.dpr), Math.round(height * panel.dpr))
                  visible: status === Image.Ready
                }
                Rectangle {
                  anchors.fill: parent
                  color: "transparent"
                  border.width: bgCell.sel ? Style.space(2) : 1
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
          Rectangle { anchors { top: parent.top; left: parent.left } width: root.bgThumbW; height: Style.space(40)
            gradient: Gradient { GradientStop { position: 0; color: Util.alpha(root.bg, 0.75) } GradientStop { position: 1; color: Util.alpha(root.bg, 0) } } }
          Rectangle { anchors { bottom: parent.bottom; left: parent.left } width: root.bgThumbW; height: Style.space(40)
            gradient: Gradient { GradientStop { position: 0; color: Util.alpha(root.bg, 0) } GradientStop { position: 1; color: Util.alpha(root.bg, 0.75) } } }
          Rectangle { x: -Style.space(10); anchors.verticalCenter: parent.verticalCenter; width: Style.space(2); height: root.bgThumbH + Style.space(8); color: root.fg; opacity: 0.9 }

          Column {
            anchors { left: bgStrip.right; leftMargin: Style.space(14); verticalCenter: parent.verticalCenter }
            spacing: Style.space(4)
            Text { text: root.selected ? (root.bgIndex + 1) + " / " + root.selected.backgrounds.length : ""; color: root.fg; font.family: Style.fontFamily; font.pixelSize: Style.font.title; font.weight: Font.DemiBold }
            Text { text: "backgrounds"; color: root.fg; opacity: 0.7; font.family: Style.fontFamily; font.pixelSize: Style.font.caption }
            Text { text: "↑ ↓"; color: root.fg; opacity: 0.5; font.family: Style.fontFamily; font.pixelSize: Style.font.caption }
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
        anchors { right: parent.right; top: parent.top; rightMargin: Style.space(56); topMargin: Style.space(52) }
        spacing: Style.space(14)
        visible: !!root.selected

      Rectangle {
        width: Math.round(Style.space(500) * root.k)
        height: sample.implicitHeight + Style.space(28)
        color: Util.alpha(root.bg, 0.88)
        border.width: 1
        border.color: root.accent
        visible: !!root.selected

        Column {
          id: sample
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(14) }
          spacing: Style.space(4)
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
          Row { spacing: Style.space(6)
            Text { text: "❯"; color: root.accent; font.family: sample.ff; font.pixelSize: sample.px }
            Rectangle { width: Style.space(8); height: sample.px + 2; color: root.accent; anchors.verticalCenter: parent.verticalCenter } }
        }
      }

      // A small Rails model, in homage to where Omarchy comes from.
      Rectangle {
        width: Math.round(Style.space(500) * root.k)
        height: code.implicitHeight + Style.space(28)
        color: Util.alpha(root.bg, 0.88)
        border.width: 1
        border.color: Util.alpha(root.fg, 0.35)

        Column {
          id: code
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(14) }
          spacing: Style.space(4)
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
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: Style.space(52) }
        spacing: Style.space(10)

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)
          Repeater {
            model: Model.MODES
            Rectangle {
              id: chip
              required property string modelData
              readonly property bool on: modelData === root.modeFilter
              height: Style.space(24)
              width: chipLabel.implicitWidth + Style.space(20)
              color: on ? Util.alpha(root.fg, 0.92) : Util.alpha(root.bg, 0.55)
              border.width: 1
              border.color: on ? root.fg : Util.alpha(root.fg, 0.35)
              Text {
                id: chipLabel
                anchors.centerIn: parent
                text: chip.modelData.charAt(0).toUpperCase() + chip.modelData.slice(1)
                color: chip.on ? root.bg : root.fg
                font.family: Style.fontFamily
                font.pixelSize: Style.font.caption
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
          font.pixelSize: Style.font.heading
          style: Text.Outline
          styleColor: Util.alpha(root.bg, 0.7)
        }
      }

      // ---- filmstrip under a fixed playhead
      Item {
        id: stripArea
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: Style.space(44) }
        height: root.thumbH + Style.space(24)

        readonly property int thumbW: root.thumbW
        readonly property int thumbH: root.thumbH

        ListView {
          id: strip
          anchors.fill: parent
          anchors.topMargin: Style.space(12)
          orientation: ListView.Horizontal
          model: root.rows
          spacing: Style.space(12)
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
            width: stripArea.thumbW
            height: stripArea.thumbH

            Rectangle {
              anchors.fill: parent
              color: cell.modelData.colors.background || "#000"
              opacity: cell.selected ? 1 : 0.82
              scale: cell.selected ? 1.0 : 0.94
              Behavior on scale { NumberAnimation { duration: 140 } }
              Behavior on opacity { NumberAnimation { duration: 140 } }
              clip: true

              // Painted card: instant, zero I/O. The thumb lands on top.
              Column {
                anchors { left: parent.left; top: parent.top; margins: Style.space(10) }
                spacing: Style.space(5)
                Rectangle { width: cell.width * 0.55; height: Style.space(5); color: cell.modelData.colors.accent || "#888" }
                Rectangle { width: cell.width * 0.8; height: Style.space(5); color: cell.modelData.colors.foreground || "#ccc"; opacity: 0.8 }
                Rectangle { width: cell.width * 0.4; height: Style.space(5); color: cell.modelData.colors.green || "#8c8" }
              }
              Image {
                anchors.fill: parent
                source: cell.modelData.thumb ? Util.fileUrl(cell.modelData.thumb) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                sourceSize: Qt.size(Math.round(width * panel.dpr), Math.round(height * panel.dpr))
                visible: status === Image.Ready
              }
              Row {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: Style.space(4)
                Repeater { model: Model.ansi(cell.modelData); Rectangle { required property var modelData; width: cell.width / 6; height: Style.space(4); color: modelData } }
              }
              Text {
                anchors { left: parent.left; bottom: parent.bottom; leftMargin: Style.space(8); bottomMargin: Style.space(9) }
                text: cell.modelData.name
                color: cell.modelData.colors.foreground || "#fff"
                font.family: Style.fontFamily
                font.pixelSize: Style.font.caption
                style: Text.Outline
                styleColor: Util.alpha(cell.modelData.colors.background || "#000", 0.9)
              }
              Rectangle {
                visible: !!cell.modelData.video
                anchors { right: parent.right; top: parent.top; margins: Style.space(6) }
                width: Style.space(16); height: Style.space(16)
                color: Util.alpha(cell.modelData.colors.background || "#000", 0.7)
                Text { anchors.centerIn: parent; text: "▶"; color: cell.modelData.colors.foreground || "#fff"; font.pixelSize: Style.space(8) }
              }
              Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: cell.selected ? Style.space(2) : 1
                border.color: cell.selected ? root.accent : Util.alpha(cell.modelData.colors.foreground || "#fff", 0.18)
              }
            }
            MouseArea {
              anchors.fill: parent
              onClicked: { root.selectedIndex = cell.index; root.bgIndex = 0 }
              onDoubleClicked: { root.selectedIndex = cell.index; root.apply() }
            }
          }
        }

        // Edge fades and the playhead.
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: Style.space(140)
          gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: Util.alpha(root.bg, 0.9) } GradientStop { position: 1; color: Util.alpha(root.bg, 0) } } }
        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: Style.space(140)
          gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: Util.alpha(root.bg, 0) } GradientStop { position: 1; color: Util.alpha(root.bg, 0.9) } } }
        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: -Style.space(4); width: Style.space(2); height: parent.height + Style.space(8); color: root.fg; opacity: 0.9 }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          onWheel: function(w) { root.move(w.angleDelta.y < 0 || w.angleDelta.x < 0 ? 1 : -1, true); w.accepted = true }
        }
      }

      // ---- footer
      Text {
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: Style.space(56); bottomMargin: Style.space(14) }
        text: root.rows.length ? (root.selectedIndex + 1) + " / " + root.rows.length + (root.rows.length !== root.themes.length ? "  (" + root.themes.length + " total)" : "") : "no themes match"
        color: root.fg; opacity: 0.75
        font.family: Style.fontFamily; font.pixelSize: Style.font.caption
      }
      Row {
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: Style.space(56); bottomMargin: Style.space(14) }
        spacing: Style.space(18)
        Repeater {
          model: ["← → theme", "↑ ↓ background", "type to filter", "Tab filter", "⏎ apply", "Esc cancel"]
          Text { required property string modelData; text: modelData; color: root.fg; opacity: 0.75; font.family: Style.fontFamily; font.pixelSize: Style.font.caption }
        }
      }
    }
  }

  readonly property int thumbW: Style.space(188)
  readonly property int thumbH: Style.space(106)
  readonly property int bgThumbW: Style.space(150)
  readonly property int bgThumbH: Style.space(84)
  readonly property int bgStripH: Style.space(84) * 4 + Style.space(8) * 3

  // Keep the index warm so the first open doesn't wait on a cold walk.
  Component.onCompleted: indexProc.running = true
}
