# Handout: instant, click-free commands by rewinding the audio queue

For the agent implementing this. Read `AGENTS.md` first (assembly conventions,
both ABIs, `make test`). Work on branch `dev`. Delete this file when the work
is merged.

## Why (issues #1, #2, #3)

* **#1 crackle on drop.** `plat_audio_flush` (`snd_pcm_drop`) stops the
  speaker in mid-wave. That cut *is* the click. Commit 0f7fcef flushes first
  and then queues 6 ms of the old track, which is heard later as a second blip.
* **#2/#3 stutter (MP3 and FLAC).** Not the decoders: the device buffer is
  only 100 ms, so any hiccup longer than that is an underrun.
* The owner wants every command to be heard instantly, so "wait for the queue
  to play out" and "bigger buffer, laggier keys" are both rejected.

**The mechanism:** never drop the queue and never wait for it. Take back the
frames the device has not played yet (`snd_pcm_rewind`), and write something
else in their place: a 3 ms fade-out, or the same audio at the new volume.
Then the buffer can be large, because nothing waits on it.

Normal playback stays bit-exact. Only the last 128 frames of a track the user
interrupted are faded.

## Step 0: probe the owner's machine (do this before writing assembly)

Rewind works on ALSA `hw` and `dmix`. Through the PipeWire and PulseAudio ALSA
plugins it is **unverified**. Ask the owner to run this and paste the output
(do not commit it; the repo takes no new languages):

```c
/* cc probe.c -lasound -o probe && ./probe */
#include <alsa/asoundlib.h>
int main(void)
{
    snd_pcm_t *p;
    static short z[2 * 9600];                       /* 200 ms of silence */
    if (snd_pcm_open(&p, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) return 1;
    if (snd_pcm_set_params(p, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
                           2, 48000, 1, 250000) < 0) return 2;
    snd_pcm_writei(p, z, 9600);
    snd_pcm_sframes_t d = 0, a = snd_pcm_rewindable(p);
    snd_pcm_delay(p, &d);
    printf("delay %ld rewindable %ld rewind(%ld) -> %ld\n", (long)d, (long)a,
           (long)(a > 512 ? a - 512 : 0), (long)snd_pcm_rewind(p, a > 512 ? a - 512 : 0));
    snd_pcm_close(p);
    return 0;
}
```

* `rewindable` in the thousands and `rewind` returning the same number: go on.
* `rewindable 0` or a negative `rewind`: stop and tell the owner. The code
  below still falls back to today's behaviour, but it will not fix anything
  on that machine, and step 6 (bigger buffer) must **not** be done.

## Step 1: `plat_audio_rewind` (platform layer)

`plat_audio_rewind(keep, max) -> rax`: take back up to `max` queued frames,
always leaving `keep` frames ahead of the play point. Returns the frames taken
back, 0 if none (unsupported, not running, nothing queued).

`src/linux.asm`: add `snd_pcm_rewindable, snd_pcm_rewind` to the `extern`
line (27-29), and after `plat_audio_queued`:

```nasm
FUNC plat_audio_rewind, 0              ; (keep, max) -> rax frames taken back
    ARGS rbx, r12
    xor  r13d, r13d
    mov  A1, [pcm]
    test A1, A1
    jz   .r
    call snd_pcm_rewindable
    sub  rax, rbx                      ; errors are negative: also end up here
    jle  .r
    cmp  rax, r12
    jle  .n
    mov  rax, r12
.n: test rax, rax
    jle  .r
    mov  A1, [pcm]
    mov  A2, rax
    call snd_pcm_rewind
    test rax, rax
    jle  .r
    mov  r13, rax
.r: mov  rax, r13
    RET_
```

`src/win32.asm`: `waveOut` cannot rewind. Add a stub that returns 0, so
Windows keeps today's behaviour exactly:

```nasm
FUNC plat_audio_rewind, 0              ; waveOut cannot take audio back
    xor  eax, eax
    RET_
```

Also:
* `global plat_audio_rewind` wherever the other `plat_audio_*` are exported in
  each file, and `extern plat_audio_rewind ; (keep, max) -> rax` in
  `src/core.asm` next to line 21.
* `Makefile` line 78, `SYMS_ASOUND`: add `snd_pcm_rewind snd_pcm_rewindable`
  or the musl link fails.

