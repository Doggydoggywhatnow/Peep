; Liberated Peep 0.3.1: Peep's playback kernel. See peep.h for the API.
;
; Freestanding: no libc, no malloc, no syscalls, no writable globals.
; Assembles for System V (Linux/macOS-style) and Microsoft x64 (-DWIN64).
; Everything lives in the caller's `peep` struct, so it is reentrant: any
; number of players, any number of threads, as long as one player is used by
; one thread at a time.

default rel
%include "abi.inc"

global peep_open, peep_fill, peep_fill32, peep_seek, peep_close


; struct peep (peep.h)
P_CODEC  equ 0
P_SRC    equ 8
P_LEN    equ 16
P_POS    equ 24
P_TOTAL  equ 32
P_RATE   equ 40
P_CH     equ 44
P_GAIN   equ 48
P_KIND   equ 52
P_DATA   equ 56
P_CTX    equ 64
P_ZERO   equ 128                  ; end of the part a failed codec open may dirty
P_WORK   equ 128
P_WSIZE  equ 136
P_WNEED  equ 144
P_ERRS   equ 152                  ; u32 damaged frames met so far (a codec increments it)
P_DITH   equ 156                  ; u16 16-bit output mode for sources wider than 16 bits: 0 truncate, 1 round, 2 TPDF dither
P_BITS   equ 158                  ; u16 bits per sample of the source (WAV: 16)
P_SIZE   equ 160
; struct peep_codec
C_OPEN   equ 0
C_READ   equ 8
C_SEEK   equ 16
C_CLOSE  equ 24
C_READ32 equ 32                   ; optional: full-resolution read (int32, left-justified)

KIND_WAV equ 1
KIND_COD equ 2

SCR      equ 192                  ; frames of scratch for >2-channel codecs
SCRBYTES equ SCR * 8 * 2          ; 3072: keeps the frame under one page
LOC_SCR  equ 32                   ; above the Win64 shadow space
LOC_C    equ 32 + SCRBYTES
HR_CHUNK equ 64                   ; frames per step on the full-resolution routes
LOC_ST   equ LOC_SCR + HR_CHUNK * 8 * 4      ; stereo int32 staging area, after the source chunk

section .text

; ----------------------------------------------------------------------------
; Internal helpers (private register convention; they never touch rbx, rbp,
; r12-r15, so callers keep their state there).
; ----------------------------------------------------------------------------

; mix_st: stereo int16 -> stereo int16 with gain, in place or not.
;   rsi = src, rdi = dst, rcx = frames, r10d = gain (0..256)
; (x * gain) >> 8 with an arithmetic shift, so the output is identical to the
; scalar loop in Peep's core.asm. SSE2 only, 4 frames per iteration.
mix_st:
    cmp  r10d, 256
    jne  .scale
    cmp  rsi, rdi
    je   .ret
    shl  rcx, 2
    rep  movsb
.ret:
    ret
.scale:
    movd xmm7, r10d
    pshuflw xmm7, xmm7, 0
    pshufd xmm7, xmm7, 0          ; gain in every word
    mov  rdx, rcx
    shr  rdx, 2
    jz   .tail
.v: movdqu xmm0, [rsi]            ; 8 samples = 4 frames
    movdqa xmm1, xmm0
    pmullw xmm0, xmm7             ; low 16 bits of each product
    pmulhw xmm1, xmm7             ; high 16 bits
    movdqa xmm2, xmm0
    punpcklwd xmm0, xmm1          ; 32-bit products
    punpckhwd xmm2, xmm1
    psrad xmm0, 8
    psrad xmm2, 8
    packssdw xmm0, xmm2           ; |x*g>>8| <= |x|: never saturates
    movdqu [rdi], xmm0
    add  rsi, 16
    add  rdi, 16
    dec  rdx
    jnz  .v
.tail:
    and  rcx, 3
    jz   .ret
.t: movsx eax, word [rsi]
    imul eax, r10d
    sar  eax, 8
    mov  [rdi], ax
    movsx eax, word [rsi + 2]
    imul eax, r10d
    sar  eax, 8
    mov  [rdi + 2], ax
    add  rsi, 4
    add  rdi, 4
    dec  rcx
    jnz  .t
    ret

