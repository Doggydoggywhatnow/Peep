; ============================================================================
; Peep — shared core (platform independent)
;
;   * playlist objects
;   * the player thread: decode -> stereo mix + volume -> platform audio
;   * native 16-bit PCM WAV decoder
;   * software renderer: black screen, optional minimal overlay, 8x8 font
;   * key handling
;
; Threads: the UI thread (platform main loop) only ever *writes* the command
; variables below and *publishes* new playlists with an atomic xchg. The
; player thread owns the decoder, the audio device and the current playlist.
; ============================================================================
default rel
%include "abi.inc"

; ---- platform layer (src/linux.asm or src/win32.asm) -----------------------
extern plat_audio_open      ; (rate) -> eax 0 = ok
extern plat_audio_write     ; (stereo_s16_buf, frames)
extern plat_audio_flush     ; ()
extern plat_audio_close     ; (drain)
extern plat_audio_queued    ; () -> rax frames written but not yet heard
extern plat_audio_wait      ; () -> eax 1 = room for a chunk, 0 = not yet (waits a couple of ms)
extern plat_map             ; (path, &len) -> rax ptr | 0
extern plat_unmap           ; (ptr, len)
extern plat_sleep           ; (ms)
extern plat_title           ; (path, out, max)  ASCII display name
extern plat_cmp             ; qsort comparator for native path strings
extern plat_wake            ; () nudge the UI thread
extern plat_ms              ; () -> rax monotonic milliseconds
extern plat_thread          ; (fn) -> rax handle | 0
extern plat_join            ; (handle)
; ---- C runtime ------------------------------------------------------------
extern malloc, calloc, free, realloc, memcpy, qsort
; the decoder kernel (src/peep.asm, src/flac.asm; API in src/peep.h)
extern peep_open, peep_fill, peep_seek, peep_close, peep_codec_flac, peep_codec_wavx, peep_codec_wavc
%ifndef PURE
extern codec_open, codec_read, codec_seek, codec_close   ; the C shim (src/codecs.c)
%endif

global core_list_new, core_list_add, core_list_free, core_list_sort
global core_publish, core_player, core_key
global g_quit, g_ui, g_blank, g_paused, g_volstep
global cur_idx, st_count, st_playing, st_rate, st_pos, st_total, cmd_seek
global pending_info, info_free, art_unref
extern meta_parse, meta_art_ptr, meta_art_len, meta_done
extern gfx_font_cycle, gfx_show_version
%ifndef PURE
extern image_decode, image_free
%endif

section .data
align 8
pending_list  dq 0          ; new playlist waiting for the player thread
pending_info  dq 0          ; new track info waiting for the UI thread
g_quit        dd 0
g_paused      dd 0
g_ui          dd 0          ; Tab: info overlay
g_blank       dd 0          ; Shift+Tab: nothing at all, just black
g_volstep     dd 20         ; 0..20
cmd_skip      dd 0          ; tracks to move (+/-), accumulated
cmd_seek      dd 0          ; seconds to seek (+/-), accumulated; the UI shows
                            ; st_pos + this, so keys register at once
