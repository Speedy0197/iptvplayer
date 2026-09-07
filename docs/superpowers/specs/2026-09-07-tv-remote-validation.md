# TV remote validation

The TV home uses the approved groups / channels / preview layout. The live
player stays mounted while browsing; programme information follows the cursor.

## Automated coverage

- A held D-pad reaches channels beyond the first lazy viewport without tuning.
- Reordering and asynchronous group loading retain channel identity and scroll.
- Short OK opens fullscreen; held OK invokes channel options once.
- Back dismisses fullscreen controls, returns to the channel, then steps through
  groups and the main menu.
- Group and playlist browsing preserve the playing stream and its EPG.
- Search initializes the adjacent-channel playback queue.
- A failed group can be retried with OK on the same group.
- Fullscreen Retry survives a rebuilt preview, and successful playback removes
  the error overlay.
- Directional Android navigation selects the TV layout at an 800-pixel logical
  width, before the compact-layout breakpoint.
- EPG and recording actions target the correct playlist when browsing another
  source; asynchronous responses cannot replace newer selections.

## Device checks before shipping

Use an Android TV or Google TV device with the real remote and a representative
playlist. These checks need native video and remote hardware.

- Hold Down through at least 100 channels, then reverse direction. The cursor
  should remain visible and movement should stop on release.
- Play a channel, press Back, then browse another group and playlist. Video
  should continue, the playing marker should remain distinct, and returning to
  each group should restore its channel and viewport.
- Press OK to watch, OK to show controls, then Back twice. The first Back hides
  controls and the second returns to the same channel in the browser.
- Hold OK, dismiss channel actions, and immediately press Down. Focus should
  remain in the channel list.
- Search for a channel in another group, watch it, use Next/Previous, then Back.
- Verify Favorites, playlist selection, playlist management and programme
  recording actions with the remote alone.
- Try an unavailable stream. OK must retry from the error screen and Back must
  provide a path to channels. Check recording playback and seeking separately.
- Check text, focus contrast, overscan margins and remote repeat speed at the
  device's actual resolution and display scaling.

The layout capture in `flutter_app/build/tv-home-960x540.png` renders the actual
TV widgets with sample channels, programme data and a video placeholder. It is
not evidence of native media playback.
