const double kCompactBreakpoint = 900;
const Duration kTabAnimation = Duration(milliseconds: 220);

// Android TV layout tuning. Applied only when isAndroidTv(context) is true.
// Side pane widths on TV (wider than the 280 desktop default so larger fonts
// don't overflow channel/group names).
const double kTvPlaylistsColumnWidth = 360;
const double kTvChannelsColumnWidth = 380;

// Embedded (non-fullscreen) player size cap on TV. The default desktop clamp
// of 400 leaves the player feeling small on a couch-distance TV.
const double kTvPlayerMaxHeight = 560;

// Text + tile scaling on TV. The whole textTheme is multiplied by this factor;
// list tiles get a taller min height for better D-pad framing.
const double kTvFontScale = 1.25;
const double kTvListTileMinHeight = 64;

// How many upcoming EPG entries to render on TV. Larger fonts + extra padding
// per card means fewer fit comfortably than on desktop.
const int kTvEpgEntriesToShow = 4;
const int kDesktopEpgEntriesToShow = 5;

// Long-press threshold for the OK/Select button on TV.
const Duration kTvLongPressDuration = Duration(milliseconds: 500);