## Step 2: `fade_cut` and a mute switch for `mix` (`src/core.asm`)

Data, next to `mix_gain` (line 66):

```nasm
mix_mute      dd 0          ; 1: mix() glides to silence (the end of a cut-off track)
vol_seen      dd 20         ; the g_volstep the queued audio was mixed at
```

Constants near the top (or in `abi.inc` beside `CHUNK`):

```nasm
FADE equ 128                ; frames of fade-out, ~3 ms
KEEP equ 512                ; frames never taken back, ~11 ms ahead of the speaker
```

In `mix`, right after `movzx r12d, word [rcx + rax*2]` (line 464):

```nasm
    cmp  dword [mix_mute], 0
    je   .nm
    xor  r12d, r12d                   ; target gain 0: the .ramp path fades out
.nm:
```

New function, before `play_track`:

```nasm
; fade_cut() -> eax 1 if the queued audio was replaced by a short fade-out of the
; track (it now ends in silence, a few ms from now), 0 if the device cannot take
; audio back: the caller then flushes as before.
FUNC fade_cut, 0
    xor  r12d, r12d
    mov  A1, KEEP
    mov  A2, [st_pos]                 ; never reach back into the previous track
    call plat_audio_rewind
    test rax, rax
    jle  .r
    mov  rbx, [st_pos]
    sub  rbx, rax
    lea  A1, [g_peep]
    mov  A2, rbx
    call peep_seek
    mov  [st_pos], rbx
    inc  r12d
    lea  A1, [g_peep]
    lea  A2, [decbuf]
    mov  A3, FADE
    call peep_fill
    test rax, rax
    jz   .r
    mov  rbx, rax
    mov  dword [mix_mute], 1
    mov  A1, rbx
    call mix
    mov  dword [mix_mute], 0
    lea  A1, [outbuf]
    mov  A2, rbx
    call plat_audio_write
    add  [st_pos], rbx
.r: mov  dword [mix_gain], -1         ; whatever plays next starts at its own gain
    mov  eax, r12d
    RET_
```

Why `max = st_pos`: at a track boundary the queue still holds the tail of the
previous track; rewinding past frame 0 of this one would re-decode the wrong
audio. With `st_pos` 0 it returns 0 and the caller flushes.

## Step 3: use it where a track is abandoned

Replace the whole `.newlist` block from 0f7fcef (keep the `dropfile` command
in `tests/drive.c`) and reroute `.flushout`:

```nasm
.newlist:
.flushout:
    cmp  dword [g_paused], 0          ; paused: the queue is already empty
    jne  .flush
    call fade_cut
    test eax, eax
    jnz  .out
.flush:
    call plat_audio_flush
.out:
    RET_
```

Careful: `.doskip` sets `g_paused` to 0 just before `jmp .flushout` (line
572). A skip while paused must still flush, so in `.doskip` jump to `.flush`
when `g_paused` was set, and only then clear it. This covers drop, next,
previous and seeking past the end. The device keeps running through the fade
into the new track; if the new file opens slowly it underruns in silence and
`snd_pcm_recover` restarts it, as it does today.

## Step 4: volume takes effect at once

Replace the comment block at `.noseek` (lines 633-639):

```nasm
.noseek:
    ; --- volume -----------------------------------------------------------
    ; The queued audio was mixed at the old volume. Take it back and decode it
    ; again: mix() glides to the new gain, so the key is heard within ~11 ms
    ; with no drop and no restart. If the device cannot take audio back, the
    ; change is heard when the queue has played, as before.
    mov  eax, [g_volstep]
    cmp  eax, [vol_seen]
    je   .novol
    mov  [vol_seen], eax
    cmp  dword [g_paused], 0
    jne  .novol
    mov  A1, KEEP
    mov  A2, [st_pos]
    call plat_audio_rewind
    test rax, rax
    jle  .novol
    mov  rbx, [st_pos]
    sub  rbx, rax
    lea  A1, [g_peep]
    mov  A2, rbx
    call peep_seek
    mov  [st_pos], rbx
.novol:
```

