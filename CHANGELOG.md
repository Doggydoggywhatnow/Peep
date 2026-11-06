# Changelog

All notable changes to Peep.

## 0.2.7

### Faster
- Peep starts much faster when opened with files. On a typical desktop the
  cover used to appear about 150 ms after launch, as a black square that then
  jumped to the cover's size. Now the window appears already at the cover's
  size and shape, with the cover in it, about 20 ms after launch.
  - Playback starts before the window is built, so opening the sound device
    (the slowest step with PipeWire or PulseAudio) overlaps with setting up
    the window.
  - The cover is decoded on its own thread, alongside the audio, and shown
    as soon as it's ready. Neither waits for the other.
  - Peep waits for the first cover, at most 0.3 s, before showing the window.
- Window setup asks the X server for everything in one round trip, and the
  invisible fullscreen cursor is only created the first time you go
  fullscreen.

## 0.2.6

### Added
- A Debian / Ubuntu package, `peep_0.2.6_amd64.deb`, built with `make deb`.
  It installs Peep with a menu entry and icon; install it with
  `sudo apt install ./peep_0.2.6_amd64.deb`.
- The README explains the philosophy behind Peep: why the cover is the
  interface, why there's no library or settings, and why it stays local.

## 0.2.5

### Faster
- Arrow keys respond at once:
  - Seeking back in an MP3 no longer decodes the file again from the start.
    The worst case measured on a 5-minute track went from 187 ms to under
    1 ms. Peep builds a seek index the first time you seek in a track, which
    takes about 2 ms for a typical song.
  - The time display updates as soon as a seek happens, instead of on the
    next clock tick (up to a quarter second later).
  - Volume changes are heard immediately. Peep re-mixes the audio already
    queued for the sound device (~100-190 ms) at the new volume.
- New tracks start sooner: the cover picture is decoded once the audio is
  already playing, so a large cover (10-50 ms to decode) no longer delays
  the music.
- Drawing the info and controls takes about half the work per frame:
  - Text in a custom font is rasterized once and then reused, instead of on
    every frame.
  - The fade-out blends only the part of the window the controls cover.
  - The shading behind the controls handles four pixels per step.

## 0.2.4

### Changed
- The AppImage now starts Peep directly: its launcher is a link to the
  program instead of a small shell script. Nothing changes when you run it.
- The repository no longer contains any shell script, and GitHub's language
  bar no longer counts the Makefile.

## 0.2.3

### Changed
- With Tab on, the track info and controls now show only while the pointer
  is over Peep's window. When the pointer leaves, they fade out over half a
  second, leaving just the cover.

### Added
- Click and drag anywhere on the cover (away from the buttons) to move the
  window, like dragging a title bar. Not available in fullscreen.

## 0.2.2

### Fixed
- Linux: resizing the window is now smooth. Peep now tells the window
  manager when each new size has been drawn (`_NET_WM_SYNC_REQUEST`), so it
  no longer shows stale or half-drawn rectangles of the cover while you
  drag. This works with window managers that support it, including GNOME,
  KDE and Xfce.

### Changed
- The Linux build also links libXext, for the X Sync extension.

## 0.2.1

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