; mix_gen: any channel count -> stereo with gain.
;   rsi = src, rdi = dst, rcx = frames (> 0), r10d = gain,
;   r8 = source bytes per frame, r9 = byte offset of the right channel (0 = mono)
mix_gen:
    test rcx, rcx
    jz   .d
.l: movsx eax, word [rsi]
    imul eax, r10d
    sar  eax, 8
    mov  [rdi], ax
    movsx eax, word [rsi + r9]
    imul eax, r10d
    sar  eax, 8
    mov  [rdi + 2], ax
    add  rsi, r8
    add  rdi, 4
    dec  rcx
    jnz  .l
.d: ret

; m16_32: int16 source (any channel count) -> stereo int32, left-justified, with gain.
;   rsi = src, rdi = dst, rcx = frames, r10d = gain (0..256), r8 = source bytes per frame,
;   r9 = byte offset of the right channel (0 = mono). (x * gain) << 8 is exact.
m16_32:
    test rcx, rcx
    jz   .d
.l: movsx eax, word [rsi]
    imul eax, r10d
    shl  eax, 8
    mov  [rdi], eax
    movsx eax, word [rsi + r9]
    imul eax, r10d
    shl  eax, 8
    mov  [rdi + 4], eax
    add  rsi, r8
    add  rdi, 8
    dec  rcx
    jnz  .l
.d: ret

; m32_32: int32 source -> stereo int32 with gain at 64-bit precision: (x * gain) >> 8.
;   rsi = src, rdi = dst (may equal src when src is stereo), rcx = frames, r10d = gain,
;   r8 = source bytes per frame, r9 = byte offset of the right channel (0 = mono)
m32_32:
    test rcx, rcx
    jz   .d
.l: movsxd rax, dword [rsi]
    imul rax, r10
    sar  rax, 8
    mov  [rdi], eax
    movsxd rax, dword [rsi + r9]
    imul rax, r10
    sar  rax, 8
    mov  [rdi + 4], eax
    add  rsi, r8
    add  rdi, 8
    dec  rcx
    jnz  .l
.d: ret

; conv16: int32 samples -> int16, saturating.   rsi = src, rdi = dst, rcx = sample count,
;   r10d = mode: 0 truncate, 1 round to nearest, 2 TPDF dither (triangular, +-1 LSB, then round)
;   r11d = xorshift32 state for mode 2 (the caller keeps it between calls)
conv16:
    test rcx, rcx
    jz   .d
.l: cmp  r10d, 2
    jne  .nd
    mov  eax, r11d                    ; xorshift32
    shl  eax, 13
    xor  r11d, eax
    mov  eax, r11d
    shr  eax, 17
    xor  r11d, eax
    mov  eax, r11d
    shl  eax, 5
    xor  r11d, eax
    movzx eax, r11w                   ; two uniform 16-bit numbers
    mov  edx, r11d
    shr  edx, 16
    lea  r8d, [rax + rdx - 65535]     ; their sum minus the mean: triangular, -65535 .. 65535
    movsxd r8, r8d
    movsxd rax, dword [rsi]
    lea  rax, [rax + r8 + 32768]      ; dither + rounding offset
    jmp  .s
.nd:movsxd rax, dword [rsi]
    cmp  r10d, 1
    jne  .s
    add  rax, 32768
.s: sar  rax, 16
    cmp  rax, 32767
    jle  .a
    mov  eax, 32767
.a: cmp  rax, -32768
    jge  .b
    mov  eax, -32768
.b: mov  [rdi], ax
    add  rsi, 4
    add  rdi, 2
    dec  rcx
    jnz  .l
.d: ret

