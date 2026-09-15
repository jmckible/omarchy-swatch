import QtQuick
import QtMultimedia

// The animated half of a background, isolated in its own file on purpose.
//
// MediaPlayer lives in qt6-multimedia, which Quickshell does not depend on.
// Omarchy does declare it now, since native video wallpapers (#6792), but an
// install predating that migration still lacks it and nothing stops this plugin
// being mounted outside Omarchy — and `import QtMultimedia` is a hard error at
// component load, not a runtime miss. Keeping it here means that error is
// confined to a Loader that reports Loader.Error, and the picker carries on
// showing stills, instead of taking the whole overlay down with it. Nothing
// outside this file may import QtMultimedia.
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

  // Open and able to start on the next frame. The parent reads this to decide
  // whether arming can skip its debounce: a clip already open plays inside the
  // wipe that revealed it, where one still opening cannot and arrives after.
  readonly property bool loaded: active
    && (player.mediaStatus === MediaPlayer.LoadedMedia
        || player.mediaStatus === MediaPlayer.BufferedMedia
        || player.mediaStatus === MediaPlayer.EndOfMedia)

  // A decoded frame is up and will stay up. Distinct from `showing`, which means
  // "playing this clip" and goes false the moment the clip hands off — while the
  // frame it left behind is still on screen and still needed, because the clip
  // taking over has to dissolve over something opaque rather than over the still.
  property bool framed: false
  onShowingChanged: if (showing) framed = true

  readonly property bool motionPlaying: showing && player.playbackState === MediaPlayer.PlayingState

  signal failed()

  MediaPlayer {
    id: player
    source: stage.active ? stage.source : ""
    videoOutput: output
    audioOutput: null   // the derivative has no audio track; this is belt and braces

    // Played once and held on the final frame, not looped. 73 of the 77 clips
    // end exactly on their still, so holding there is already the right resting
    // state and the hand-off back to the still is a no-op. A loop would instead
    // jump-cut those 73 every time it wrapped.
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
    if (!active || !playing || started || !loaded) return
    started = true
    // A slot now holds one clip across many arrivals, so the position has to be
    // taken back explicitly. Without this, returning to a background whose clip
    // already ran finds the player parked on EndOfMedia and plays nothing — and
    // EndOfMedia is counted as loaded precisely so that arrival can be instant.
    player.position = 0
    player.play()
  }

  // Never assign player.source here: it is bound to `active`, and an
  // imperative write would replace that binding with a dead value, so the
  // first disarm would silently kill every clip for the rest of the session.
  // Clearing is what the binding already does when active goes false.
  onActiveChanged: {
    if (active) maybePlay()
    else { player.stop(); started = false; framed = false }
  }

  // Handed off to whichever slot is now live. Pause rather than stop: stop
  // blanks the VideoOutput, and this layer is still fading out *over* the
  // incoming one, so a blanked frame would put a black hole exactly where the
  // cross-fade is meant to be seamless. Pausing holds the last frame for the
  // length of the fade. Clearing `started` is what lets the next arrival replay
  // from the top rather than finding the clip already spent.
  onPlayingChanged: {
    if (playing) maybePlay()
    else if (started) { player.pause(); started = false }
  }

  // `started` is per-clip, so it has to clear when the clip changes and not
  // only when the player is torn down. Moving between two animated backgrounds
  // deliberately never drops `active` — there is no rapid scrub to drop it —
  // so the flag survived from the previous clip and maybePlay returned early:
  // the new file loaded and then sat there. Playing worked once per session of
  // continuous availability, which read as intermittent.
  //
  // This is now the rare path rather than the usual one: the parent keeps one
  // slot per clip, so a slot's source changes only when its key is evicted, not
  // on every move. The hand-off between clips runs through `playing` above.
  onSourceChanged: { started = false; framed = false }
}
