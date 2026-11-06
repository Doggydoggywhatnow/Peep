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
extern plat_map             ; (path, &len) -> rax ptr | 0
extern plat_unmap           ; (ptr, len)
extern plat_sleep           ; (ms)
extern plat_title           ; (path, out, max)  ASCII display name
extern plat_cmp             ; qsort comparator for native path strings
; ---- C runtime ------------------------------------------------------------
extern malloc, free, realloc, memcpy, qsort
%ifndef PURE
extern codec_open, codec_read, codec_seek, codec_close
%endif

global core_list_new, core_list_add, core_list_free, core_list_sort
global core_publish, core_player, core_key, core_render
global g_quit, g_ui

section .data
align 8
pending_list  dq 0          ; new playlist waiting for the player thread
g_quit        dd 0
g_paused      dd 0
g_ui          dd 0          ; 0 = absolutely no interface (default)
g_volstep     dd 20         ; 0..20
cmd_skip      dd 0          ; tracks to move (+/-), accumulated
cmd_seek      dd 0          ; seconds to seek (+/-), accumulated

; gain = 256 * (step/20)^2  — roughly perceptual
voltab: dw 0,1,3,6,10,16,23,31,41,52,64,77,92,108,125,144,164,185,207,231,256

col_bar_bg    equ 0x00222222
col_bar_fg    equ 0x00b8b8b8
col_text      equ 0x00808080
col_text_hi   equ 0x00c8c8c8

s_drop        db "drop music here", 0
s_paused      db "paused  ", 0
s_vol         db "vol ", 0
s_slash       db " / ", 0
s_sep         db "  ", 0
s_end         db "end", 0
s_q           db "--:--", 0

%include "font.inc"

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
st_title      resb 160       ; read by UI (ASCII)
map_ptr       resq 1
map_len       resq 1
dev_rate      resd 1
alignb 16
decbuf        resw CHUNK*MAXCH
outbuf        resw CHUNK*2
; render context (UI thread only)
rc_buf        resq 1
rc_w          resd 1
rc_h          resd 1
rc_s          resd 1
txt_l         resb 256
txt_r         resb 64

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
    mov  rax, [cur_list]
    mov  ecx, [cur_idx]
    mov  rax, [rax + PL_ITEMS]
    mov  rbx, [rax + rcx*8]           ; path
    mov  A1, rbx
    lea  A2, [st_title]
    mov  A3, 150
    call plat_title
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
    jb   .l
    mov  r15d, 2
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
    jmp  .loop
.doskip:
    mov  eax, [cur_idx]
    add  eax, ebx
    jns  .sk1
    xor  eax, eax
.sk1:
    mov  [cur_idx], eax
    mov  dword [g_paused], 0
    jmp  .flushout
.noskip:
    ; --- seek -------------------------------------------------------------
    xor  eax, eax
    xchg eax, [cmd_seek]
    test eax, eax
    jz   .noseek
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
    jmp  .flushout
.sk3:
    mov  rbx, rax
    mov  A1, rbx
    call dec_seek
    mov  [st_pos], rbx
    call plat_audio_flush
.noseek:
    cmp  dword [g_paused], 0
    je   .play
    mov  A1, 15
    call plat_sleep
    jmp  .loop
.play:
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
    jne  .no
    xor  dword [g_ui], 1
.yes:
    mov  eax, 1
    RET_
.no:xor  eax, eax
    RET_

; ============================================================================
; Rendering
; ============================================================================

; fill_rect(x, y, w, h, color) — clipped
FUNC fill_rect, 0
%ifdef WIN64
    mov  eax, [rbp + 48]              ; caller's [rsp+32] = 5th argument
%else
    mov  eax, A5d
%endif
    movsxd r12, A1d                   ; x0
    movsxd r13, A2d                   ; y0
    movsxd r14, A3d
    add  r14, r12                     ; x1
    movsxd r15, A4d
    add  r15, r13                     ; y1
    xor  ecx, ecx
    cmp  r12, 0
    cmovl r12, rcx
    cmp  r13, 0
    cmovl r13, rcx
    movsxd rcx, dword [rc_w]
    cmp  r14, rcx
    cmovg r14, rcx
    movsxd rcx, dword [rc_h]
    cmp  r15, rcx
    cmovg r15, rcx
    cmp  r12, r14
    jge  .r
    movsxd rbx, dword [rc_w]
    shl  rbx, 2                       ; stride
.row:
    cmp  r13, r15
    jge  .r
    mov  rdi, r13
    imul rdi, rbx
    add  rdi, [rc_buf]
    lea  rdi, [rdi + r12*4]
    mov  rcx, r14
    sub  rcx, r12
    rep  stosd
    inc  r13
    jmp  .row
