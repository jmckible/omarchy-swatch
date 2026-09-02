import QtQuick
import QtMultimedia

// The animated half of a background, isolated in its own file on purpose.
//
// MediaPlayer lives in qt6-multimedia, which Quickshell does not depend on and
// Omarchy does not declare — on a machine without it, `import QtMultimedia` is
// a hard error at component load. Keeping it here means that error is confined
// to a Loader that reports Loader.Error, and the picker carries on showing
// stills, instead of taking the whole overlay down with it. Nothing outside
// this file may import QtMultimedia.
//
// The source is always a derivative thumbs.sh transcoded into our cache, never
// a theme's own file: our encoder wrote those bytes, and audio was dropped
// there rather than muted here.
Item {
  id: stage

  property url source: ""
  // Two stages, deliberately separate. `active` opens the file; `playing` runs
  // it. Loading a local clip measured ~115 ms, so doing it *after* an arming
  // delay put first motion at ~300 ms — past the 240 ms wipe, which is why the
  // clip appeared to start only once the transition had finished. Overlapping
  // the two puts motion inside the wipe.
  property bool active: false
  property bool playing: false

  // The parent cross-fades on this, so it must mean "there is a frame to
  // show", not merely "a file was opened".
  // Revealed only once playback has actually been issued, so the layer never
  // fades up on a frame that is sitting still — for an ARRIVE clip a held
  // frame 0 is a different picture from the still beneath it, and pausing
  // there would read as a stutter before the motion.
  readonly property bool showing: active && started
    && (player.mediaStatus === MediaPlayer.LoadedMedia
        || player.mediaStatus === MediaPlayer.BufferedMedia
        || player.mediaStatus === MediaPlayer.BufferingMedia
        || player.mediaStatus === MediaPlayer.EndOfMedia)

  signal failed()

  MediaPlayer {
    id: player
    source: stage.active ? stage.source : ""
    videoOutput: output
    audioOutput: null   // the derivative has no audio track; this is belt and braces

    // Played once and held on the final frame, not looped. Five of yamz8's
    // eight clips end exactly on their still, so holding there is already the
    // right resting state and the hand-off back to the still is a no-op. A
    // loop would instead jump-cut those five every time it wrapped.
    onMediaStatusChanged: {
      if (mediaStatus === MediaPlayer.InvalidMedia) stage.failed()
      else stage.maybePlay()   // the side that usually arrives last
    }
    onErrorOccurred: function(err, str) { console.warn("swatch/video: error", err, str); stage.failed() }
  }

  VideoOutput {
    id: output
    anchors.fill: parent
    // Must match how the stills are framed, or the swap shifts the picture.
    fillMode: VideoOutput.PreserveAspectCrop
  }

  // Playback cannot be started from onActiveChanged. player.source is bound to
  // `active`, so at the moment that handler runs the source is still the old
  // "" — play() there is a no-op on empty media, and by the time the real
  // source resolves and loads there is nothing left to start it. The clip then
  // sits loaded on frame 0, which for a DEPART clip is pixel-identical to the
  // still it belongs to: indistinguishable from the feature not working.
  //
  // So play when the media is actually ready, from whichever side arrives
  // last. `started` keeps it to once: after EndOfMedia we hold the final
  // frame rather than looping.
  property bool started: false

  function maybePlay() {
    if (!active || !playing || started) return
    if (player.mediaStatus === MediaPlayer.LoadedMedia
        || player.mediaStatus === MediaPlayer.BufferedMedia) {
      started = true
      player.play()
    }
  }

  // Never assign player.source here: it is bound to `active`, and an
  // imperative write would replace that binding with a dead value, so the
  // first disarm would silently kill every clip for the rest of the session.
  // Clearing is what the binding already does when active goes false.
  onActiveChanged: {
    if (active) maybePlay()
    else { player.stop(); started = false }
  }
  onPlayingChanged: if (playing) maybePlay()
}
