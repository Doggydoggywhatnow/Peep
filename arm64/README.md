# Peep on ARM64: decoder test player

This branch swaps **lib-Peep's ARM64 WAV and FLAC decoders** (pure assembly) in
as the only decoders, behind a small player you can try on real hardware. It
is a **test vehicle for the decoders, not an ARM64 port of Peep**: Peep's
player core, drawing code and X11/ALSA layer are still x86-64 assembly (about
5,700 lines), so the player here is a small C front end (X11 + ALSA). The
decoders themselves are `peep.s` and `flac.s`.

Provenance: copied from [lib-Peep](https://github.com/Doggydoggywhatnow/lib-Peep)
(`arm64` branch, commit `17b85ae`, version 0.2.0, built from Peep 0.2.11).

## Build

On an ARM64 Linux machine (Raspberry Pi 4/5, an ARM server, an ARM laptop):

```sh
sudo apt install build-essential libx11-dev libasound2-dev     # as, gcc, headers
make a64                       # -> build/peep-a64
```

Cross-building from x86-64 (what produced the binary I tested):

```sh
make a64 CROSS=aarch64-linux-gnu- A64CC="aarch64-linux-gnu-gcc -idirafter /usr/include -L/usr/lib/aarch64-linux-gnu"
```

## Use

```sh
build/peep-a64 song.flac                 # one file
build/peep-a64 ~/Music                   # a folder (scanned for .wav and .flac, in path order)
build/peep-a64 --bench *.flac *.wav      # no window, no sound: decode, speed, checksum
```

A small window shows the track, format, a progress bar, time and buttons.
Space pause, left/right seek 10 s, up/down volume, `n`/`p` next/previous
(`p` restarts the track if more than 3 s in), `q` quit. Click the bar to seek.
The window also says what share of real time decoding takes, which is the
number the lib-Peep README lacks for ARM64 ("not timed on real hardware").

If there is no usable sound device the player says so and plays silently in
real time, which still exercises the decoders.

## Check the decoders on your hardware

```sh
make a64-test          # needs python3 + numpy
```

It runs lib-Peep's own suites against the ARM64 assembly: 2,505 WAV checks,
120 random FLAC streams checked against ground truth (all channel modes, 4 to
24 bits, every block-size code, LPC orders 1-32, ...), and a 100,000-input
fuzz run with guard pages around every buffer. On x86-64 it runs them under
QEMU: `make a64-test CROSS=aarch64-linux-gnu-` (uses `qemu-aarch64`).

`--bench` prints a checksum of the decoded audio. The same file gives the same
checksum from the x86-64 and ARM64 decoders, so you can compare machines.

## What was verified, and what was not

Verified here, on the actual ARM64 binary running under QEMU (user mode, ARM64
libX11 and libasound) against a virtual display and a model sound device:

* the decoder suites above: all pass (WAV 2505/2505, FLAC 120/120, fuzz clean);
* 12 files (mono, stereo, 6 and 8 channels, 16 and 24 bit, odd rates, random
  streams) decode to audio identical to the x86-64 decoders, and FLAC decodes
  to exactly the WAV it came from;
* in the player: clicking the bar lands on the exact frame, arrow keys jump
  exactly 10 s, volume goes to 25%, silence and back, next/previous switch and
  restart tracks, quitting is immediate, and tracks change with no silent gap.

Not verified, because nothing here is a real ARM64 machine:

* sound through a real ALSA device, and real timing (QEMU's figures are
  meaningless; run `--bench` on the board);
* the player under your window manager (the window is fixed-size);
* resuming after a pause can repeat a few frames (about 70 microseconds under
  emulation; the device queue is read and then dropped a moment later). Inaudible.

## Limits

WAV and FLAC only (that is all lib-Peep decodes; MP3 and Ogg are not ported).
No cover art, no drag and drop, no tag display (the file name is shown), no
resizing. This is a test player: Peep's real interface needs the full port.
