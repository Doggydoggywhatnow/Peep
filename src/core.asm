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
extern malloc, free, realloc, memcpy, qsort
%ifndef PURE
extern codec_open, codec_read, codec_seek, codec_close
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
vol_ms        dq 0          ; when a volume key was last pressed
cmd_refill    dd 0          ; volume changed: re-render the queued audio
art_thr       dq 0          ; cover-decoding thread, 0 when none
job_info      dq 0          ; its track info
job_buf       dq 0          ; its copy of the picture bytes
job_len       dq 0
job_hash      dq 0

; gain = 256 * (step/20)^2  — roughly perceptual
voltab: dw 0,1,3,6,10,16,23,31,41,52,64,77,92,108,125,144,164,185,207,231,256

section .bss
alignb 16
g_dec:        resb DEC_SIZE
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
decbuf        resw CHUNK*MAXCH
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
; Decoder dispatch: native WAV first, then the codec shim
; ============================================================================

; dec_open(p, n) -> eax 1 ok
FUNC dec_open, 0
    ARGS rbx, r12                     ; rbx = data, r12 = length
    lea  r15, [g_dec]
    mov  dword [r15 + DEC_TYPE], DT_NONE
    cmp  r12, 44
    jb   .codec
    cmp  dword [rbx], 'RIFF'
    jne  .codec
    cmp  dword [rbx + 8], 'WAVE'
    jne  .codec
    mov  r13, 12                      ; chunk cursor
    xor  r14d, r14d                   ; bit0 = fmt seen and usable
.chunk:
    lea  rax, [r13 + 8]
    cmp  rax, r12
    ja   .codec
    mov  eax, [rbx + r13]             ; id
    mov  ecx, [rbx + r13 + 4]         ; size
    lea  rsi, [r13 + 8]               ; body offset
    cmp  eax, 'fmt '
    jne  .notfmt
    cmp  ecx, 16
    jb   .codec
    lea  rdx, [rsi + 16]
    cmp  rdx, r12
    ja   .codec
    cmp  word [rbx + rsi], 1          ; PCM
    jne  .codec
    cmp  word [rbx + rsi + 14], 16    ; 16-bit
    jne  .codec
    movzx eax, word [rbx + rsi + 2]
    mov  [r15 + DEC_CH], eax
    mov  eax, [rbx + rsi + 4]
    mov  [r15 + DEC_RATE], eax
    mov  r14d, 1
    jmp  .next
.notfmt:
    cmp  eax, 'data'
    jne  .next
    test r14d, r14d
    jz   .codec                       ; data before fmt: let dr_wav cope
    mov  rax, r12
    sub  rax, rsi                     ; bytes really available
    cmp  rcx, rax
    cmova rcx, rax
    lea  rax, [rbx + rsi]
    mov  [r15 + DEC_DATA], rax
    mov  eax, [r15 + DEC_CH]
    test eax, eax
    jz   .codec
    add  eax, eax                     ; block align
    xchg rax, rcx
    xor  edx, edx
    div  rcx
    mov  [r15 + DEC_TOTAL], rax
    mov  qword [r15 + DEC_POS], 0
    mov  dword [r15 + DEC_TYPE], DT_WAV
    mov  eax, 1
    RET_
.next:
    mov  eax, ecx
    and  eax, 1                       ; odd-sized chunks carry a pad byte
    add  rsi, rcx
    add  rsi, rax
    mov  r13, rsi
    jmp  .chunk
.codec:
%ifdef PURE
    xor  eax, eax
%else
    mov  A1, r15
    mov  A2, rbx
    mov  A3, r12
    call codec_open
%endif
    RET_

; dec_read(out, frames) -> rax frames
FUNC dec_read, 0
    ARGS rbx, r12
    lea  r15, [g_dec]
    cmp  dword [r15 + DEC_TYPE], DT_WAV
    jne  .codec
    mov  rax, [r15 + DEC_TOTAL]
    sub  rax, [r15 + DEC_POS]
    cmp  r12, rax
    cmova r12, rax
    test r12, r12
    jz   .z
    mov  r13d, [r15 + DEC_CH]
    add  r13d, r13d                   ; bytes per frame
    mov  rax, [r15 + DEC_POS]
    imul rax, r13
    add  rax, [r15 + DEC_DATA]
    mov  A1, rbx
    mov  A2, rax
    mov  rax, r12
    imul rax, r13
    mov  A3, rax
    call memcpy
    add  [r15 + DEC_POS], r12
    mov  rax, r12
    RET_
.z: xor  eax, eax
    RET_
.codec:
%ifdef PURE
    xor  eax, eax
%else
    mov  A1, r15
    mov  A2, rbx
    mov  A3, r12
    call codec_read
%endif
    RET_

; dec_seek(frame)
FUNC dec_seek, 0
    ARGS rbx
    lea  r15, [g_dec]
    cmp  dword [r15 + DEC_TYPE], DT_WAV
    jne  .codec
    mov  rax, [r15 + DEC_TOTAL]
    cmp  rbx, rax
    cmova rbx, rax
    mov  [r15 + DEC_POS], rbx
    RET_