; ----------------------------------------------------------------------------
; int peep_open(peep *p, const peep_codec *const *codecs, const void *data, size_t len,
;               void *work, size_t work_size)
; ----------------------------------------------------------------------------
FUNC peep_open, 0
    ARGS rbx, r12, r13, r14           ; p, codecs, data, len
    mov  rdi, rbx
    xor  eax, eax
    mov  ecx, P_SIZE / 8
    rep  stosq
    mov  dword [rbx + P_GAIN], 256
    mov  [rbx + P_SRC], r13
    mov  [rbx + P_LEN], r14
    mov  rax, IN5                     ; workspace for codecs that need one
    mov  [rbx + P_WORK], rax
    mov  rax, IN6
    mov  [rbx + P_WSIZE], rax

    ; ---- built-in 16-bit PCM WAV ------------------------------------------
    cmp  r14, 44
    jb   .codecs
    cmp  dword [r13], 'RIFF'
    jne  .codecs
    cmp  dword [r13 + 8], 'WAVE'
    jne  .codecs
    mov  r15d, 12                     ; chunk cursor
.chunk:
    lea  rax, [r15 + 8]
    cmp  rax, r14
    ja   .nowav
    mov  eax, [r13 + r15]             ; chunk id
    mov  ecx, [r13 + r15 + 4]         ; chunk size
    lea  rsi, [r15 + 8]               ; body offset
    cmp  eax, 'fmt '
    jne  .notfmt
    cmp  ecx, 16
    jb   .nowav
    lea  rdx, [rsi + 16]
    cmp  rdx, r14
    ja   .nowav
    movzx eax, word [r13 + rsi]       ; format tag
    cmp  eax, 1
    je   .tagok
    cmp  eax, 0xFFFE                  ; extensible: accept only PCM subformat
    jne  .nowav
    cmp  ecx, 40
    jb   .nowav
    lea  rdx, [rsi + 40]
    cmp  rdx, r14
    ja   .nowav
    cmp  word [r13 + rsi + 24], 1
    jne  .nowav
.tagok:
    cmp  word [r13 + rsi + 14], 16    ; 16 bits per sample
    jne  .nowav
    movzx eax, word [r13 + rsi + 2]
    mov  [rbx + P_CH], eax
    mov  eax, [r13 + rsi + 4]
    mov  [rbx + P_RATE], eax
    jmp  .next
.notfmt:
    cmp  eax, 'data'
    jne  .next
    cmp  dword [rbx + P_RATE], 0      ; data before fmt: leave it to a codec
    je   .nowav
    mov  eax, [rbx + P_CH]
    dec  eax
    cmp  eax, 7                       ; 1..8 channels
    ja   .nowav
    mov  rax, r14
    sub  rax, rsi                     ; bytes actually present
    cmp  rcx, rax
    cmova rcx, rax                    ; clamp truncated / unknown-length files
    lea  rax, [r13 + rsi]
    mov  [rbx + P_DATA], rax
    mov  eax, [rbx + P_CH]
    add  eax, eax                     ; bytes per frame
    xchg rax, rcx                     ; rax = bytes, rcx = frame size
    xor  edx, edx
    div  rcx
    mov  [rbx + P_TOTAL], rax
    mov  dword [rbx + P_KIND], KIND_WAV
    mov  word [rbx + P_BITS], 16
    jmp  .validate
.next:
    mov  eax, ecx
    and  eax, 1                       ; odd-sized chunks carry a pad byte
    add  rsi, rcx
    add  rsi, rax
    mov  r15, rsi
    jmp  .chunk
.nowav:
    mov  qword [rbx + P_RATE], 0      ; rate + channels
    mov  qword [rbx + P_TOTAL], 0
    mov  qword [rbx + P_DATA], 0

    ; ---- plugged-in codecs --------------------------------------------------
.codecs:
    test r12, r12
    jz   .fail
.cl:mov  rax, [r12]
    test rax, rax
    jz   .fail
    mov  [rbx + P_CODEC], rax
    mov  A1, rbx
    mov  A2, r13
    mov  A3, r14
    call [rax + C_OPEN]
    test eax, eax
    jnz  .gotc
    lea  rdi, [rbx + P_RATE]          ; wipe whatever a failed open left behind
    xor  eax, eax
    mov  ecx, (P_ZERO - P_RATE) / 8
    rep  stosq
    mov  dword [rbx + P_GAIN], 256
    mov  word [rbx + P_BITS], 0
    add  r12, 8
    jmp  .cl