seek_taken    dd 0          ; the part of cmd_seek being carried out
pause_done    dd 0          ; the queued audio was dropped for this pause
mix_gain      dd -1         ; gain at the end of the last chunk (-1: none yet)
art_thr       dq 0          ; cover-decoding thread, 0 when none
job_info      dq 0          ; its track info
job_buf       dq 0          ; its copy of the picture bytes
job_idx       dd 0          ; the playlist index the cover is for
%ifndef WIN64               ; (Windows' millisecond clock ticks every ~15 ms: too coarse for these)
skip_ms       dq 0          ; when the last Next/Previous key arrived
skip_prev     dq 0          ; and the one before it
seek_ms       dq 0          ; when the last seek key arrived
seek_first    dq 0          ; when the first of the seek keys not yet carried out arrived
%endif
job_len       dq 0
job_hash      dq 0

; gain = 256 * (step/20)^2  — roughly perceptual
voltab: dw 0,1,3,6,10,16,23,31,41,52,64,77,92,108,125,144,164,185,207,231,256
; Codecs tried after the kernel's built-in 16-bit PCM WAV, in order: the compressed
; WAV formats (A-law, mu-law, IMA and MS ADPCM), the other WAV formats
; (8/12/20/24/32-bit PCM, 32/64-bit float), native FLAC, then (unless PURE) the
; C shim for MP3 and Ogg Vorbis.
align 8
codec_list:   dq peep_codec_wavc
              dq peep_codec_wavx
              dq peep_codec_flac
%ifndef PURE
              dq peep_codec_shim
%endif
              dq 0

section .bss
alignb 16
g_peep:       resb PEEP_SIZE ; the open track's decoder
dec_work      resq 1         ; its scratch memory, if a codec asked for some
cur_list      resq 1
cur_idx       resd 1         ; read by UI
st_count      resd 1         ; read by UI
st_playing    resd 1         ; read by UI
st_rate       resd 1         ; read by UI
st_pos        resq 1         ; read by UI (frames)
st_total      resq 1         ; read by UI (frames)
map_ptr       resq 1
map_len       resq 1
dev_rate      resd 1
last_art      resq 1         ; player's reference to the most recent art
alignb 16
decbuf        resw CHUNK*2   ; the kernel always yields stereo
outbuf        resw CHUNK*2

section .text

; ============================================================================
; Playlist
; ============================================================================
FUNC core_list_new, 0
    mov  A1, PL_SIZE
    call malloc
    test rax, rax
    jz   .r
    xor  ecx, ecx
    mov  [rax + PL_COUNT], rcx
    mov  [rax + PL_CAP], rcx
    mov  [rax + PL_ITEMS], rcx
.r: RET_

; core_list_add(list, src, bytes) -> eax 1 ok
FUNC core_list_add, 0
    ARGS rbx, r12, r13
    mov  rax, [rbx + PL_COUNT]
    cmp  rax, [rbx + PL_CAP]
    jb   .room
    mov  r14, [rbx + PL_CAP]
    shl  r14, 1
    jnz  .g
    mov  r14, 64
.g: mov  A1, [rbx + PL_ITEMS]
    lea  A2, [r14*8]
    call realloc
    test rax, rax
    jz   .fail
    mov  [rbx + PL_ITEMS], rax
    mov  [rbx + PL_CAP], r14
.room:
    mov  A1, r13
    call malloc
    test rax, rax
    jz   .fail
    mov  r14, rax
    mov  A1, r14
    mov  A2, r12
    mov  A3, r13
    call memcpy
    mov  rax, [rbx + PL_COUNT]
    mov  rcx, [rbx + PL_ITEMS]
    mov  [rcx + rax*8], r14
    inc  qword [rbx + PL_COUNT]
    mov  eax, 1
    RET_
.fail:
    xor  eax, eax
    RET_

FUNC core_list_free, 0
    ARGS rbx
    test rbx, rbx
    jz   .r
    xor  r12d, r12d
.l: cmp  r12, [rbx + PL_COUNT]
    jae  .d
    mov  rax, [rbx + PL_ITEMS]
    mov  A1, [rax + r12*8]
    call free
    inc  r12
    jmp  .l
.d: mov  A1, [rbx + PL_ITEMS]
    call free
    mov  A1, rbx
    call free
.r: RET_

FUNC core_list_sort, 0
    ARGS rbx
    mov  A1, [rbx + PL_ITEMS]
    mov  A2, [rbx + PL_COUNT]
    cmp  A2, 2
    jb   .r
    mov  A3, 8
    lea  A4, [rel plat_cmp]
    call qsort
.r: RET_

; core_publish(list): hand a fresh playlist to the player. Empty lists are
; discarded so an accidental drop of non-audio never stops the music.
FUNC core_publish, 0
    ARGS rbx
    test rbx, rbx
    jz   .r
    cmp  qword [rbx + PL_COUNT], 0
    jne  .go
    mov  A1, rbx
    call core_list_free
    RET_
.go:
    mov  A1, rbx
    call core_list_sort
    mov  rax, rbx
    xchg rax, [pending_list]          ; atomic publish
    mov  A1, rax                      ; an older list the player never took
    call core_list_free
.r: RET_

; ============================================================================
; Decoder: lib-Peep's kernel (built-in 16-bit PCM WAV, native FLAC) and the C
; shim behind it. The kernel always yields interleaved stereo int16 at the
; file's own rate; Peep applies volume in mix(), so the kernel's gain stays 256.
; ============================================================================

%macro SET5 1
%ifdef WIN64
    mov  qword SARG(5), %1
%else
    mov  A5, %1
%endif
%endmacro
%macro SET6 1
%ifdef WIN64
    mov  qword SARG(6), %1
%else
    mov  A6, %1
%endif
%endmacro

; The kernel's open call: peep_open(&g_peep, codec_list, data, len, work, work_size).
; Its 5th and 6th arguments go on the stack under Win64, at [rsp+32], so this is a
; macro used inside dec_open's own frame, never a separate called routine.
%macro PEEP_OPEN 0
    lea  A1, [g_peep]
    lea  A2, [codec_list]
    mov  A3, rbx
    mov  A4, r12
    SET5 r14
    SET6 r13
    call peep_open
%endmacro

; dec_open(p, n) -> eax 1 ok
FUNC dec_open, 0
    ARGS rbx, r12                     ; rbx = data, r12 = length
    mov  qword [dec_work], 0
    xor  r14d, r14d                   ; no scratch memory yet
    xor  r13d, r13d
    PEEP_OPEN
    test eax, eax
    jz   .first
    ; Opened. But a codec earlier in the list may have wanted scratch memory for this
    ; very file and been skipped for lack of it (ADPCM WAV, FLAC), leaving it to a
    ; later codec: the C shim takes almost any bytes for MP3. Open it again with the
    ; memory, so the right codec gets it.
    mov  r13, [g_peep + PEEP_WNEED]
    test r13, r13
    jz   .ok
    lea  A1, [g_peep]
    call peep_close
    jmp  .need
.first:
    mov  r13, [g_peep + PEEP_WNEED]   ; a codec wanted scratch memory: give it some
    test r13, r13
    jz   .no
.need:
    mov  A1, 1
    mov  A2, r13
    call calloc
    test rax, rax
    jz   .no
    mov  [dec_work], rax
    mov  r14, rax
    PEEP_OPEN
    test eax, eax
    jnz  .ok
    mov  A1, [dec_work]
    call free
    mov  qword [dec_work], 0
.no:xor  eax, eax
    RET_
.ok:mov  dword [g_peep + PEEP_GAIN], 256
    mov  eax, 1
    RET_

FUNC dec_close, 0
    lea  A1, [g_peep]
    call peep_close
    mov  A1, [dec_work]
    test A1, A1
    jz   .n
    call free
    mov  qword [dec_work], 0
.n: RET_

%ifndef PURE
; ---- the C shim as the kernel's last codec: MP3 and Ogg Vorbis. Its decoder
; object (dec_t) lives in the kernel's state[] bytes.
FUNCL sh_open, 0                      ; (p, data, len) -> nonzero = mine
    ARGS rbx, r12, r13
    lea  A1, [rbx + PEEP_STATE]
    mov  A2, r12
    mov  A3, r13
    call codec_open
    test eax, eax
    jz   .no
    mov  eax, [rbx + PEEP_STATE + DEC_RATE]
    mov  [rbx + PEEP_RATE], eax
    mov  eax, [rbx + PEEP_STATE + DEC_CH]
    mov  [rbx + PEEP_CH], eax
    mov  rax, [rbx + PEEP_STATE + DEC_TOTAL]
    mov  [rbx + PEEP_TOTAL], rax
    mov  eax, 1
    RET_
.no:xor  eax, eax
    RET_
FUNCL sh_read, 0                      ; (p, out, frames) -> frames, in the file's channels
    ARGS rbx, r12, r13
    lea  A1, [rbx + PEEP_STATE]
    mov  A2, r12
    mov  A3, r13
    call codec_read
    RET_
FUNCL sh_seek, 0                      ; (p, frame)
    ARGS rbx, r12
    lea  A1, [rbx + PEEP_STATE]
    mov  A2, r12
    call codec_seek
    RET_
FUNCL sh_close, 0                     ; (p)
    ARGS rbx
    lea  A1, [rbx + PEEP_STATE]
    call codec_close
    RET_

section .data
align 8
peep_codec_shim: dq sh_open, sh_read, sh_seek, sh_close, 0   ; no read32: 16-bit only
section .text
%endif

; ============================================================================
; Player thread
; ============================================================================

; open_track() -> eax 1 ok. Uses cur_list/cur_idx.
FUNC open_track, 16
    mov  dword [mix_gain], -1         ; a new track starts at its own gain
    mov  rax, [cur_list]
    mov  ecx, [cur_idx]
    mov  rax, [rax + PL_ITEMS]
    mov  rbx, [rax + rcx*8]           ; path
    mov  A1, rbx
    lea  A2, [map_len]
    call plat_map
    test rax, rax
    jz   .fail
    mov  [map_ptr], rax
    mov  A1, rax
    mov  A2, [map_len]
    call dec_open
    test eax, eax
    jz   .unmap
    mov  eax, [g_peep + PEEP_CH]
    test eax, eax
    jz   .close
    cmp  eax, MAXCH
    ja   .close
    mov  eax, [g_peep + PEEP_RATE]
    cmp  eax, 1000
    jb   .close
    cmp  eax, 768000
    ja   .close
    ; Another skip is already queued and will move on from this track (not
    ; the no-op of Next on the last track): don't publish its info or decode
    ; its cover, and leave the sound device alone.
    call skip_pending
    test eax, eax
    jz   .pub
.pass:
    mov  eax, [g_peep + PEEP_RATE]
    mov  [st_rate], eax
    mov  qword [st_pos], 0
    mov  eax, 1
    RET_
.pub:
    mov  A1, rbx
    call publish_info                 ; tags now; the cover decodes alongside
    mov  eax, [g_peep + PEEP_RATE]
    cmp  eax, [dev_rate]
    je   .devok
    cmp  dword [dev_rate], 0
    je   .open
    mov  A1, 1
    call plat_audio_close
    mov  dword [dev_rate], 0
.open:
    mov  A1d, [g_peep + PEEP_RATE]
    call plat_audio_open
    test eax, eax
    jnz  .close
    mov  eax, [g_peep + PEEP_RATE]
    mov  [dev_rate], eax
.devok:
    mov  eax, [g_peep + PEEP_RATE]
    mov  [st_rate], eax
    mov  rax, [g_peep + PEEP_TOTAL]
    mov  [st_total], rax
    mov  qword [st_pos], 0
    mov  dword [st_playing], 1
    mov  eax, 1
    RET_
.close:
    call dec_close
.unmap:
    mov  A1, [map_ptr]
    mov  A2, [map_len]
    call plat_unmap
    mov  qword [map_ptr], 0
.fail:
    xor  eax, eax
    RET_

; skip_pending() -> eax 1 if a queued Next/Previous will move away from the
; current track (Next on the last track does nothing, so it doesn't count)
FUNC skip_pending, 0
    xor  ebx, ebx
    mov  eax, [cmd_skip]
    test eax, eax
    jz   .r
    inc  ebx
    js   .r
    mov  rcx, [cur_list]
    mov  rcx, [rcx + PL_COUNT]
    dec  ecx
    cmp  [cur_idx], ecx
    jb   .r
    xor  ebx, ebx
.r: mov  eax, ebx
    RET_

FUNC close_track, 0
    call dec_close
    mov  A1, [map_ptr]
    test A1, A1
    jz   .r
    mov  A2, [map_len]
    call plat_unmap
    mov  qword [map_ptr], 0
.r: RET_

; mix(frames): decbuf (N channels) -> outbuf (stereo) with volume
FUNC mix, 0
    ARGS rbx
    mov  eax, [g_volstep]
    lea  rcx, [voltab]
    movzx r12d, word [rcx + rax*2]    ; gain 0..256
    mov  r13d, 2                      ; decbuf is stereo
    lea  rsi, [decbuf]
    lea  rdi, [outbuf]
    lea  r14, [r13*2]                 ; source stride in bytes
    xor  r15d, r15d                   ; offset of right channel
    cmp  r13d, 2
    jb   .g
    mov  r15d, 2
.g: mov  eax, [mix_gain]              ; where the last chunk ended
    cmp  eax, -1
    jne  .h
    mov  eax, r12d
.h: mov  [mix_gain], r12d
    cmp  eax, r12d
    jne  .ramp
.l: test rbx, rbx
    jz   .d
    movsx eax, word [rsi]
    imul eax, r12d
    sar  eax, 8
    mov  [rdi], ax
    movsx eax, word [rsi + r15]
    imul eax, r12d
    sar  eax, 8
    mov  [rdi + 2], ax
    add  rsi, r14
    add  rdi, 4
    dec  rbx
    jmp  .l
.ramp:                                ; the gain moved: glide to it over this chunk
    test rbx, rbx
    jz   .d
    mov  r8d, eax
    shl  r8, 16                       ; gain in 16.16, starting at the old one
    mov  ecx, r12d
    sub  ecx, eax
    movsxd rax, ecx
    shl  rax, 16
    cqo
    idiv rbx
    mov  r9, rax                      ; per-frame step
.rl:test rbx, rbx
    jz   .d
    mov  r10, r8
    sar  r10, 16
    movsx eax, word [rsi]
    imul eax, r10d
    sar  eax, 8
    mov  [rdi], ax
    movsx eax, word [rsi + r15]
    imul eax, r10d
    sar  eax, 8
    mov  [rdi + 2], ax
    add  r8, r9
    add  rsi, r14
    add  rdi, 4
    dec  rbx
    jmp  .rl
.d: RET_

; play_track(): returns when the track ends or is interrupted
FUNC play_track, 0
.loop:
    cmp  dword [g_quit], 0
    jne  .out
    cmp  qword [pending_list], 0
    jne  .newlist
    ; --- skip / previous -------------------------------------------------
    xor  eax, eax
    xchg eax, [cmd_skip]
    test eax, eax
    jz   .noskip
    mov  ebx, eax
    jns  .doskip
    ; previous: if more than 3 s in, restart this track instead
    mov  eax, [st_rate]
    imul rax, 3
    cmp  [st_pos], rax
    jbe  .doskip
    inc  ebx
    jnz  .doskip
    lea  A1, [g_peep]
    xor  A2d, A2d
    call peep_seek
    mov  qword [st_pos], 0
    call plat_audio_flush
    call plat_wake                    ; show the new time now
    jmp  .loop
.doskip:
    mov  eax, [cur_idx]
    add  eax, ebx
    jns  .dk1
    xor  eax, eax                     ; before the first track: restart it
.dk1:
    mov  rcx, [cur_list]
    mov  rcx, [rcx + PL_COUNT]
    dec  ecx                          ; index of the last track
    cmp  eax, ecx
    jle  .dk2
    mov  eax, ecx                     ; past the last track: stay on it
.dk2:
    cmp  eax, [cur_idx]
    jne  .dk3
    test ebx, ebx
    jg   .loop                        ; Next on the last track: nothing to do,
.dk3:                                 ; and the music carries on
    mov  [cur_idx], eax
    mov  dword [g_paused], 0
    jmp  .flushout
.noskip:
    ; --- seek -------------------------------------------------------------
    mov  eax, [cmd_seek]              ; taken, but only cleared once st_pos has
    test eax, eax                     ; moved, so the clock never jumps back
    jz   .noseek
%ifndef WIN64
    ; A burst of seek keys is carried out as one seek: wait until the keys have
    ; been quiet for 2 ms (never more than 10 ms after the first), so a hundred
    ; presses make one flush and one redraw, not a dozen. A lone press waits
    ; the 2 ms, which is still far below what anyone can notice.
    call plat_ms
    mov  rcx, [seek_ms]
    add  rcx, 2
    cmp  rax, rcx
    jae  .sq
    mov  rcx, [seek_first]
    add  rcx, 10
    cmp  rax, rcx
    jae  .sq
    mov  A1, 1
    call plat_sleep
    jmp  .loop
.sq:
    mov  eax, [cmd_seek]              ; (plat_ms clobbered eax; a late key just joins in)
%endif
    mov  [seek_taken], eax
    call plat_audio_queued            ; seek from the point being heard, not the
    mov  rbx, [st_pos]                ; decoder's, which runs ahead by whatever
    sub  rbx, rax                     ; the device still holds (~100 ms); read just
    jns  .sk1                         ; before the flush so no audio slips between
    xor  ebx, ebx
.sk1:
    movsxd rax, dword [seek_taken]
    mov  ecx, [st_rate]
    imul rax, rcx
    add  rax, rbx
    jns  .sk2
    xor  eax, eax
.sk2:
    mov  rcx, [st_total]
    test rcx, rcx
    jz   .sk3
    cmp  rax, rcx
    jb   .sk3
    inc  dword [cur_idx]              ; seeking past the end = next track
    mov  eax, [seek_taken]
    lock sub [cmd_seek], eax
    jmp  .flushout
.sk3:
    mov  rbx, rax
    lea  A1, [g_peep]
    mov  A2, rbx
    call peep_seek
    mov  [st_pos], rbx
    mov  eax, [seek_taken]
    lock sub [cmd_seek], eax          ; st_pos has it now
    call plat_audio_flush
    call plat_wake                    ; redraw with the real position
.noseek:
    ; --- volume -----------------------------------------------------------
    ; Nothing to do: a volume key only sets g_volstep, and mix() glides to it over
    ; the next chunk. (Dropping the queued audio so a lone press is heard at once
    ; used to be done here; on a real device that stops and restarts the stream,
    ; which is a glitch of its own. The change is heard within the device buffer,
    ; ~100 ms, and never interrupts the sound.)
.novol:
    cmp  dword [g_paused], 0
    je   .play
    ; --- paused: silence now ------------------------------------------------
    ; The device still holds up to ~100+ ms that would play on after the key.
    ; Drop it and rewind the decoder to the point actually heard, so the sound
    ; stops at once and a resume carries on from exactly where it stopped.
    cmp  dword [pause_done], 0
    jne  .sleep
    mov  dword [pause_done], 1
    call plat_audio_queued
    test rax, rax
    jle  .sleep
    mov  rbx, [st_pos]
    sub  rbx, rax
    jns  .p1
    xor  ebx, ebx
.p1:
    call plat_audio_flush
    lea  A1, [g_peep]
    mov  A2, rbx
    call peep_seek
    mov  [st_pos], rbx
    call plat_wake                    ; the clock shows the heard position
.sleep:
    mov  A1, 15
    call plat_sleep
    jmp  .loop
.play:
    mov  dword [pause_done], 0
    ; Wait for room in the device here, not inside the write, so every command
    ; (seek, skip, volume, pause, quit) is seen within ~2 ms, not after a chunk.
    call plat_audio_wait
    test eax, eax
    jz   .loop
    lea  A1, [g_peep]
    lea  A2, [decbuf]
    mov  A3, CHUNK
    call peep_fill
    test rax, rax
    jz   .ended
    mov  rbx, rax
    mov  A1, rbx
    call mix
    lea  A1, [outbuf]
    mov  A2, rbx
    call plat_audio_write
    add  [st_pos], rbx
    jmp  .loop
.ended:
    inc  dword [cur_idx]
    RET_
.newlist:
    ; New files were dropped on the window. Stop the track that is playing, and start
    ; the new one at once, without a click: the queued audio is thrown away, then the
    ; next few milliseconds the listener would have heard are decoded again and cut at
    ; their quietest frame, so the old track ends where its wave is nearly at rest
    ; instead of in mid-swing. The audio is not changed, only ended a little early.
    cmp  dword [g_paused], 0
    jne  .flushout
    call plat_audio_queued
    test rax, rax
    jle  .flushout
    mov  rbx, [st_pos]
    sub  rbx, rax                     ; the frame being heard now
    jns  .nl1
    xor  ebx, ebx
.nl1:
    call plat_audio_flush
    lea  A1, [g_peep]
    mov  A2, rbx
    call peep_seek
    lea  A1, [g_peep]
    lea  A2, [decbuf]
    mov  A3, 256                      ; ~6 ms at 44.1 kHz
    call peep_fill
    test rax, rax
    jz   .out
    mov  rbx, rax
    lea  r8, [decbuf]
    xor  r10d, r10d
    xor  r11d, r11d
    mov  r9d, 0x7fffffff
.nl2:
    movsx eax, word [r8 + r10*4]
    mov  edx, eax
    sar  edx, 31
    xor  eax, edx
    sub  eax, edx
    movsx ecx, word [r8 + r10*4 + 2]
    mov  edx, ecx
    sar  edx, 31
    xor  ecx, edx
    sub  ecx, edx
    add  eax, ecx
    cmp  eax, r9d
    jae  .nl3
    mov  r9d, eax
    mov  r11d, r10d
.nl3:
    inc  r10d
    cmp  r10, rbx
    jb   .nl2
    lea  rbx, [r11 + 1]               ; the frames up to and including the quietest
    mov  A1, rbx
    call mix
    lea  A1, [outbuf]
    mov  A2, rbx
    call plat_audio_write
    jmp  .out
.flushout:
    call plat_audio_flush
.out:
    RET_

;  ---------------------------------------------------------------------------
;  Track info (player thread -> UI thread)
;  ---------------------------------------------------------------------------

; art_unref(art): drop one reference, free on the last
FUNC art_unref, 0
    ARGS rbx
    test rbx, rbx
    jz   .r
    lock dec dword [rbx + ART_REF]
    jnz  .r
    mov  A1, [rbx + ART_PX]
    call free
    mov  A1, rbx
    call free
.r: RET_

; info_free(info)
FUNC info_free, 0
    ARGS rbx
    test rbx, rbx
    jz   .r
    mov  A1, [rbx + INFO_ART]
    call art_unref
    mov  A1, rbx
    call free
.r: RET_

; fnv1a64(ptr, len) -> rax
FUNC fnv1a, 0
    ARGS rbx, r12
    mov  rax, 0xcbf29ce484222325
    mov  r13, 0x100000001b3
.l: test r12, r12
    jz   .r
    movzx ecx, byte [rbx]
    xor  rax, rcx
    imul rax, r13
    inc  rbx
    dec  r12
    jmp  .l
.r: RET_

%ifndef PURE
; decode_art(ptr, len) -> rax ART (new, ref 1) or 0
FUNC decode_art, 16
    lea  A3, [L(0)]
    lea  A4, [L(4)]
    call image_decode
    test rax, rax
    jz   .r
    mov  rbx, rax                     ; RGBA
    ; RGBA -> BGRX in place
    mov  ecx, [L(0)]
    imul ecx, [L(4)]
    mov  rsi, rbx
.cv:test ecx, ecx
    jz   .cvd
    mov  eax, [rsi]
    bswap eax                         ; AABBGGRR -> RRGGBBAA
    shr  eax, 8                       ; 00RRGGBB
    mov  [rsi], eax
    add  rsi, 4
    dec  ecx
    jmp  .cv
.cvd:
    mov  A1, ART_SIZE
    call malloc
    test rax, rax
    jz   .nomem
    mov  dword [rax + ART_REF], 1
    mov  ecx, [L(0)]
    mov  [rax + ART_W], ecx
    mov  ecx, [L(4)]
    mov  [rax + ART_H], ecx
    mov  [rax + ART_PX], rbx
    RET_
.nomem:
    mov  A1, rbx
    call image_free
    xor  eax, eax
.r: RET_
%endif

; publish_info(path): parse the tags of the mapped file and hand the result
; to the UI. A cover that needs decoding (10-50 ms for a big JPEG or PNG) is
; decoded on its own thread, so the track's audio and the window don't wait
; for it.
FUNC publish_info, 0
    ARGS r12                          ; path
    call art_join                     ; the previous cover is done with last_art
    mov  A1, INFO_SIZE
    call malloc
    test rax, rax
    jz   .r
    mov  rbx, rax
    mov  byte [rbx + INFO_TITLE], 0
    mov  byte [rbx + INFO_ARTIST], 0
    mov  qword [rbx + INFO_ART], 0
    mov  A1, [map_ptr]
    mov  A2, [map_len]
    mov  A3, rbx
    call meta_parse
    cmp  byte [rbx + INFO_TITLE], 0
    jne  .titled
    mov  A1, r12                      ; no tag: file name
    lea  A2, [rbx + INFO_TITLE]
    mov  A3, 256
    call plat_title
.titled:
%ifndef PURE
    mov  r13, [meta_art_len]
    test r13, r13
    jz   .now
    mov  A1, [meta_art_ptr]
    mov  A2, r13
    call fnv1a
    mov  r14, rax
    mov  rax, [last_art]              ; same picture as last track? reuse it
    test rax, rax
    jz   .dec
    cmp  [rax + ART_HASH], r14
    jne  .dec
    cmp  [rax + ART_LEN], r13
    jne  .dec
    lock inc dword [rax + ART_REF]    ; the info's reference
    mov  [rbx + INFO_ART], rax
    jmp  .now
.dec:
    ; copy the picture (it may live in the parser's buffers or the mapped
    ; file, both gone soon) and decode it on a worker thread
    mov  A1, r13
    call malloc
    test rax, rax
    jz   .now
    mov  r15, rax
    mov  A1, rax
    mov  A2, [meta_art_ptr]
    mov  A3, r13
    call memcpy
    call meta_done
    mov  [job_info], rbx
    mov  [job_buf], r15
    mov  eax, [cur_idx]
    mov  [job_idx], eax
    mov  [job_len], r13
    mov  [job_hash], r14
    lea  A1, [art_worker]
    call plat_thread
    mov  [art_thr], rax
    test rax, rax
    jnz  .r
    call art_worker                   ; no thread: decode here
    RET_
%endif
.now:
    call meta_done                    ; free any buffers the parser made
    mov  A1, rbx
    call hand_over
.r: RET_

; hand_over(info): make info the UI's next track info
FUNC hand_over, 0
    mov  rax, A1
    xchg rax, [pending_info]
    mov  A1, rax                      ; superseded before the UI saw it
    call info_free
    call plat_wake
    RET_

; art_join(): wait for the cover thread, if one is running
FUNC art_join, 0
    xor  eax, eax
    xchg rax, [art_thr]
    test rax, rax
    jz   .r
    mov  A1, rax
    call plat_join
.r: RET_

%ifndef PURE
; art_worker(): thread body. Decodes job_buf, attaches it to job_info and
; hands the info to the UI. Only one runs at a time (publish_info joins the
; last one first), so it may update last_art freely.
FUNC art_worker, 0
    mov  rbx, [job_info]
    ; A burst of Next/Previous keys passes through tracks it won't stop on: wait
    ; until the keys have been quiet for 6 ms (at most ~16 ms), but only if
    ; they are coming in a burst: a lone press is shown at once,, and drop this
    ; cover, and the info that goes with it, if the player is moving on.
    xor  r12d, r12d
.q: call skip_pending
    test eax, eax
    jnz  .drop
    mov  eax, [cur_idx]
    cmp  eax, [job_idx]
    jne  .drop
%ifndef WIN64
    cmp  r12d, 16
    jae  .go
    mov  rcx, [skip_ms]               ; a lone press (the key before it long ago)
    sub  rcx, [skip_prev]             ; has nothing to wait for: show it at once
    cmp  rcx, 6
    jae  .go
    call plat_ms
    mov  rcx, [skip_ms]
    add  rcx, 6
    cmp  rax, rcx
    jae  .go
    inc  r12d
    mov  A1, 1
    call plat_sleep
    jmp  .q
%endif
.go:
    mov  A1, [job_buf]
    mov  A2, [job_len]
    call decode_art
    test rax, rax
    jz   .pub
    mov  r15, rax
    mov  rcx, [job_hash]
    mov  [r15 + ART_HASH], rcx
    mov  rcx, [job_len]
    mov  [r15 + ART_LEN], rcx
    mov  A1, [last_art]
    call art_unref
    mov  [last_art], r15
    lock inc dword [r15 + ART_REF]    ; the info's reference
    mov  [rbx + INFO_ART], r15
.pub:
    mov  A1, [job_buf]
    call free
    ; Decoding takes ~20 ms, by which time a burst of Next/Previous keys is long
    ; over: if the player has moved on from this track, it is one the burst only
    ; passed through, so don't show it (no flash, no window resize for it).
    call skip_pending
    test eax, eax
    jnz  .late
    mov  eax, [cur_idx]
    cmp  eax, [job_idx]
    jne  .late
    mov  A1, rbx
    call hand_over
    xor  eax, eax
    RET_
.late:
    mov  A1, rbx
    call info_free
    xor  eax, eax
    RET_
.drop:
    mov  A1, [job_buf]
    call free
    mov  A1, rbx
    call info_free
    xor  eax, eax
    RET_
%endif

FUNC core_player, 0
.top:
    cmp  dword [g_quit], 0
    jne  .exit
    xor  eax, eax
    xchg rax, [pending_list]
    test rax, rax
    jz   .nonew
    mov  rbx, rax
    mov  A1, [cur_list]
    call core_list_free
    mov  [cur_list], rbx
    mov  dword [cur_idx], 0
    mov  dword [cmd_skip], 0
    mov  dword [cmd_seek], 0
    mov  dword [g_paused], 0
    mov  rax, [rbx + PL_COUNT]
    mov  [st_count], eax
.nonew:
    mov  rbx, [cur_list]
    test rbx, rbx
    jz   .idle
    mov  eax, [cur_idx]
    cmp  rax, [rbx + PL_COUNT]
    jae  .atend
    ; skips pressed while no track is open (key repeat): move the index now,
    ; so only the track we land on is opened
    xor  ecx, ecx
    xchg ecx, [cmd_skip]
    test ecx, ecx
    jz   .noq
    add  eax, ecx
    jns  .q1
    xor  eax, eax
.q1:mov  rcx, [rbx + PL_COUNT]
    dec  ecx
    cmp  eax, ecx
    jle  .q2
    mov  eax, ecx
.q2:mov  [cur_idx], eax
.noq:
    call open_track
    test eax, eax
    jz   .bad
    call play_track
    call close_track
    jmp  .top
.bad:
    inc  dword [cur_idx]
    jmp  .top
.atend:
    mov  dword [st_playing], 0
    cmp  dword [dev_rate], 0
    je   .idlecmd
    mov  A1, 1                        ; let the last note ring out
    call plat_audio_close
    mov  dword [dev_rate], 0
.idlecmd:
    ; after the last track, "previous" walks back into the list
    xor  eax, eax
    xchg eax, [cmd_skip]
    test eax, eax
    jns  .idle
    mov  ecx, [rbx + PL_COUNT]
    add  eax, ecx
    jns  .ic
    xor  eax, eax
.ic:mov  [cur_idx], eax
    jmp  .top
.idle:
    mov  dword [cmd_seek], 0
    mov  A1, 20
    call plat_sleep
    jmp  .top
.exit:
    xor  eax, eax
    RET_

; ============================================================================
; Input
; ============================================================================
; core_key(k) -> eax 1 if the screen should be redrawn
FUNC core_key, 0
    mov  ebx, A1d                     ; plat_ms below clobbers the argument register
%ifndef WIN64
    cmp  ebx, K_SEEKBACK
    je   .stampseek
    cmp  ebx, K_SEEKFWD
    je   .stampseek
    cmp  ebx, K_NEXT
    je   .stampskip
    cmp  ebx, K_PREV
    je   .stampskip
    jmp  .nostamp
.stampseek:
    call plat_ms
    mov  [seek_ms], rax
    cmp  dword [cmd_seek], 0
    jne  .nostamp
    mov  [seek_first], rax
    jmp  .nostamp
.stampskip:
    call plat_ms
    mov  rcx, [skip_ms]
    mov  [skip_prev], rcx
    mov  [skip_ms], rax
.nostamp:
%endif
    mov  eax, ebx
    cmp  eax, K_PAUSE
    jne  .k2
    xor  dword [g_paused], 1
    jmp  .yes
.k2:cmp  eax, K_SEEKBACK
    jne  .k3
    lock sub dword [cmd_seek], 10
    jmp  .yes
.k3:cmp  eax, K_SEEKFWD
    jne  .k4
    lock add dword [cmd_seek], 10
    jmp  .yes
.k4:cmp  eax, K_VOLUP
    jne  .k5
    cmp  dword [g_volstep], 20
    jae  .yes
    inc  dword [g_volstep]
    jmp  .yes
.k5:cmp  eax, K_VOLDN
    jne  .k6
    cmp  dword [g_volstep], 0
    je   .yes
    dec  dword [g_volstep]
    jmp  .yes
.k6:cmp  eax, K_NEXT
    jne  .k7
    lock inc dword [cmd_skip]
    jmp  .yes
.k7:cmp  eax, K_PREV
    jne  .k8
    lock dec dword [cmd_skip]
    jmp  .yes
.k8:cmp  eax, K_UI
    jne  .k9
    xor  dword [g_ui], 1
    jmp  .yes
.k9:cmp  eax, K_BLANK
    jne  .k10
    xor  dword [g_blank], 1
    jmp  .yes
.k10:
    cmp  eax, K_FONT
    jne  .k11
    call gfx_font_cycle
    jmp  .yes
.k11:
    cmp  eax, K_VERSION
    jne  .no
    call gfx_show_version
.yes:
    mov  eax, 1
    RET_
.no:xor  eax, eax
    RET_
%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