.r: RET_

; draw_text(x, y, str, color)
FUNC draw_text, 16
    ARGS r12, r13, rbx, r14
.ch:
    movzx eax, byte [rbx]
    test eax, eax
    jz   .r
    cmp  eax, 32
    jb   .q
    cmp  eax, 126
    jbe  .ok
.q: mov  eax, '?'
.ok:sub  eax, 32
    lea  rcx, [font8x8]
    lea  rsi, [rcx + rax*8]
    mov  [L(0)], rsi
    xor  r15d, r15d                   ; row
.row:
    cmp  r15d, 8
    jae  .nextch
    mov  rsi, [L(0)]
    movzx eax, byte [rsi + r15]
    mov  [L(8)], eax                  ; bits
    xor  esi, esi
    mov  [L(12)], esi                 ; col
.col:
    mov  ecx, [L(12)]
    cmp  ecx, 8
    jae  .nextrow
    mov  eax, [L(8)]
    bt   eax, ecx
    jnc  .skip
    mov  eax, [rc_s]
    imul ecx, eax
    add  ecx, r12d
    mov  A1d, ecx
    mov  edx, r15d
    imul edx, eax
    add  edx, r13d
    mov  A2d, edx
    mov  A3d, eax
    mov  A4d, eax
%ifdef WIN64
    mov  SARG(5), r14
%else
    mov  A5, r14
%endif
    call fill_rect
.skip:
    inc  dword [L(12)]
    jmp  .col
.nextrow:
    inc  r15d
    jmp  .row
.nextch:
    mov  eax, [rc_s]
    shl  eax, 3
    add  r12d, eax
    inc  rbx
    jmp  .ch
.r: RET_

; ---- tiny string builders: all take dst in A1 and return the new end in rax
FUNC s_cat, 0                          ; (dst, src)
    mov  rax, A1
.l: mov  cl, [A2]
    mov  [rax], cl
    test cl, cl
    jz   .r
    inc  rax
    inc  A2
    jmp  .l
.r: RET_

FUNC s_num, 32                         ; (dst, value, min_digits)
    mov  rax, A2
    mov  r8, A3
    mov  r9, A1
    lea  r10, [L(31)]
    mov  byte [r10], 0
    mov  ecx, 10
    xor  r11d, r11d
.l: xor  edx, edx
    div  rcx
    add  dl, '0'
    dec  r10
    mov  [r10], dl
    inc  r11
    test rax, rax
    jnz  .l
    cmp  r11, r8
    jb   .l
    mov  rax, r9
.c: mov  cl, [r10]
    mov  [rax], cl
    test cl, cl
    jz   .r
    inc  rax
    inc  r10
    jmp  .c
.r: RET_

FUNC s_time, 0                         ; (dst, seconds) -> "m:ss"
    ARGS rbx, r12
    mov  rax, r12
    xor  edx, edx
    mov  ecx, 60
    div  rcx
    mov  r13, rdx
    mov  A1, rbx
    mov  A2, rax
    mov  A3, 1
    call s_num
    mov  byte [rax], ':'
    lea  A1, [rax + 1]
    mov  A2, r13
    mov  A3, 2
    call s_num
    RET_

; frames -> seconds
%macro FR2SEC 1
    mov  rax, %1
    mov  ecx, [st_rate]
    test ecx, ecx
    jnz  %%ok
    mov  ecx, 1
%%ok:
    xor  edx, edx
    div  rcx
%endmacro

; core_render(buf, w, h)
FUNC core_render, 16
    mov  [rc_buf], A1
    mov  [rc_w], A2d
    mov  [rc_h], A3d
    ; clear to black
    mov  rdi, A1
    mov  eax, A2d
    imul eax, A3d
    mov  ecx, eax
    xor  eax, eax
    rep  stosd
    cmp  dword [g_ui], 0
    je   .r
    ; pick a scale for the text
    mov  dword [rc_s], 1
    cmp  dword [rc_w], 900
    jb   .sc
    cmp  dword [rc_h], 500
    jb   .sc
    mov  dword [rc_s], 2
    cmp  dword [rc_w], 2400
    jb   .sc
    mov  dword [rc_s], 3
.sc:
    mov  r15d, [rc_s]
    lea  r14d, [r15d*8]               ; glyph size / padding
    cmp  dword [st_count], 0
    jne  .player
    ; ---- nothing loaded: one quiet hint, centered
    mov  eax, [rc_w]
    mov  ecx, 15                      ; strlen("drop music here")
    imul ecx, r14d
    sub  eax, ecx
    sar  eax, 1
    mov  A1d, eax
    mov  eax, [rc_h]
    sub  eax, r14d
    sar  eax, 1
    mov  A2d, eax
    lea  A3, [s_drop]
    mov  A4, col_text
    call draw_text
    RET_