.gotc:
    mov  dword [rbx + P_KIND], KIND_COD
    cmp  word [rbx + P_BITS], 0       ; a codec that does not say is taken to be 16-bit
    jne  .validate
    mov  word [rbx + P_BITS], 16

    ; ---- sanity: 1..8 channels, 1..1,048,575 Hz (FLAC's whole range) -----
.validate:
    mov  eax, [rbx + P_CH]
    dec  eax
    cmp  eax, 7
    ja   .bad
    mov  eax, [rbx + P_RATE]
    dec  eax
    cmp  eax, 1048574
    ja   .bad
    mov  eax, 1
    RET_
.bad:
    mov  A1, rbx
    call peep_close
.fail:
    xor  eax, eax
    RET_

; ----------------------------------------------------------------------------
; size_t peep_fill(peep *p, int16_t *out, size_t frames)
; ----------------------------------------------------------------------------
FUNC peep_fill, SCRBYTES + 16
    ARGS rbx, r12, r13                ; p, out, frames
    mov  eax, [rbx + P_GAIN]
    mov  r14d, 256
    cmp  eax, r14d
    cmova eax, r14d
    mov  r14d, eax                    ; gain, clamped to 256
    mov  eax, [rbx + P_KIND]
    cmp  eax, KIND_WAV
    je   .wav
    cmp  eax, KIND_COD
    je   .cod
.zero:
    xor  eax, eax
    RET_

    ; ---- built-in WAV: read, scale and write in one pass --------------------
.wav:
    mov  rax, [rbx + P_TOTAL]
    sub  rax, [rbx + P_POS]
    jb   .zero                        ; pos past the end (never by the API): play nothing
    cmp  r13, rax
    cmova r13, rax
    test r13, r13
    jz   .zero
    mov  ecx, [rbx + P_CH]
    lea  r8, [rcx * 2]                ; source bytes per frame
    mov  rsi, [rbx + P_POS]
    imul rsi, r8
    add  rsi, [rbx + P_DATA]
    mov  rdi, r12
    mov  rcx, r13
    mov  r10d, r14d
    cmp  dword [rbx + P_CH], 2
    jne  .wgen
    call mix_st
    jmp  .wdone
.wgen:
    xor  r9d, r9d                     ; mono: right = left
    cmp  dword [rbx + P_CH], 1
    je   .w1
    mov  r9d, 2                       ; 3+ channels: first two
.w1:call mix_gen
.wdone:
    add  [rbx + P_POS], r13
    mov  rax, r13
    RET_

    ; ---- codec -------------------------------------------------------------
.cod:
    mov  rax, [rbx + P_CODEC]         ; a source wider than 16 bits, when the volume or the output mode
    cmp  qword [rax + C_READ32], 0    ; asks for more than plain truncation, goes through the
    je   .cod16                       ; full-resolution path: gain first, then one rounding step
    cmp  word [rbx + P_BITS], 16
    jbe  .cod16
    cmp  r14d, 256
    jne  .hires
    cmp  word [rbx + P_DITH], 0
    jne  .hires
.cod16:
    cmp  dword [rbx + P_CH], 2
    jne  .multi
    mov  A1, rbx                      ; stereo: the codec writes straight into out
    mov  A2, r12
    mov  A3, r13
    mov  rax, [rbx + P_CODEC]
    call [rax + C_READ]
    cmp  rax, r13
    cmova rax, r13
    mov  r15, rax
    mov  rsi, r12
    mov  rdi, r12
    mov  rcx, r15
    mov  r10d, r14d
    call mix_st                       ; no-op at unity gain
    add  [rbx + P_POS], r15
    mov  rax, r15
    RET_
.multi:                               ; mono / 3+ channels: via stack scratch
    xor  r15d, r15d                   ; frames produced
.ml:test r13, r13
    jz   .mdone
    mov  rax, r13
    mov  ecx, SCR
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    mov  A1, rbx
    lea  A2, [rsp + LOC_SCR]
    mov  A3, rax
    mov  rax, [rbx + P_CODEC]
    call [rax + C_READ]
    test rax, rax
    jz   .mdone
    mov  rcx, [rsp + LOC_C]
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    lea  rsi, [rsp + LOC_SCR]
    mov  rdi, r12
    mov  rcx, rax
    mov  r10d, r14d
    mov  r8d, [rbx + P_CH]
    add  r8, r8
    xor  r9d, r9d
    cmp  dword [rbx + P_CH], 1
    je   .m1
    mov  r9d, 2
.m1:call mix_gen
    mov  rax, [rsp + LOC_C]
    lea  r12, [r12 + rax * 4]
    add  r15, rax
    sub  r13, rax
    jmp  .ml
.mdone:
    add  [rbx + P_POS], r15
    mov  rax, r15
    RET_
.hires:
    cmp  dword [rbx + P_DATA], 0      ; dither state: seeded on first use
    jne  .hs
    mov  dword [rbx + P_DATA], 0x9E3779B9
.hs:xor  r15d, r15d
.hl:test r13, r13
    jz   .hdone
    mov  rax, r13
    mov  ecx, HR_CHUNK
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    mov  A1, rbx
    lea  A2, [rsp + LOC_SCR]
    mov  A3, rax
    mov  rax, [rbx + P_CODEC]
    call [rax + C_READ32]
    test rax, rax
    jz   .hdone
    mov  rcx, [rsp + LOC_C]
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    lea  rsi, [rsp + LOC_SCR]
    lea  rdi, [rsp + LOC_ST]
    mov  rcx, rax
    mov  r10d, r14d
    mov  r8d, [rbx + P_CH]
    shl  r8, 2
    mov  r9d, 4
    cmp  dword [rbx + P_CH], 1
    jne  .h2
    xor  r9d, r9d
.h2:call m32_32                       ; to stereo, gain at full precision
    lea  rsi, [rsp + LOC_ST]
    mov  rdi, r12
    mov  rcx, [rsp + LOC_C]
    add  rcx, rcx
    movzx r10d, word [rbx + P_DITH]
    cmp  r10d, 2
    jbe  .h3
    mov  r10d, 2
.h3:mov  r11d, [rbx + P_DATA]
    call conv16                       ; the one reduction to 16 bits
    mov  [rbx + P_DATA], r11d
    mov  rax, [rsp + LOC_C]
    lea  r12, [r12 + rax * 4]
    add  r15, rax
    sub  r13, rax
    jmp  .hl
.hdone:
    add  [rbx + P_POS], r15
    mov  rax, r15
    RET_

; ----------------------------------------------------------------------------
; size_t peep_fill32(peep *p, int32_t *out, size_t frames)
; Full resolution: interleaved stereo int32, each sample left-justified (value << (32 - bits)), so a
; 24-bit file arrives with all 24 bits and a 16-bit file as x << 16. Volume is applied at 64-bit
; precision. Nothing is rounded or dithered. Returns the frames written; 0 = end of stream.
; ----------------------------------------------------------------------------
FUNC peep_fill32, SCRBYTES + 16
    ARGS rbx, r12, r13
    mov  eax, [rbx + P_GAIN]
    mov  r14d, 256
    cmp  eax, r14d
    cmova eax, r14d
    mov  r14d, eax
    mov  eax, [rbx + P_KIND]
    cmp  eax, KIND_WAV
    je   .wav
    cmp  eax, KIND_COD
    je   .cod
.zero:
    xor  eax, eax
    RET_
.wav:
    mov  rax, [rbx + P_TOTAL]
    sub  rax, [rbx + P_POS]
    jb   .zero
    cmp  r13, rax
    cmova r13, rax
    test r13, r13
    jz   .zero
    mov  ecx, [rbx + P_CH]
    lea  r8, [rcx * 2]
    mov  rsi, [rbx + P_POS]
    imul rsi, r8
    add  rsi, [rbx + P_DATA]
    mov  rdi, r12
    mov  rcx, r13
    mov  r10d, r14d
    xor  r9d, r9d
    cmp  dword [rbx + P_CH], 1
    je   .w1
    mov  r9d, 2
.w1:call m16_32
    add  [rbx + P_POS], r13
    mov  rax, r13
    RET_
.cod:
    mov  rax, [rbx + P_CODEC]
    cmp  qword [rax + C_READ32], 0
    je   .c16
    cmp  dword [rbx + P_CH], 2
    jne  .c32
    mov  A1, rbx                      ; stereo: the codec writes straight into out
    mov  A2, r12
    mov  A3, r13
    call [rax + C_READ32]
    cmp  rax, r13
    cmova rax, r13
    mov  r15, rax
    mov  rsi, r12
    mov  rdi, r12
    mov  rcx, r15
    mov  r10d, r14d
    mov  r8d, 8
    mov  r9d, 4
    call m32_32
    add  [rbx + P_POS], r15
    mov  rax, r15
    RET_
.c32:                                 ; mono / 3+ channels through the scratch area
    xor  r15d, r15d
.c3l:test r13, r13
    jz   .cdone
    mov  rax, r13
    mov  ecx, HR_CHUNK
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    mov  A1, rbx
    lea  A2, [rsp + LOC_SCR]
    mov  A3, rax
    mov  rax, [rbx + P_CODEC]
    call [rax + C_READ32]
    test rax, rax
    jz   .cdone
    mov  rcx, [rsp + LOC_C]
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    lea  rsi, [rsp + LOC_SCR]
    mov  rdi, r12
    mov  rcx, rax
    mov  r10d, r14d
    mov  r8d, [rbx + P_CH]
    shl  r8, 2
    mov  r9d, 4
    cmp  dword [rbx + P_CH], 1
    jne  .c3m
    xor  r9d, r9d
.c3m:call m32_32
    mov  rax, [rsp + LOC_C]
    lea  r12, [r12 + rax * 8]
    add  r15, rax
    sub  r13, rax
    jmp  .c3l
.c16:                                 ; a codec without read32: widen its 16-bit output
    xor  r15d, r15d
.c1l:test r13, r13
    jz   .cdone
    mov  rax, r13
    mov  ecx, SCR
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    mov  A1, rbx
    lea  A2, [rsp + LOC_SCR]
    mov  A3, rax
    mov  rax, [rbx + P_CODEC]
    call [rax + C_READ]
    test rax, rax
    jz   .cdone
    mov  rcx, [rsp + LOC_C]
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rsp + LOC_C], rax
    lea  rsi, [rsp + LOC_SCR]
    mov  rdi, r12
    mov  rcx, rax
    mov  r10d, r14d
    mov  r8d, [rbx + P_CH]
    add  r8, r8
    xor  r9d, r9d
    cmp  dword [rbx + P_CH], 1
    je   .c1m
    mov  r9d, 2
