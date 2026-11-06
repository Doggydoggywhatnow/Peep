# Peep 0.2.1

A music player that is just a screen.

Peep opens as a black square. Drop a folder or some files on it and it
plays them, showing the album cover from the file's own tags. The window
takes the cover's shape, and you can drag it to any size. Press **Tab** to
show the track info and controls. Press **Shift+Tab** for nothing at all,
only black, while the music keeps playing.

Peep is hand-written x86-64 assembly. It runs entirely on your own machine.
It has no network code, no telemetry and no library database, and it never
writes to disk.

| Download | Platform |
|---|---|
| `Peep-0.2.1-x86_64.AppImage` | Linux x86-64 |
| `Peep-0.2.1.exe` | Windows x64 |

## Use

* **Drag & drop** a folder or files onto the window, or *Open with* Peep.
  Folders are scanned recursively for `mp3 flac ogg oga wav` and played in
  path order. A new drop replaces the queue.
* **Cover art** is read from the files' tags: ID3v2 (APIC/PIC), FLAC
  PICTURE blocks, and Ogg Vorbis `METADATA_BLOCK_PICTURE` or `COVERART`.
  The front cover wins when a file has several pictures. JPEG, PNG, BMP and
  GIF are supported.
* **Window shape**: the first cover opens at its own pixel size, fitted to
  85% of the screen. Resizing keeps the cover's aspect ratio. After you've
  scaled the window, later covers keep your size and only change shape.
  Tracks without art keep the current window and show black.
* **Title / artist** come from ID3v2 (2.2–2.4, every text encoding), ID3v1,
  Vorbis comments and WAV `LIST/INFO`. When a file has none, the file name
  is used.

| Key | Action |
|---|---|
| Tab | show / hide info and controls |
| Shift+Tab | blank: black screen, music continues (again to restore) |
| F | next font (cycles through the fonts folder, then back to Default) |
| Space | pause / resume |
| ← / → | seek −10 s / +10 s |
| ↑ / ↓ | volume |
| N or Page Down | next track |
| P or Page Up | previous track (restarts the current one if more than 3 s in) |
| F11 | fullscreen (pointer hidden); Esc leaves it |
| Q | quit |

The overlay's **⏮ ⏯ ⏭** buttons are clickable.

### Custom fonts

Put `.ttf`, `.otf` or `.ttc` files in:

* **Linux**: `~/.local/share/peep/fonts` (or `$XDG_DATA_HOME/peep/fonts`)
* **Windows**: `%APPDATA%\Peep\fonts`, or a `fonts` folder next to
  `Peep.exe` (portable)

Press **F** to cycle through them. The folder is rescanned on every press,
so new fonts show up without restarting Peep. The top-left notice shows the
selected font's name, drawn in that font. The built-in 8×8 bitmap font is
**Default**. It covers ASCII only, so pick a TrueType font for accented or
non-Latin titles.

## What's inside

```
src/abi.inc     one calling-convention layer: the same sources assemble for
                System V (Linux) and Microsoft x64 (Windows)
src/core.asm    playlist, player thread, native 16-bit WAV decoder,
                stereo mix + volume, track info hand-off to the UI
src/meta.asm    tag reader: ID3v2/v1, FLAC blocks, Ogg page reassembly,
                Vorbis comments, base64 pictures, WAV LIST/INFO
src/gfx.asm     cover scaling (box-filter halving + SSE2 bilinear), overlay,
                buttons, UTF-8 text layout, font cycling, window sizing
src/linux.asm   X11 window + XDND drag & drop, ALSA, aspect hints, fonts dir
src/win32.asm   Win32 window + WM_DROPFILES, waveOut, WM_SIZING aspect lock
src/codecs.c    ~150-line shim over public-domain libraries (see below)
```

**About the C shim.** Peep's own code is all assembly. The shim connects it
to well-tested public-domain single-file libraries:

* `dr_mp3`, `dr_flac`, `dr_wav` (David Reid) and `stb_vorbis` decode audio.
* `stb_image` decodes cover pictures.
* `stb_truetype` (Sean Barrett) rasterises font glyphs.

Tag parsing, image scaling, text layout and blending stay in assembly.
`make pure` builds a C-free Linux binary. It plays 16-bit PCM WAV through
Peep's own decoder and reads tags, but has no cover art and no custom fonts.

When nothing is changing, the UI thread sleeps until an event arrives. While
the overlay is visible, it wakes four times a second to update the clock.

## Build

Requires `nasm`. For Linux you also need `gcc` and the libX11 and libasound
development headers. For Windows you need `mingw-w64`, and for the AppImage,
`squashfs-tools`.

```sh
make            # build/peep
make pure       # build/peep-pure   (assembly-only)
make exe        # build/Peep.exe    (cross-compiled)
make appimage RUNTIME=/path/to/runtime-x86_64
                # runtime from github.com/AppImage/type2-runtime/releases
```

## Compatibility

* **Linux**: needs glibc 2.34+ (Ubuntu 22.04, Debian 12, Fedora 35 or newer),
  X11 or XWayland, and ALSA, which reaches PipeWire and PulseAudio through
  their ALSA plugins. Aspect-locked resizing depends on the window manager
  honouring size hints; most floating WMs do, and tiling WMs ignore them.
* **Windows**: Windows 7 or later, x64. The exe isn't code-signed, so
  SmartScreen will warn the first time it runs.
