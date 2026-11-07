# Peep tests

```sh
make test                         # build Peep and run everything (~2 minutes)
python3 tests/run.py --list       # what each check proves
python3 tests/run.py pause_silence quit_speed    # just these
PEEP_BIN=/path/to/other/peep python3 tests/run.py   # test a different build
```

Each check starts the real Peep on a private virtual display (Xvfb), plays
generated test media through a model sound device, and drives it with key
presses and pointer moves, the way a person would. Nothing needs a screen, a
sound card or a window manager. Results are `PASS`, `FAIL` or `SKIP` (a tool is
missing); the exit code is 1 if anything fails.

| Check | What it proves |
|---|---|
| `resize_sync` | the window manager is asked to wait for each frame while resizing (smooth drag): 40 of 40 steps acknowledged |
| `hover_fade_drag` | controls show only under the pointer and fade out in 0.5 s, leaving no trace; a click on the art starts a window drag, a click on a button does not |
| `seek_latency` | the clock changes in the same frame as an arrow key (under 20 ms; it used to take 250 ms) |
| `seek_settle` | after bursts of arrow keys the clock reads the right time, e.g. `RR` and `R.R.L.R` agree |
| `pause_silence` | the sound stops within ~one audio chunk of pausing (under 40 ms; it used to take 110 ms), and the audio heard across pause and resume is identical to the file: no gap, nothing repeated |
| `seek_audio_integrity` | seeking never garbles the audio: between seeks every sample heard is exactly the file's next one (no wrong, repeated, skipped or silent samples), through slow, rapid, paused and held-key seeking and the clamp at the start; the sound drops out for under 25 ms after each seek |
| `seek_efficiency` | what an arrow key costs: a lone press reaches the audio within 8 ms and is heard within 12 ms (it was 22 ms before the player stopped waiting inside the audio write), with exactly one audio seek per press; six quick presses cause at most six |
| `key_efficiency` | every key once (pause, resume, seek both ways, volume both ways, next, previous, controls on/off, blank on/off, font, version, quit): time until the screen changes, frames drawn, time until the audio reacts and is heard. Fails if any key takes over 50 ms to change the screen. Every number is written to `build/tests/efficiency/keys.json` and `keys.txt` |
| `render_efficiency` | drawing: frames and CPU per frame (from `/proc/<pid>/schedstat`) with the controls hidden (must draw nothing), shown, fading in and out, in a 24-step resize drag (time until a frame with the new size) and entering/leaving fullscreen, with every frame time recorded in `build/tests/efficiency/render.json` and `render.txt` |
| `key_spam` | spams every key as fast as the X server takes it (~12,000 a second; 40 presses, 20 for seek/next/previous): Peep stays alive, stops drawing within 300 ms of the last key, the audio never stalls over 150 ms and is still playing, all 20 seek keys count (exactly +200 s, then -200 s), audio between seeks is the file sample for sample, 20 Nexts end on the last cover and 20 Previouses on the first, quit is still instant. Lag, frames, audio drops, stalls and CPU per key go to `build/tests/efficiency/spam.json` and `spam.txt` (~8 s) |
| `arrow_seek` | the arrow keys move playback by exactly 10 s: right +10, left -10, three quick presses +30, left/left/right nets -10, and left with less than 10 s played stops at 0:00; measured on the audio actually played, not the clock |
| `pause_seek_resume` | seeking while paused, then resuming, plays from exactly 10 s later |
| `clock_cadence` | with the controls shown Peep redraws once a second, never for nothing, and not at all while paused; a font notice still expires |
| `volume_hold` | holding a volume key (key repeat) never drops the audio queue or stalls the sound, and the gain glides instead of stepping |
| `track_keys` | Next/Previous react in under 80 ms, land on the right track, quick presses settle fast, and Next on the last track is a no-op that doesn't interrupt the music |
| `fullscreen_pointer` | fullscreen keeps the pointer usable; after 2 s of stillness the controls fade (0.5 s) and the pointer hides with them, and both return at once on movement; entering and leaving draw 1-3 frames, all at the right size |
| `version_notice` | V shows "Peep X.Y.Z" for 2 s, costs two frames, and matches the README |
| `quit_speed` | Q exits within milliseconds while playing, paused, seeking and skipping |
| `track_gap` | moving to the next track leaves no silent gap |
| `cover_per_track` | the cover on screen is the playing track's, even after rapid skipping |
| `codec_seek` | seeking lands on exactly the right samples in MP3, Ogg, FLAC and WAV |
| `wav_decoder` | the built-in 16-bit WAV decoder against 2,505 checks: header variants, chunk layouts, channel counts, volume, seeking, files that must be rejected (needs numpy) |
| `wavx_decoder` | the other WAV formats (8/12/16/20/24/32-bit PCM, 32/64-bit float, extensible headers, truncation) against an independent model (needs numpy) |
| `flac_crc` | damaged FLAC frames are caught by their CRC-16, counted, and skipped without stopping playback (needs numpy) |
| `hires_output` | full-resolution output, volume and the 16-bit conversion, bit-exact against a model. One group of cases (a 16-bit-only codec) needs `dr_flac`, which Peep no longer has, so it is skipped with `--no-legacy` (needs numpy) |
| `flac_decoder` | the native FLAC decoder against ground truth: 120 random streams using every feature of the format, with seeks (needs numpy) |
| `decoder_fuzz` | 100,000 mutated WAV/FLAC inputs with guard pages around every buffer: no out-of-bounds read or write (needs numpy) |
| `stress_valgrind` | rapid skipping and fullscreen toggling cause no memory errors |

## Groups

`python3 tests/run.py seeking` runs the whole seeking suite: `seek_latency`, `seek_settle`,
`arrow_seek`, `seek_audio_integrity`, `seek_efficiency`, `pause_seek_resume` and `codec_seek`. (`--list` shows the groups.)

`python3 tests/run.py efficiency` runs the timing checks (`key_efficiency`, `render_efficiency`,
`seek_efficiency`, `key_spam`). The first two write their raw numbers under `build/tests/efficiency/`.

## Needs

`python3`, `gcc`, `Xvfb`, the X11 and ALSA development headers (the same ones
Peep needs to build), and for the media checks `ffmpeg` and Pillow
(`python3 -m pip install pillow`). `stress_valgrind` also needs `valgrind`.
Anything missing skips only the checks that use it.

## How it works

- `run.py` builds the helpers into `build/tests/`, starts Xvfb, generates the
  media (cached in `build/tests/assets/`), and runs the checks.
- `shim.c` is preloaded into Peep. It replaces ALSA with a model 44.1 kHz
  device with a 100 ms buffer, and records exactly which audio would be heard
  and when. It also logs a checksum of every frame Peep draws.
- `drive.c` plays the user, and the window manager where needed (it grants
  map and resize requests, as a real one does).
- `codec_seek.c` tests the decoders directly, without a window.

The checks measure behaviour that has gone wrong before, so each one fails on
the build that had the bug: run the suite with `PEEP_BIN` pointing at 0.2.6
and `seek_latency`, `pause_silence` and `clock_cadence` fail.

Not covered: the Windows build (it needs Windows), a real sound server, and
real window managers. The timings are from a model device, so treat them as
"never worse than this" rather than what your sound server will measure.
