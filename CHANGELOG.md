# Changelog

All notable changes to Peep.

## 0.6.2

### Added
- **A queue: hold Shift while dropping files** to add them to the end of the playlist
  instead of replacing it. The music keeps playing, no cut and no gap, and the new
  files play after the current list (sorted by path among themselves). A plain drop
  still replaces everything. On Linux (X11) and Windows this reads the Shift key at
  the moment of the drop; on Wayland it relies on the compositor passing the modifier
  to Peep during the drag, which may vary.
- **Text size: J makes the text larger, H smaller**, in steps from 50% to 200%, with a
  short "Text size 115%" notice. It applies to the title, artist and time text and
  costs one redraw per press. The size is not remembered between runs. The built-in
  8x8 font can only scale in whole multiples, so its steps are coarser than a
  TrueType font's.

## 0.6.1

### Added
- **A Wayland build.** `Peep-0.6.1-x86_64-wayland` is the same player with a native
  Wayland window, for GNOME, KDE, sway and the rest. It is a separate download; the
  AppImage, the .deb and the plain musl build are still the X11 program (X.Org, XLibre,
  XWayland) and are unchanged. Everything works the same: every key (found in your
  keyboard layout, held keys repeat), controls under the pointer, dragging the window by
  the cover, fullscreen with the pointer hiding, the window taking each cover's size and
  shape, and dropping files or folders. It is still assembly: Peep speaks the Wayland
  protocol itself, so it needs no libwayland, no libxkbcommon and no X11 libraries, only
  ALSA. Where the compositor offers a title bar (KDE, sway) Peep asks for one; where it
  does not (GNOME) the window is bare: drag the cover to move it, drag the outer 6 pixels
  to resize it, Q to close.
- Build it with `make wayland` (`build/peep-wayland`); `make musl` also builds
  `build/peep-wayland-musl`.
- Tests: `wayland_keys`, `wayland_pointer`, `wayland_drop` and `wayland_bare` run the
  Wayland build on a real compositor (sway, headless) with a virtual keyboard and pointer
  and a real drag and drop.

## 0.6.0

### Changed
- **Newest FLAC decoder from lib-Peep `dev`.** Optimised x86-64 decoder: 8-byte bit
  refill, `lzcnt`/BMI2 loops, an SSE4.1 predictor, a PCLMULQDQ CRC-16, one loop per
  predictor. Each is chosen by the CPU at run time and falls back to plain code. A
  300 s stereo file decodes about 25 to 30% faster than with the previous decoder
  (same machine, alternating runs). Fixes FLAC files whose STREAMINFO block size is 0
  ("unknown") and seeking in fixed-block-size files whose last block is short.
  `peep_open` also accepts sample rates from 1 Hz (Peep itself still plays 1,000 Hz
  and up). The program is larger: 390 KB on Linux (was 382 KB).

## 0.5.1

