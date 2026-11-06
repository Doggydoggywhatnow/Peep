# Peep 0.1.0

A music player that is just a screen.

Drop a folder or some files on the window and it plays. By default there is
no interface at all: a black window. Press **Tab** to show a single line of
information along the bottom edge, and press it again to hide it.

Peep is hand-written x86-64 assembly. It runs entirely on your own machine.
It has no network code, no telemetry, no config files, no library database,
and it never writes to disk.

| Download | Size |
|---|---|
| `Peep-x86_64.AppImage` (Linux) | ~1 MB (≈940 KB of that is the standard AppImage runtime) |
| `Peep.exe` (Windows, x64) | ~205 KB |

## Use

* **Drag & drop** a folder or files onto the window. Folders are scanned
  recursively for `mp3 flac ogg oga wav` and played in path order. A new
  drop replaces the queue. Dropping something that isn't audio is ignored
  and the music keeps playing.
* Or open with Peep: `peep ~/Music/Album` / `Peep.exe "D:\Music"` / *Open with…*

| Key | Action |
|---|---|
| Space | pause / resume |
| ← / → | seek −10 s / +10 s |
| ↑ / ↓ | volume |
| N or Page Down | next track |
| P or Page Up | previous track (restarts the current one if more than 3 s in) |
| Tab or I | show / hide the overlay |
| F or F11 | fullscreen (pointer hidden); Esc leaves it |
| Q | quit |

## What's inside

```
src/abi.inc     one calling-convention layer so the same core assembles for
                System V (Linux) and Microsoft x64 (Windows)
src/core.asm    playlist, player thread, native 16-bit WAV decoder,
                stereo mix + volume, software renderer, 8x8 bitmap font
src/linux.asm   X11 window, XDND drag & drop, ALSA output, folder scan, mmap
src/win32.asm   Win32 window, WM_DROPFILES, waveOut output, folder scan,
                memory-mapped files, fullscreen
src/codecs.c    ~100-line shim over public-domain decoders (see below)
```

**About the codecs.** All of Peep's own code is assembly. MP3, FLAC and Ogg
Vorbis decoding (and the less common WAV variants) come from four
well-tested public-domain single-file libraries: `dr_mp3`, `dr_flac` and
`dr_wav` by David Reid, and `stb_vorbis` by Sean Barrett. They are compiled
in statically. `src/codecs.c` is the only C file, and it only routes calls.
If you want zero C, `make pure` builds a 28 KB Linux binary that plays 16-bit
PCM WAV with Peep's own assembly decoder and nothing else.

Files are memory-mapped and decoded straight from memory. The UI thread
sleeps until an event arrives. While the overlay is visible it wakes four
times a second to update the clock.

## Build

Requires `nasm`. For Linux you also need `gcc` and the libX11 and libasound
development headers. For Windows you need `mingw-w64`, and for the AppImage,
`squashfs-tools`.

```sh
make            # build/peep
make pure       # build/peep-pure   (assembly-only, WAV only)
make exe        # build/Peep.exe    (cross-compiled)
make appimage RUNTIME=/path/to/runtime-x86_64
                # runtime from github.com/AppImage/type2-runtime/releases
```

## Compatibility

* **Linux**: needs glibc 2.34+ (Ubuntu 22.04, Debian 12, Fedora 35 or newer),
  X11 or XWayland, and ALSA, which reaches PipeWire and PulseAudio through
  their ALSA plugins on every mainstream desktop.
* **Windows**: Windows 7 or later, x64. The exe isn't code-signed, so
  SmartScreen will warn the first time it runs.
* Track titles are drawn in ASCII. Non-Latin characters show as `?`, but
  the files themselves play fine whatever their names.
