# Peep 0.4.4

A music player that is just a screen.

Peep opens as a black square. Drop a folder or some files on it and it
plays them, showing the album cover from the file's own tags. The window
takes the cover's shape, and you can drag it to any size, or click and drag
the cover to move it. Press **Tab** to show the track info and controls
whenever the pointer is over the window. Press **Shift+Tab** for nothing at all,
only black, while the music keeps playing.

Peep is machine-written x86-64 assembly. It runs entirely on your own machine.
It has no network code, no telemetry and no library database, and it never
writes to disk.

| Download | Platform |
|---|---|
| [`Peep-0.4.4-x86_64.AppImage`](releases/Peep-0.4.4-x86_64.AppImage) | Linux x86-64 |
| [`peep_0.4.4_amd64.deb`](releases/peep_0.4.4_amd64.deb) | Ubuntu 22.04+ / Debian 12+ (x86-64) |
| [`Peep-0.4.4.exe`](releases/Peep-0.4.4.exe) | Windows x64 |
| [`Peep-0.4.4-x86_64-musl`](releases/Peep-0.4.4-x86_64-musl) | Linux x86-64 with musl libc (Void musl, Alpine): one file, `chmod +x` and run |

## Philosophy

Most music players are built around *managing* music: libraries, playlists,
ratings, recommendations. Peep is built around *listening* to it.

* **The cover is the interface.** Album art was made to be looked at while
  the music plays. Peep gives it the whole window and takes its shape, so
  nothing competes with it. The controls exist, but stay out of sight until
  you reach for them, and fade away when you move on.
* **Nothing is also an option.** Shift+Tab leaves only black. Sometimes the
  best thing a player can show is nothing at all.
* **Your files are the library.** Your folders are already an order you
  chose. Peep reads titles, artists and covers straight from the files' own
  tags and plays in path order: no import step, no database to build or keep
  in sync.
* **It stays on your machine.** No network code, no telemetry, no accounts,
  and nothing written to disk. Peep can't share what you listen to because
  it has nowhere to send it, and it leaves no trace when it closes.
* **Small and immediate.** Assembly plus a handful of public-domain
  decoders: a single file of about 1 MB on Linux and 300 KB on Windows, with
  no installer and no runtime. It sleeps when nothing is happening and
  answers a key press at once.
* **Fewer features, on purpose.** Every feature has to earn its place against
  a quiet screen. There is no settings window, equalizer or visualizer. What
  is there works with a key, a click or a drag.

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
| Tab | info and controls on / off (shown while the pointer is over the window) |
| Shift+Tab | blank: black screen, music continues (again to restore) |
| G | next font (cycles through the fonts folder, then back to Default) |
| V | show the Peep version in the top-left box for 2 seconds |
| Space | pause / resume |
| ← / → | seek −10 s / +10 s |
| ↑ / ↓ | volume |
| N or Page Down | next track (on the last track it does nothing, and the music carries on) |
| P or Page Up | previous track (restarts the current one if more than 3 s in) |
| F | fullscreen; Esc leaves it. The pointer stays usable and hides, with the controls, once it stops moving |
| Q | quit |

With Tab on, the info and controls appear while the pointer is over the
window and fade out half a second after it leaves. The **⏮ ⏯ ⏭** buttons
are clickable. Click and drag anywhere else on the cover to move the window
(not in fullscreen).

In fullscreen the controls and the pointer follow the pointer: they show while it
moves, and when it has been still for two seconds the controls fade out and the
pointer hides with them. Move it and both come straight back.

### Custom fonts

Put `.ttf`, `.otf` or `.ttc` files in:

* **Linux**: `~/.local/share/peep/fonts` (or `$XDG_DATA_HOME/peep/fonts`)
* **Windows**: `%APPDATA%\Peep\fonts`, or a `fonts` folder next to
  `Peep.exe` (portable)

Press **G** to cycle through them. The folder is rescanned on every press,
so new fonts show up without restarting Peep. The top-left notice shows the
selected font's name, drawn in that font. The built-in 8×8 bitmap font is
**Default**. It covers ASCII only, so pick a TrueType font for accented or
non-Latin titles.

## Peep is opinionated

Peep is a small number of decisions made for you, and it would rather do those
well than offer a switch for everything. It will not grow:

* **No settings window and no config file.** The keys are fixed, and nothing is
  remembered between launches: Peep never writes to disk.