### Changed
- **No click when a track is cut off, and volume is heard at once.** Dropping new
  files while one plays, Next, Previous and the volume keys used to stop the sound
  device, throw away the audio waiting in it and start it again. That cut the old
  track in mid-wave (a click or crackle, issue #1) and, on a real sound system, could
  leave a small gap. Peep now takes the not-yet-played audio back from the device
  (`snd_pcm_rewind`) and keeps the device running: the old track ends at its
  quietest frame a few milliseconds later (the audio itself is unchanged), the new
  one follows at once, and a volume key is heard within about 11 ms with nothing
  dropped. If the sound system cannot take audio back (and on Windows), Peep does
  what it did before.
- **A bigger sound buffer (250 ms, was 100 ms)** on Linux, because nothing waits on
  it any more. It should help with the occasional stutter and short stops in long
  files (issues #2 and #3). Seek, pause and "previous restarts the track" still stop
  the device and can still click.
- Tested against a model sound device only; real sound systems (PipeWire, Pulse) and
  Windows were not run. The 250 ms buffer is not covered by any test.

## 0.5.0

### Added
- **Compressed WAV plays.** A-law, mu-law, IMA ADPCM and Microsoft ADPCM WAV files
  (the old telephone and game formats) now play: mono or stereo for ADPCM, up to
  eight channels for A-law and mu-law. They were the one WAV family 0.4.0
  dropped when `dr_wav` went. Seeking lands on the exact sample (it decodes from
  the start of the block that holds it).

### Changed
- **Faster FLAC.** The FLAC decoder is the newest from lib-Peep: the predictor
  now runs inside the residual loop, with SSE4.1 and BMI2 versions chosen by
  the CPU at run time (a CPU without them keeps the plain loop). A 300 s
  stereo file decodes in 69 ms instead of 94 ms (best of five, on a shared
  virtual machine). The audio is bit for bit the same.
- Tested with the full lib-Peep suites against Peep's own objects, and again with
  the SSE4.1 and BMI2 code switched off.

## 0.4.5

### Fixed
- **Volume keys never interrupt the sound.** A lone volume press, and the first
  repeat of a held key, used to stop the sound device, throw away the queued
  audio and start it again so the change was heard at once. On a real sound
  system that restart can leave a small gap, which showed as stuttering when
  you pressed or held the volume keys. Volume keys now only change the level,
  which glides smoothly into the next piece of audio. The change is heard after
  the audio already queued (up to about 0.1 s, plus your device's own delay)
  instead of nearly at once.

## 0.4.4

### Fixed
- **Spamming Next or Previous no longer flashes the covers in between.** When
  the keys come faster than a cover decodes (about 20 ms), the cover and title
  of a track that was only passed through are dropped instead of shown, so the
  window no longer briefly jumps to that cover's shape. In 10 of 10 test
  bursts the screen went straight to the last track (before, about 5 of 8
  flashed), with about a third of the CPU. A single press is as quick as before.

### Changed
- **Faster cover decoding on Linux.** The C code (cover, MP3 and Ogg decoders)
  is built with `-O3` for CPUs with SSE4.2 (any x86-64 CPU from 2009 on): PNG
  covers decode about a third faster (39 ms to 25 ms for a 1400x1400 image),
  JPEG about 1 ms faster. The pictures and audio are bit-for-bit identical.
  The cost is size: the Linux program is 378 KB (was 189 KB). Windows is
  unchanged.

## 0.4.3

### Changed
- **Key bursts are cheaper.** Many arrow-key presses in a row are now carried
  out as one seek, so 20 quick presses make one audio flush and 2 or 3 frames
  instead of 5 frames and 2 flushes. A lone press still reacts at once
  (key to sound about 5 ms, was 3).
- On Linux, a new picture is drawn at once, but further changes within 4 ms
  share one frame. A burst of volume presses draws 2 or 3 frames instead of 5.
- When Next or Previous is pressed many times quickly, the cover of a track
  that is only passed through is no longer decoded or shown, when Peep can
  tell in time. This helped in about 3 of 8 test bursts; a single press is as
  quick as before. (Windows keeps its old behaviour for the timing parts,
  because its clock is too coarse.)

## 0.4.2

### Fixed
- **No sound in 0.4.1 on real sound systems.** 0.4.1 waited for room in the
  sound device before writing, but a freshly opened ALSA device only starts
  playing once the first write fills it, so it waited forever and stayed
  silent. Peep now lets a device that is not yet playing start inside the
  write, as before. The test sound device now starts the way ALSA does, so
  this is caught by the tests. Sorry: 0.4.1 should not be used.

## 0.4.1

### Added
- **A build for musl Linux (Void musl, Alpine).** `Peep-0.4.1-x86_64-musl` is one
  file that asks for musl's loader, not glibc 2.34, so it runs where the other
  Linux downloads cannot. It needs libX11, libXext and ALSA, which those systems
  have. `make musl` builds it (with `musl-gcc`). Threads get an 8 MB stack there,
  because musl's default (128 KB) is too small for the decoders.
- Checked: the MP3, Ogg, FLAC and WAV decoders seek to exactly the right sample
  when run on musl's libc. Not yet run on a real musl desktop: the window and
  sound paths there are untested, so please report what you find.

### Fixed
- **Seeking is exact.** The arrow keys moved from where the decoder was, which
  runs about 0.1 s ahead of what you hear, so right skipped 10.1 s and left
  went back only 9.9 s. They now move exactly 10 s from the point being heard
  (measured on the audio itself).

### Changed
- **Keys are seen sooner.** The player only looked for keys between audio
  writes, and a write waits for room in the sound device, so a key could wait
  up to 23 ms. It now waits for room in 2 ms slices and looks for keys in
  between. Seek key to new sound: 22 ms before, about 1 ms now. Skip, volume,
  pause and quit go through the same loop and react as fast.

## 0.4.0

### Changed
- Peep's WAV and FLAC decoders are now the newest ones from the Liberated Peep
  project (lib-Peep 0.5.0), built straight into Peep's own assembly. The player
  calls them directly, with no wrapper layer in between.
- **WAV in assembly at every common depth.** Unsigned 8-bit; signed 12, 16, 20,
  24 and 32-bit PCM; 32-bit and 64-bit float; plain or extensible headers; one
  to eight channels; odd chunks, unknown lengths and truncated files. The C
  library `dr_wav` is removed.
- **Sturdier FLAC.** Every frame's checksum is verified, so a damaged frame is
  skipped cleanly instead of playing as noise. FLAC with 25 to 31 bits per
  sample now plays (0.3.0 stopped at 24), and ID3 tags placed in front of a
  FLAC stream are skipped.
- Smaller: the Linux program is 189 KB (218 KB in 0.3.0, 279 KB in 0.2.15) and
  the Windows `.exe` 219 KB (301 KB in 0.2.15).
- `make pure`, the build with no C at all, now plays every WAV format as well
  as FLAC.
- Verified: 20 test files played through the old and the new build, with the
  audio output compared byte for byte. 17 are identical, including 8-bit,
  24-bit and 32-bit PCM and both float formats. The other three are the
  removals below. The decoders also pass lib-Peep's own suites against Peep's
  exact objects, now part of `make test`: 2,505 16-bit WAV checks, the new
  WAV-format model, 120 random FLAC streams with seeks, 300 damaged streams,
  1,153 high-resolution output checks, and a 100,000-input fuzz run.

### Removed
- A-law, µ-law and ADPCM WAV files, and WAV files with more than eight
  channels, no longer play. The C library that handled them is gone. They are
  rare; ordinary PCM and float WAV are unaffected.
- FLAC with 32 bits per sample does not play. (The old C decoder, removed in
  0.3.0, accepted it; the native one stops at 31. Practically no FLAC is 32-bit.)

## 0.3.0

### Changed
- Peep now decodes FLAC and 16-bit PCM WAV with its own assembly decoders,
  which replace the `dr_flac` C library and the old WAV code. The decoders are
  the ones from the Liberated Peep (lib-Peep) project, brought in as part of
  Peep and adapted to its conventions. FLAC is checked against ground truth
  (120 random streams using every feature of the format, 285 seeks) and fuzzed
  with guard pages around every buffer; WAV against 2,505 checks of header
  layouts, chunk sizes, channel counts, volume and seeking. Those suites are
  now part of `make test`.
- The same 15 test files (WAV in five sample formats, FLAC mono / stereo /
  24-bit / 48 kHz / six-channel, MP3, Ogg) play with byte-for-byte identical
  output before and after the change.
- Smaller: the Linux program shrank from 279 KB to 218 KB and the Windows
  `.exe` from 301 KB to 247 KB, since `dr_flac` (about 90 KB) is gone.
- `make pure`, the assembly-only build with no C at all, now plays FLAC as well
  as WAV.
- MP3, Ogg Vorbis and the WAV formats that are not 16-bit PCM (24-bit, float,
  8-bit) still use the C libraries, now plugged in behind the new decoders.

### Removed
- FLAC files with more than 24 bits per sample no longer play. The old C
  decoder accepted up to 32 bits; the new one does 4 to 24. Such files are
  rare (the common high-resolution FLAC is 24-bit).

### Fixed
- The README said the clock wakes four times a second; since 0.2.9 it wakes
  once a second and not at all while paused.

## 0.2.15

### Changed
- Two keys changed places: **G** now cycles the font (it was F), and **F** now
  toggles fullscreen (it was F11). F11 no longer does anything. Esc still
  leaves fullscreen.

## 0.2.14

### Fixed
- A faint trace of the controls could stay on screen after they finished
  fading out. If drawing the last fade frame happened to take long enough to
  cross the end of the fade, nothing redrew to clear it. Peep now always draws
  one more frame when the controls are gone but the last frame still shows them.
  (Found because it made a test fail about one run in three.)

### Changed
- The title and artist are left-aligned again, in line with the time below
  them (0.2.13 had centred them).
- The title and artist text is a size smaller: for example at a 1020-pixel
  window the title letters are about 17% smaller. Small windows, whose text was
  already small, are unchanged. The time and track/volume text is unchanged.

## 0.2.13

### Fixed
- Holding a volume key no longer makes the sound stutter. Each key repeat used
  to drop the queued audio and decode it again (40 times in 3 seconds of
  holding a key, measured); now only a lone press does that, and held presses
  glide the volume smoothly instead of stepping it.
- Next on the last track no longer silently stops the music; it does nothing
  and the music carries on. Next and Previous skip past tracks you are passing
  over without opening them, so holding the key moves through a long folder
  quickly.

### Changed
- The on-screen controls are about 30% less tall (33.7% of the window before,
  about 23% now). The buttons now sit centred directly above the progress bar,
  sharing a row with the time on the left and the track number and volume on
  the right. The title and artist are centred above them, so the whole thing is
  balanced.
- Fullscreen keeps the pointer usable. The pointer and the controls show while
  the pointer moves; after two seconds without movement the controls fade out
  (the same half-second fade as usual) and the pointer hides with them. Moving
  it brings both back at once. Pointer movement costs nothing outside
  fullscreen.
- Entering and leaving fullscreen draw one or two frames, never one at the
  wrong size, and the controls no longer flicker from the pointer crossing the
  window edge during the change.
- The README now says plainly that Peep is opinionated, and what it won't do.

## 0.2.12

### Added
- Press **V** to see which version of Peep you are running: "Peep 0.2.12"
  appears in the top-left box for 2 seconds. It costs nothing while it's
  hidden, and the version comes from the same place as the release, so it
  can't go out of date.

## 0.2.11

### Added
- Peep is now released under the Unlicense (public domain). See `LICENSE`.
- A test suite, in `tests/` (run it with `make test`). It starts the real
  program on a virtual display, plays generated media through a model sound
  device, and checks the behaviour that matters: the clock reacts to a seek
  key in the same frame, pause silences the music at once and resume loses
  nothing, redraws happen only when something changed, controls fade out
  without a trace, no silence between tracks, the right cover for the right
  track, exact seeking in every format, and no memory errors under stress.
  Run against the 0.2.6 build, the seek, pause and redraw checks fail, as
  they should.

## 0.2.10

### Fixed
- Pausing now silences the music at once. Until now the sound device kept
  playing the audio already queued for it, so sound carried on for 100 ms
  or more after you pressed pause (measured: 100-123 ms). Peep now drops that
  queue and rewinds to the exact point you heard, so the sound stops within
  one audio chunk (about 20 ms, measured 6-22 ms) and resuming carries on
  from exactly where it stopped, with no gap and nothing repeated. The clock
  shows the heard position while paused.

### Checked, no change needed
- Quitting takes about 2-3 ms in every state (playing, paused, mid-seek,
  mid-skip).
- Moving on to the next track leaves no silent gap, even for MP3s with
  large covers.

## 0.2.9

### Faster
- Peep does much less work while the info and controls are showing. The
  clock changes once a second, but Peep used to redraw and upload the whole
  window four times a second, and kept doing it while paused. Now it wakes
  once per second, exactly when the clock changes, and not at all while
  paused. In a 1000x1000 window (measured, 10 seconds of playback):
  - playing with the controls showing: 90 ms of CPU, down to 40 ms
  - paused with the controls showing: 90 ms, down to about 10 ms
- The progress bar now advances once a second, together with the clock.

## 0.2.8

### Fixed
- The clock and progress bar now react to the ← / → seek keys at once. A
  press used to show up on screen only on the next clock tick, about a
  quarter of a second later (measured: 257 ms); now it appears in the same
  frame (under 1 ms). Peep shows the position plus any seek still waiting for
  the player, so every press in a quick series moves the clock, instead of
  only some of them.
- A seek (and a volume change) now redraws as soon as the player has carried
  it out; on both Linux and Windows that redraw used to wait for the next
  tick.

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