`mix_gain` still holds the old gain, so the next chunk ramps from it. Check
what the clock reads (`disp_pos`): `st_pos` now steps back by up to the queue
length on a volume key. If the clock is drawn from `st_pos` alone it could
show the previous second for a moment; `clock_cadence` and `volume_hold` will
tell. If it does, keep the displayed position monotonic rather than changing
this code.

## Step 5: tests (`tests/shim.c`, `tests/run.py`)

`tests/shim.c`, the model device, needs the two calls:

```c
snd_pcm_sframes_t snd_pcm_rewindable(snd_pcm_t *p)
{
    if (getenv("SIM_NO_REWIND")) return 0;
    pthread_mutex_lock(&mu);
    long r = ts0 ? queued() : 0;
    pthread_mutex_unlock(&mu);
    return r;
}

snd_pcm_sframes_t snd_pcm_rewind(snd_pcm_t *p, snd_pcm_uframes_t n)
{
    if (getenv("SIM_NO_REWIND")) return 0;
    pthread_mutex_lock(&mu);
    long q = queued();
    if ((long)n > q) n = q;
    heard_len -= n;
    wr -= n;
    if (heard_fd >= 0 && ftruncate(heard_fd, heard_len * 4) < 0) { }
    long after = heard_len;
    pthread_mutex_unlock(&mu);
    char b[96];
    put(log_fd, b, snprintf(b, sizeof b, "REWIND %.3f %ld %ld\n", now(), (long)n, after));
    return n;
}
```

Make `read_prog()` in `tests/run.py` skip or collect `REWIND` lines (it parses
`DROP` lines today; read it first).

Checks to write. Confirm each **fails on the current build**
(`PEEP_BIN=/path/to/old/peep python3 tests/run.py <check>`):

* Rewrite `drop_clean_cut` (rename `drop_fade`). For the same four delays:
  no `DROP` line after the drop mark; everything heard before the fade equals
  file A exactly; the last `FADE` frames before B starts are A's own frames
  scaled down (same sign, `|heard| <= |A| + 1`) and the final one is under
  400 of 24000; B is heard within 40 ms of the drop.
* `volume_instant`: one volume key while a ramp or tone plays. The gain of
  the heard audio changes within 30 ms of the key; no `DROP`; dividing out the
  gain, the heard frames are the file's frames in order, none repeated or
  skipped.
* `rewind_fallback`: run `drop` and a volume key with `SIM_NO_REWIND=1` and
  assert today's behaviour (a `DROP` on the drop, playback continues, audio
  intact). This is also what Windows does.
* Extend `track_keys` or add `skip_fade`: Next mid-track ends in a fade, no
  `DROP`.

Then `make test` (all of it, ~2 minutes) and `make musl`, and assemble all
three targets (`-f elf64`, `-f win64 -DWIN64`, `-f elf64 -DPURE`). Add the new
checks to the table in `tests/README.md`.

## Step 6: the stutter fix (only if step 0 passed)

`src/linux.asm:1562`: `100000` -> `250000` (and the comment). With rewind
working, nothing waits on the buffer, so this costs no responsiveness. The
model device in `tests/shim.c` ignores `snd_pcm_set_params` and stays at
100 ms, so this line is **not covered by any test**: say so. Ask the owner to
listen to a long file for the stutter after this change; it is the only real
check.

Do not change `NBUF` in `win32.asm`: without rewind a bigger buffer there
would make volume keys lag.

## Not in this change (needs the owner's yes first)

Seek, pause and "previous = restart" still flush, so they can still click.
The same `fade_cut` call fixes them (for seek: `fade_cut`, then `peep_seek` to
the target; for pause: `fade_cut` and let the device run dry). But
`pause_silence` and `seek_audio_integrity` assert bit-exact audio up to the
cut, and would have to allow the 128 faded frames. That is a change to what
the tests promise, so propose it; do not do it unasked.

## Finishing

* This changes what ships: patch bump and a plain-language CHANGELOG entry
  per `AGENTS.md` "Releasing". Build release files only if the owner asks.
* Report honestly: rewind was exercised only against the model device; real
  hardware, PipeWire and PulseAudio behaviour come from the owner's probe and
  ears; Windows is unchanged and was not run.
* Update `AGENTS.md` (platform layer list, "Threads and shared state": no
  command drops the queue when the device can rewind) and delete this file.