* **No library, playlists, ratings or queue editing.** A folder is the library,
  played in path order.
* **No skins or layouts.** The cover is the interface and the window takes its
  shape. The controls are one small row you only see when you reach for it.
* **No network.** No streaming, no cover or lyric lookups, no scrobbling, no
  update check.
* **No equalizer, visualizer or effects.**

If you want one of those, another player is the better choice. Peep's job is to
play your files and then get out of the way.

## What's inside

```
src/abi.inc     one calling-convention layer: the same sources assemble for
                System V (Linux) and Microsoft x64 (Windows)
src/core.asm    playlist, player thread, stereo mix + volume with a smooth
                ramp, track info hand-off to the UI
src/peep.asm    the decoder kernel: built-in 16-bit PCM WAV (every header
                layout), channel mapping to stereo, codec dispatch
src/wav.asm     the other WAV formats: unsigned 8-bit, 12/16/20/24/32-bit PCM,
                32/64-bit float, plain or extensible, 1 to 8 channels
src/flac.asm    native FLAC decoder: 4 to 31 bit, 1 to 8 channels, every
                stereo mode, every frame CRC-checked, seeking without a
                seek table
src/meta.asm    tag reader: ID3v2/v1, FLAC blocks, Ogg page reassembly,
                Vorbis comments, base64 pictures, WAV LIST/INFO
src/gfx.asm     cover scaling (box-filter halving + SSE2 bilinear), overlay,
                buttons, UTF-8 text layout, font cycling, window sizing
src/linux.asm   X11 window + XDND drag & drop, ALSA, aspect hints, resize sync, fonts dir
src/win32.asm   Win32 window + WM_DROPFILES, waveOut, WM_SIZING aspect lock
src/codecs.c    ~150-line shim over public-domain libraries (see below)
tests/          the test suite: drives the real program (see tests/README.md)
```

**About the C shim.** Peep's own code is all assembly. The shim connects it
to well-tested public-domain single-file libraries:

* `dr_mp3` (David Reid) and `stb_vorbis` decode MP3 and Ogg Vorbis. WAV (every
  PCM and float format) and FLAC are decoded by Peep's own assembly.
* `stb_image` decodes cover pictures.
* `stb_truetype` (Sean Barrett) rasterises font glyphs.

Tag parsing, image scaling, text layout and blending stay in assembly.
`make pure` builds a C-free Linux binary. It plays WAV and FLAC through
Peep's own decoders and reads tags, but has no MP3, Ogg, cover art or custom
fonts.

When nothing is changing, the UI thread sleeps until an event arrives. While
the overlay is visible and music is playing, it wakes once a second, when the
clock changes, and not at all while paused.

## Build

Requires `nasm`. For Linux you also need `gcc` and the libX11, libXext and libasound
development headers. For Windows you need `mingw-w64`, and for the AppImage,
`squashfs-tools`.

```sh
make            # build/peep
make pure       # build/peep-pure   (assembly-only)
make exe        # build/Peep.exe    (cross-compiled)
make deb        # build/peep_<version>_amd64.deb   (needs dpkg-deb)
make appimage RUNTIME=/path/to/runtime-x86_64
                # runtime from github.com/AppImage/type2-runtime/releases
make test       # run the test suite (about 2 minutes, see tests/README.md)
```

## Compatibility

* **Linux**: needs glibc 2.34+ (Ubuntu 22.04, Debian 12, Fedora 35 or newer),
  X11 or XWayland, and ALSA, which reaches PipeWire and PulseAudio through
  their ALSA plugins. Aspect-locked resizing depends on the window manager
  honouring size hints; most floating WMs do, and tiling WMs ignore them.
* **Linux CPU**: the Linux builds need SSE4.2 and POPCNT (any x86-64 CPU from 2009
  or later); an older CPU stops with "illegal instruction".
* **Linux with musl** (Void musl, Alpine): use the `-musl` download. It needs
  no glibc, only libX11, libXext and ALSA (on Void: `xbps-install libX11 libXext alsa-lib`).
  Build it yourself with `make musl` (needs `musl-gcc`).
* **Windows**: Windows 7 or later, x64. The exe isn't code-signed, so
  SmartScreen will warn the first time it runs.

## License

Peep is released into the public domain under [the Unlicense](LICENSE): use it,
change it and share it however you like, for any purpose, with no strings.
The libraries it bundles are public domain or MIT-0/MIT, so the same applies
to the combined program.