.codec:
%ifndef PURE
    mov  A1, r15
    mov  A2, rbx
    call codec_seek
%endif
    RET_

FUNC dec_close, 0
    lea  r15, [g_dec]
    cmp  dword [r15 + DEC_TYPE], DT_WAV
    je   .n
    cmp  dword [r15 + DEC_TYPE], DT_NONE
    je   .n
%ifndef PURE
    mov  A1, r15
    call codec_close
%endif
.n: mov  dword [r15 + DEC_TYPE], DT_NONE
    RET_

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
    mov  eax, [g_dec + DEC_CH]
    test eax, eax
    jz   .close
    cmp  eax, MAXCH
    ja   .close
    mov  eax, [g_dec + DEC_RATE]
    cmp  eax, 1000
    jb   .close
    cmp  eax, 768000
    ja   .close
    ; Another skip is already queued and will move on from this track (not
    ; the no-op of Next on the last track): don't publish its info or decode
    ; its cover, and leave the sound device alone.
    mov  eax, [cmd_skip]
    test eax, eax
    jz   .pub
    js   .pass
    mov  rcx, [cur_list]
    mov  rcx, [rcx + PL_COUNT]
    dec  ecx
    cmp  [cur_idx], ecx
    jae  .pub
.pass:
    mov  eax, [g_dec + DEC_RATE]
    mov  [st_rate], eax
    mov  qword [st_pos], 0
    mov  eax, 1
    RET_
.pub:
    mov  A1, rbx
    call publish_info                 ; tags now; the cover decodes alongside
    mov  eax, [g_dec + DEC_RATE]
    cmp  eax, [dev_rate]
    je   .devok
    cmp  dword [dev_rate], 0
    je   .open
    mov  A1, 1
    call plat_audio_close
    mov  dword [dev_rate], 0
.open:
    mov  A1d, [g_dec + DEC_RATE]
    call plat_audio_open
    test eax, eax
    jnz  .close
    mov  eax, [g_dec + DEC_RATE]
    mov  [dev_rate], eax
.devok:
    mov  eax, [g_dec + DEC_RATE]
    mov  [st_rate], eax
    mov  rax, [g_dec + DEC_TOTAL]
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
    mov  r13d, [g_dec + DEC_CH]
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
    jne  .flushout
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
    xor  A1, A1
    call dec_seek
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
    mov  [seek_taken], eax
    movsxd rax, eax
    mov  ecx, [st_rate]
    imul rax, rcx
    add  rax, [st_pos]
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
    mov  A1, rbx
    call dec_seek
    mov  [st_pos], rbx
    mov  eax, [seek_taken]
    lock sub [cmd_seek], eax          ; st_pos has it now
    call plat_audio_flush
    call plat_wake                    ; redraw with the real position
.noseek:
    ; --- volume -----------------------------------------------------------
    ; The device still holds up to ~100-200 ms mixed at the old volume. Drop
    ; it and decode again from the point actually being heard, so a volume
    ; key takes effect at once.
    xor  eax, eax
    xchg eax, [cmd_refill]
    test eax, eax
    jz   .novol
    cmp  dword [g_paused], 0
    jne  .novol
    call plat_audio_queued
    test rax, rax
    jle  .novol
    mov  rbx, [st_pos]
    sub  rbx, rax
    jns  .v1
    xor  ebx, ebx
.v1:
    call plat_audio_flush
    mov  A1, rbx
    call dec_seek
    mov  [st_pos], rbx
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
    mov  A1, rbx
    call dec_seek
    mov  [st_pos], rbx
    call plat_wake                    ; the clock shows the heard position
.sleep:
    mov  A1, 15
    call plat_sleep
    jmp  .loop
.play:
    mov  dword [pause_done], 0
    lea  A1, [decbuf]
    mov  A2, CHUNK
    call dec_read
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
    mov  A1, rbx
    call hand_over
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
; vol_touched(): a volume key was pressed. A lone press is heard at once (the
; player drops the queued audio and re-mixes it). A key being held repeats
; every ~30 ms, and doing that each time would stutter the sound: while it is
; held only new audio gets the new gain, which the mixer ramps smoothly.
FUNC vol_touched, 0
    call plat_ms
    mov  rcx, rax
    sub  rax, [vol_ms]
    mov  [vol_ms], rcx
    cmp  rax, 400
    jb   .r
    mov  dword [cmd_refill], 1
.r: RET_

; core_key(k) -> eax 1 if the screen should be redrawn
FUNC core_key, 0
    mov  eax, A1d
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
    call vol_touched
    jmp  .yes
.k5:cmp  eax, K_VOLDN
    jne  .k6
    cmp  dword [g_volstep], 0
    je   .yes
    dec  dword [g_volstep]
    call vol_touched
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