.player:
    ; ---- progress bar along the bottom edge
    mov  eax, [rc_h]
    lea  ecx, [r15d*2]
    sub  eax, ecx
    mov  [L(0)], eax                  ; bar y
    xor  A1, A1
    mov  A2d, eax
    mov  A3d, [rc_w]
    lea  A4d, [r15d*2]
%ifdef WIN64
    mov  qword SARG(5), col_bar_bg
%else
    mov  A5, col_bar_bg
%endif
    call fill_rect
    mov  rcx, [st_total]
    test rcx, rcx
    jz   .nobar
    mov  rax, [st_pos]
    cmp  rax, rcx
    cmova rax, rcx
    mov  edx, [rc_w]
    imul rax, rdx
    xor  edx, edx
    div  rcx
    xor  A1, A1
    mov  A2d, [L(0)]
    mov  A3d, eax
    lea  A4d, [r15d*2]
%ifdef WIN64
    mov  qword SARG(5), col_bar_fg
%else
    mov  A5, col_bar_fg
%endif
    call fill_rect
.nobar:
    ; ---- right text: [paused  ]vol NN  m:ss / m:ss
    lea  rbx, [txt_r]
    cmp  dword [g_paused], 0
    je   .np
    mov  A1, rbx
    lea  A2, [s_paused]
    call s_cat
    mov  rbx, rax
.np:
    mov  A1, rbx
    lea  A2, [s_vol]
    call s_cat
    mov  A1, rax
    mov  eax, [g_volstep]
    imul eax, 5
    mov  A2, rax
    mov  A3, 1
    call s_num
    mov  A1, rax
    lea  A2, [s_sep]
    call s_cat
    mov  rbx, rax
    cmp  dword [st_playing], 0
    jne  .times
    mov  A1, rbx
    lea  A2, [s_end]
    call s_cat
    jmp  .rdone
.times:
    FR2SEC [st_pos]
    mov  A1, rbx
    mov  A2, rax
    call s_time
    mov  A1, rax
    lea  A2, [s_slash]
    call s_cat
    mov  rbx, rax
    cmp  qword [st_total], 0
    jne  .tt
    mov  A1, rbx
    lea  A2, [s_q]
    call s_cat
    jmp  .rdone
.tt:FR2SEC [st_total]
    mov  A1, rbx
    mov  A2, rax
    call s_time
.rdone:
    lea  rcx, [txt_r]
    sub  rax, rcx                     ; length
    imul eax, r14d
    mov  ecx, [rc_w]
    sub  ecx, eax
    sub  ecx, r14d
    mov  [L(4)], ecx                  ; right text x
    ; text baseline
    mov  eax, [L(0)]
    sub  eax, r14d
    sub  eax, r14d
    mov  [L(8)], eax                  ; text y
    mov  A1d, [L(4)]
    mov  A2d, eax
    lea  A3, [txt_r]
    mov  A4, col_text
    call draw_text
    ; ---- left text: NN/MM  title (truncated to fit)
    lea  rbx, [txt_l]
    mov  r12d, [st_count]
    xor  r13d, r13d                   ; digits of count
    mov  eax, r12d
    mov  ecx, 10
.dg:inc  r13d
    xor  edx, edx
    div  ecx
    test eax, eax
    jnz  .dg
    cmp  r13d, 2
    jae  .dg2
    mov  r13d, 2
.dg2:
    mov  eax, [cur_idx]
    cmp  eax, r12d
    jb   .ix
    lea  eax, [r12d - 1]
.ix:inc  eax
    mov  A1, rbx
    mov  A2, rax
    mov  A3, r13
    call s_num
    mov  byte [rax], '/'
    lea  A1, [rax + 1]
    mov  A2, r12
    mov  A3, r13
    call s_num
    mov  A1, rax
    lea  A2, [s_sep]
    call s_cat
    mov  A1, rax
    lea  A2, [st_title]
    call s_cat
    ; max chars = (right_x - 3*pad) / glyph
    mov  eax, [L(4)]
    sub  eax, r14d
    sub  eax, r14d
    sub  eax, r14d
    jle  .r
    xor  edx, edx
    div  r14d
    cmp  eax, 250
    jb   .tr
    mov  eax, 250
.tr:lea  rcx, [txt_l]
    mov  byte [rcx + rax], 0
    mov  A1d, r14d
    mov  A2d, [L(8)]
    lea  A3, [txt_l]
    mov  A4, col_text_hi
    call draw_text
.r: RET_

%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
