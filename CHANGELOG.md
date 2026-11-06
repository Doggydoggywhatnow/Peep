# Changelog

All notable changes to Peep.

## Unreleased

### Fixed
- Album art no longer glitches while the window is being resized. On Windows
  the window repaints a whole frame on each resize step. On Linux the X
  server no longer clears the window to black on each step.

## 0.2.0

### Added
- The window opens as a square.
- Album art from file tags (ID3v2, FLAC PICTURE, Ogg Vorbis pictures; JPEG,
  PNG, BMP, GIF). The window takes the cover's shape and can be scaled; later
  covers keep your size and change only shape.
- Tab shows title and artist from the tags, plus clickable previous,
  play/pause and next buttons.
- Shift+Tab blanks the screen to black while music keeps playing and the
  window keeps the cover's shape. Press it again to restore.
- Custom fonts (`.ttf`, `.otf`, `.ttc`) from a folder on the device. F cycles
  through them and the built-in font, and a notice in the top-left corner
  names the selected font.
  - Linux: `~/.local/share/peep/fonts`
  - Windows: `%APPDATA%\Peep\fonts` or a `fonts` folder next to `Peep.exe`
- Tag reader for ID3v1/v2, Vorbis comments and WAV `LIST/INFO`.

### Changed
- Fullscreen is F11 only, since F now cycles fonts.
- The I shortcut for the overlay is removed; Tab is the only toggle.
- Cover decoding and font rasterising use the public-domain `stb_image` and
  `stb_truetype` libraries behind the C shim.

### Known limits
- The built-in font covers ASCII only; load a TrueType font for other scripts.
- Tiling window managers on Linux ignore the aspect-ratio hints.
- The chosen font is not remembered between launches.

## 0.1.0

First version: a native assembly music player for Linux (AppImage) and
Windows (`.exe`). Drag and drop files or folders, no interface by default,
plays MP3, FLAC, Ogg Vorbis and WAV, runs entirely locally.