.c1m:call m16_32
    mov  rax, [rsp + LOC_C]
    lea  r12, [r12 + rax * 8]
    add  r15, rax
    sub  r13, rax
    jmp  .c1l
.cdone:
    add  [rbx + P_POS], r15
    mov  rax, r15
    RET_

; ----------------------------------------------------------------------------
; void peep_seek(peep *p, uint64_t frame)
; ----------------------------------------------------------------------------
FUNC peep_seek, 0
    ARGS rbx, r12
    mov  eax, [rbx + P_KIND]
    test eax, eax
    jz   .r
    mov  rax, [rbx + P_TOTAL]
    cmp  dword [rbx + P_KIND], KIND_WAV
    je   .clamp                       ; built-in WAV: always clamp, even at 0
    test rax, rax
    jz   .nc                          ; codec with unknown length: no clamp
.clamp:
    cmp  r12, rax
    cmova r12, rax
.nc:mov  [rbx + P_POS], r12
    cmp  dword [rbx + P_KIND], KIND_COD
    jne  .r
    mov  rax, [rbx + P_CODEC]
    mov  rax, [rax + C_SEEK]
    test rax, rax
    jz   .r
    mov  A1, rbx
    mov  A2, r12
    call rax
.r: RET_

; ----------------------------------------------------------------------------
; void peep_close(peep *p)
; ----------------------------------------------------------------------------
FUNC peep_close, 0
    ARGS rbx
    cmp  dword [rbx + P_KIND], KIND_COD
    jne  .z
    mov  rax, [rbx + P_CODEC]
    mov  rax, [rax + C_CLOSE]
    test rax, rax
    jz   .z
    mov  A1, rbx
    call rax
.z: mov  dword [rbx + P_KIND], 0
    mov  qword [rbx + P_POS], 0
    mov  qword [rbx + P_TOTAL], 0
    RET_

%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
