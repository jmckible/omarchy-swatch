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
  property bool active: false

  // The parent cross-fades on this, so it must mean "there is a frame to
  // show", not merely "a file was opened".
  readonly property bool showing: active
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

    // Played once and held on the final frame, not looped. Four of yamz8's
    // eight clips end exactly on their still, so holding there is already the
    // right resting state and the hand-off back to the still is a no-op. A
    // loop would instead jump-cut those four every time it wrapped.
    onMediaStatusChanged: if (mediaStatus === MediaPlayer.InvalidMedia) stage.failed()
    onErrorOccurred: stage.failed()
  }

  VideoOutput {
    id: output
    anchors.fill: parent
    // Must match how the stills are framed, or the swap shifts the picture.
    fillMode: VideoOutput.PreserveAspectCrop
  }

  onActiveChanged: {
    if (active) player.play()
    else { player.stop(); player.source = "" }
  }
}
