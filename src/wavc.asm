; Liberated Peep compressed-WAV codec (x86-64): the WAV files that are not plain PCM or float.
;
;   * A-law (format 6) and mu-law (format 7): 1 to 8 channels, 8 bits, plain or WAVE_FORMAT_EXTENSIBLE
;   * IMA ADPCM (format 0x11) and Microsoft ADPCM (format 2): mono or stereo, 4 bits per sample
;   * output is 16-bit PCM (p->bits = 16); read32() gives each sample << 16
;   * IMA ADPCM follows the reference algorithm (diff = step>>3 plus step>>2, step>>1, step as the code bits say), the one libsndfile
;     and Windows use. ffmpeg uses a slightly different rounding, so ffmpeg-made IMA files differ from this by a few units.
;   * MS ADPCM uses the coefficient table in the file's fmt chunk; the prediction is divided by 256 truncating toward zero
;   * a 'fact' chunk, when present, trims the padding of the last ADPCM block; a partial last block plays the groups it holds
;   * freestanding: no libc, no allocation. ADPCM needs an 80-byte workspace (work_need protocol); A-law and mu-law need none
;   * seeking decodes from the start of the block that holds the frame (at most one block of work)
;
; Plug it in:  const peep_codec *c[] = { &peep_codec_wavc, &peep_codec_wavx, &peep_codec_flac, NULL };
;
default rel
%include "abi.inc"

P_SRC    equ 8
P_LEN    equ 16
P_TOTAL  equ 32
P_RATE   equ 40
P_CH     equ 44
P_CTX    equ 64
P_WORK   equ 128
P_WSIZE  equ 136
P_WNEED  equ 144
P_BITS   equ 158

S_BASE   equ 72                   ; u64 address of the first byte of the data chunk
S_POS    equ 80                   ; u64 next frame to hand out
S_DPOS   equ 88                   ; u64 the frame the ADPCM decoder state is positioned at (-1: none yet)
S_BLKP   equ 96                   ; u64 address of the block the decoder is in
S_COEF   equ 104                  ; u64 MS ADPCM: address of the coefficient pairs (int16, int16) in the file's fmt chunk
S_FMT    equ 112                  ; u32 1 A-law, 2 mu-law, 3 IMA ADPCM, 4 MS ADPCM
S_SPB    equ 116                  ; u32 frames per ADPCM block
S_BA     equ 120                  ; u32 block align
S_W      equ 124                  ; u32 index of the next frame inside the current block

; workspace (ADPCM): 32 bytes per channel: +0 predictor / sample1, +4 step index / sample2, +8 delta, +12 coef1, +16 coef2; +64 u32 number of coefficient pairs
WORKNEED equ 80

%define LOC(o) [rbp - 64 - 2112 + (o)]
L_STEP   equ 2048                 ; 16 bytes: output of frames that are decoded and thrown away (seeking)
L_N      equ 2056                 ; frames of the current wc_rd call
L_REM    equ 2064                 ; read32: frames still to hand out
L_M      equ 2072                 ; read32: frames in this chunk

section .text

align 8
ima_index: db -1, -1, -1, -1, 2, 4, 6, 8
align 8
ms_adapt:  dw 230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230
ima_step:  dw 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118
           dw 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166
           dw 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845
           dw 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767

; ----------------------------------------------------------------------------------------------------------------
; ima_nib: edx = 4-bit code, r10 = channel state -> eax = the new sample (also stored). Clobbers rax rcx rdx r15.
ima_nib:
    mov  eax, [r10 + 4]               ; step index
    lea  rcx, [rel ima_step]
    movzx r15d, word [rcx + rax * 2]  ; step
    mov  ecx, r15d
    shr  ecx, 3                       ; diff = step >> 3
    test dl, 1
    jz   .a
    mov  eax, r15d
    shr  eax, 2
    add  ecx, eax
.a: test dl, 2
    jz   .b
    mov  eax, r15d
    shr  eax, 1
    add  ecx, eax
.b: test dl, 4
    jz   .c
    add  ecx, r15d
.c: test dl, 8
    jz   .d
    neg  ecx
.d: add  ecx, [r10]                   ; predictor + diff, saturated to 16 bits
    cmp  ecx, 32767
    jle  .e
    mov  ecx, 32767
.e: cmp  ecx, -32768
    jge  .f
    mov  ecx, -32768
.f: mov  [r10], ecx
    mov  eax, [r10 + 4]
    and  edx, 7
    lea  r15, [rel ima_index]
    movsx edx, byte [r15 + rdx]
    add  eax, edx
    jns  .g
    xor  eax, eax
.g: cmp  eax, 88
    jbe  .h
    mov  eax, 88
.h: mov  [r10 + 4], eax
    mov  eax, ecx
    ret

; ms_nib: edx = 4-bit code (zero-extended), r10 = channel state -> eax = the new sample. Clobbers rax rcx rdx r15.
ms_nib:
    movsxd rax, dword [r10]           ; sample1
    movsxd rcx, dword [r10 + 12]      ; coef1
    imul rax, rcx
    movsxd rcx, dword [r10 + 4]       ; sample2
    movsxd r15, dword [r10 + 16]      ; coef2
    imul rcx, r15
    add  rax, rcx
    mov  rcx, rax
    sar  rcx, 63
    and  ecx, 255                     ; divide by 256 truncating toward zero: add 255 to a negative number first
    add  rax, rcx
    sar  rax, 8
    mov  ecx, edx
    test dl, 8
    jz   .p
    sub  ecx, 16                      ; the code as a signed 4-bit number
.p: movsxd rcx, ecx
    movsxd r15, dword [r10 + 8]       ; delta
    imul rcx, r15
    add  rax, rcx
    mov  rcx, 32767
    cmp  rax, rcx
    cmovg rax, rcx
    mov  rcx, -32768
    cmp  rax, rcx
    cmovl rax, rcx
    mov  ecx, [r10]
    mov  [r10 + 4], ecx               ; sample2 = sample1
    mov  [r10], eax                   ; sample1 = the new one
    lea  rcx, [rel ms_adapt]
    movzx ecx, word [rcx + rdx * 2]
    movsxd r15, dword [r10 + 8]
    imul rcx, r15
    sar  rcx, 8                       ; delta = max(16, adapt * delta >> 8), and kept below 2^24 so a damaged stream cannot overflow
    cmp  rcx, 16
    jge  .q
    mov  ecx, 16
.q: cmp  rcx, 0x1000000
    jle  .r
    mov  ecx, 0x1000000
.r: mov  [r10 + 8], ecx
    ret

; step: decode one ADPCM frame at the decoder's position into [rdi] (int16 per channel); rdi advances; the position moves on.
; Clobbers rax rcx rdx rsi r8-r11 (saves r14, r15).
step:
    push r14
    push r15
    mov  r8d, [rbx + S_W]
    mov  rsi, [rbx + S_BLKP]
    mov  r11, [rbx + P_WORK]
    mov  r14d, [rbx + P_CH]
    cmp  dword [rbx + S_FMT], 3
    jne  .ms
    test r8d, r8d
    jnz  .ima_n
    xor  r9d, r9d                     ; IMA block start: the header holds the first sample and the state of each channel
.ih:movsx eax, word [rsi + r9 * 4]
    movzx edx, byte [rsi + r9 * 4 + 2]
    cmp  edx, 88
    jbe  .ih1
    mov  edx, 88
.ih1:
    mov  r10, r9
    shl  r10, 5
    mov  [r11 + r10], eax
    mov  [r11 + r10 + 4], edx
    mov  [rdi + r9 * 2], ax
    inc  r9d
    cmp  r9d, r14d
    jb   .ih
    jmp  .adv
.ima_n:                               ; frame w >= 1 is code k = (w-1) & 7 of group g = (w-1) >> 3, one 4-byte run per channel
    lea  eax, [r8 - 1]
    mov  edx, eax
    shr  eax, 3
    and  edx, 7
    inc  eax
    imul eax, r14d
    shl  eax, 2                       ; 4 * ch * (g + 1): header plus the earlier groups
    mov  r8d, edx
    shr  r8d, 1
    add  eax, r8d                     ; plus k >> 1
    add  rsi, rax                     ; the byte of channel 0
    and  edx, 1
    shl  edx, 2
    mov  r8d, edx                     ; 0 for the low nibble, 4 for the high one
    xor  r9d, r9d
.in:movzx edx, byte [rsi + r9 * 4]
    mov  ecx, r8d
    shr  edx, cl
    and  edx, 15
    mov  r10, r9
    shl  r10, 5
    add  r10, r11
    call ima_nib
    mov  [rdi + r9 * 2], ax
    inc  r9d
    cmp  r9d, r14d
    jb   .in
    jmp  .adv
.ms:
    cmp  r8d, 2
    jae  .ms_n
    test r8d, r8d
    jnz  .ms_1
    xor  r9d, r9d                     ; MS block start: per channel predictor index, delta, sample1, sample2 (header = 7 * ch bytes)
.mh:movzx eax, byte [rsi + r9]
    cmp  eax, [r11 + 64]
    jb   .mh1
    mov  eax, [r11 + 64]
    dec  eax                          ; an out-of-range predictor index uses the last pair
.mh1:
    mov  rcx, [rbx + S_COEF]
    movsx edx, word [rcx + rax * 4]
    movsx r15d, word [rcx + rax * 4 + 2]
    mov  r10, r9
    shl  r10, 5
    add  r10, r11
    mov  [r10 + 12], edx
    mov  [r10 + 16], r15d
    lea  rax, [r14 + r9 * 2]          ; delta at ch + 2c
    movsx edx, word [rsi + rax]       ; the header delta is used as it stands (libsndfile and ffmpeg do the same); only the update floors it at 16
    mov  [r10 + 8], edx
    lea  rax, [r14 * 2 + r14]
    lea  rax, [rax + r9 * 2]          ; sample1 at 3ch + 2c
    movsx edx, word [rsi + rax]
    mov  [r10], edx
    lea  rax, [r14 * 4 + r14]
    lea  rax, [rax + r9 * 2]          ; sample2 at 5ch + 2c
    movsx edx, word [rsi + rax]
    mov  [r10 + 4], edx
    mov  [rdi + r9 * 2], dx           ; frame 0 is sample2
    inc  r9d
    cmp  r9d, r14d
    jb   .mh
    jmp  .adv
.ms_1:                                ; frame 1 is sample1 of each channel
    xor  r9d, r9d
.m1:mov  r10, r9
    shl  r10, 5
    add  r10, r11
    mov  eax, [r10]
    mov  [rdi + r9 * 2], ax
    inc  r9d
    cmp  r9d, r14d
    jb   .m1
    jmp  .adv
.ms_n:
    lea  eax, [r8 - 2]                ; j: the nibble index (per channel)
    cmp  r14d, 1
    je   .ms_mono
    movzx edx, byte [rsi + 14 + rax]  ; stereo: the high nibble is left, the low one right
    mov  r9d, edx                     ; (ms_nib uses r15, so the byte waits in r9)
    shr  edx, 4
    mov  r10, r11
    call ms_nib
    mov  [rdi], ax
    mov  edx, r9d
    and  edx, 15
    lea  r10, [r11 + 32]
    call ms_nib
    mov  [rdi + 2], ax
    jmp  .adv
.ms_mono:
    mov  edx, eax
    shr  eax, 1
    movzx r15d, byte [rsi + 7 + rax]  ; mono: the high nibble first
    mov  eax, r15d
    test dl, 1
    jz   .mm
    and  eax, 15
    jmp  .mm2
.mm:shr  eax, 4
.mm2:
    mov  edx, eax
    mov  r10, r11
    call ms_nib
    mov  [rdi], ax
.adv:
    mov  eax, [rbx + S_W]
    inc  eax
    cmp  eax, [rbx + S_SPB]
    jb   .a1
    xor  eax, eax
    mov  rcx, [rbx + S_BLKP]
    mov  edx, [rbx + S_BA]
    add  rcx, rdx
    mov  [rbx + S_BLKP], rcx
.a1:mov  [rbx + S_W], eax
    inc  qword [rbx + S_DPOS]
    lea  rdi, [rdi + r14 * 2]
    pop  r15
    pop  r14
    ret

; wc_adpcm: rdi = output (int16), r13 = frames (>= 1): from the current position S_POS. Resynchronises to the start of the block that holds
; S_POS when the decoder is somewhere else (a seek, or the very first read) by decoding and discarding up to one block of frames.
wc_adpcm:
    mov  rax, [rbx + S_POS]
    cmp  rax, [rbx + S_DPOS]
    je   .go
    xor  edx, edx
    mov  ecx, [rbx + S_SPB]
    div  rcx                          ; rax = block, rdx = frames into it
    mov  r14, rdx
    mov  rcx, rax
    mov  eax, [rbx + S_BA]
    imul rcx, rax
    add  rcx, [rbx + S_BASE]
    mov  [rbx + S_BLKP], rcx
    mov  dword [rbx + S_W], 0
    mov  rax, [rbx + S_POS]
    sub  rax, r14
    mov  [rbx + S_DPOS], rax
    push rdi
    test r14, r14
    jz   .dd
.dl:lea  rdi, LOC(L_STEP)
    call step
    dec  r14
    jnz  .dl
.dd:pop  rdi
.go:mov  r14, r13
.l: call step
    dec  r14
    jnz  .l
    ret

; wc_rd: produce r13 frames (already limited to what is left) into [rdi] as int16 in the file's own channel count; the position advances.
; Preserves r13, r14, r15.
wc_rd:
    push r14
    push r15
    mov  LOC(L_N), r13
    cmp  dword [rbx + S_FMT], 2
    ja   .adpcm
    mov  rax, [rbx + S_POS]           ; A-law / mu-law: one byte per sample, stateless
    mov  ecx, [rbx + P_CH]
    imul rax, rcx
    add  rax, [rbx + S_BASE]
    mov  rsi, rax
    imul rcx, r13
    mov  r9, rcx                      ; samples
    test r9, r9
    jz   .done
    cmp  dword [rbx + S_FMT], 2
    je   .mulaw
.al:movzx eax, byte [rsi]
    inc  rsi
    xor  eax, 0x55
    mov  edx, eax
    and  edx, 15
    shl  edx, 4
    mov  r8d, eax
    shr  r8d, 4
    and  r8d, 7
    jnz  .al_hi
    add  edx, 8
    jmp  .al_s
.al_hi:
    add  edx, 0x108
    lea  ecx, [r8 - 1]
    shl  edx, cl
.al_s:
    test al, 0x80
    jnz  .al_p
    neg  edx
.al_p:
    mov  [rdi], dx
    add  rdi, 2
    dec  r9
    jnz  .al
    jmp  .done
.mulaw:
    movzx eax, byte [rsi]
    inc  rsi
    not  eax
    and  eax, 0xFF
    mov  edx, eax
    and  edx, 15
    shl  edx, 3
    add  edx, 0x84
    mov  ecx, eax
    shr  ecx, 4
    and  ecx, 7
    shl  edx, cl
    test al, 0x80
    jz   .ml_p
    neg  edx
    add  edx, 0x84
    jmp  .ml_s
.ml_p:
    sub  edx, 0x84
.ml_s:
    mov  [rdi], dx
    add  rdi, 2
    dec  r9
    jnz  .mulaw
    jmp  .done
.adpcm:
    call wc_adpcm
.done:
    mov  r13, LOC(L_N)
    add  [rbx + S_POS], r13
    pop  r15
    pop  r14
    ret

; wc_take: r13 = frames wanted -> frames available; CF set (and r13 = 0) when nothing is left.
wc_take:
    mov  rax, [rbx + P_TOTAL]
    mov  rcx, [rbx + S_POS]
    sub  rax, rcx
    jbe  .none
    cmp  r13, rax
    cmova r13, rax
    test r13, r13
    jz   .none
    clc
    ret
.none:
    xor  r13d, r13d
    stc
    ret

; size_t read(peep *p, int16_t *out, size_t frames)
FUNCL wc_read, 2112
    ARGS rbx, r12, r13
    call wc_take
    jc   .z
    mov  r15, r13
    mov  rdi, r12
    call wc_rd
    mov  r13, r15
.z: mov  rax, r13
    RET_

; size_t read32(peep *p, int32_t *out, size_t frames): each sample << 16
FUNCL wc_read32, 2112
    ARGS rbx, r12, r13
    call wc_take
    jc   .z
    mov  r15, r13
    mov  LOC(L_REM), r13
.chunk:
    mov  rax, LOC(L_REM)
    test rax, rax
    jz   .fin
    mov  r13d, 128
    cmp  rax, r13
    cmovb r13, rax
    sub  rax, r13
    mov  LOC(L_REM), rax
    mov  LOC(L_M), r13
    lea  rdi, LOC(0)
    call wc_rd
    lea  rsi, LOC(0)
    mov  ecx, [rbx + P_CH]
    imul rcx, LOC(L_M)
.w: movsx eax, word [rsi]
    shl  eax, 16
    mov  [r12], eax
    add  rsi, 2
    add  r12, 4
    dec  rcx
    jnz  .w
    jmp  .chunk
.fin:
    mov  r13, r15
.z: mov  rax, r13
    RET_

; void seek(peep *p, uint64_t frame)
FUNCL wc_seek, 0
    ARGS rbx, r12
    mov  rax, [rbx + P_TOTAL]
    cmp  r12, rax
    cmova r12, rax
    mov  [rbx + S_POS], r12
    RET_

; int open(peep *p, const void *data, size_t len)
FUNCL wc_open, 0
    ARGS rbx, r12, r13
    cmp  r13, 44
    jb   .fail
    cmp  dword [r12], 'RIFF'
    jne  .fail
    cmp  dword [r12 + 8], 'WAVE'
    jne  .fail
    mov  dword [rbx + S_FMT], 0
    xor  r15d, r15d                   ; 'fact' sample count, 0 = none
    mov  r14d, 12                     ; chunk cursor
.chunk:
    lea  rax, [r14 + 8]
    cmp  rax, r13
    ja   .fail
    mov  eax, [r12 + r14]             ; chunk id
    mov  ecx, [r12 + r14 + 4]         ; chunk size
    lea  rsi, [r14 + 8]               ; body offset
    cmp  eax, 'fmt '
    je   .fmt
    cmp  eax, 'fact'
    je   .fact
    cmp  eax, 'data'
    je   .data
.next:
    mov  eax, ecx
    and  eax, 1                       ; odd-sized chunks carry a pad byte
    add  rsi, rcx
    add  rsi, rax
    mov  r14, rsi
    jmp  .chunk
.fact:
    cmp  ecx, 4
    jb   .next
    lea  rdx, [rsi + 4]
    cmp  rdx, r13
    ja   .next                        ; the body is not all in the file: treat the chunk as absent
    mov  r15d, [r12 + rsi]
    jmp  .next
.fmt:
    cmp  ecx, 16
    jb   .fail
    lea  rdx, [rsi + 16]
    cmp  rdx, r13
    ja   .fail
    movzx eax, word [r12 + rsi]       ; format tag
    cmp  eax, 0xFFFE
    jne  .tg
    cmp  ecx, 40                      ; extensible: only A-law and mu-law (the sub-format's first word is the tag)
    jb   .fail
    lea  rdx, [rsi + 40]
    cmp  rdx, r13
    ja   .fail
    movzx eax, word [r12 + rsi + 24]
    cmp  eax, 6
    je   .tg
    cmp  eax, 7
    jne  .fail
.tg:
    movzx r10d, word [r12 + rsi + 2]  ; channels
    lea  edx, [r10 - 1]
    cmp  edx, 7
    ja   .fail
    cmp  eax, 6
    je   .law
    cmp  eax, 7
    je   .law
    cmp  r10d, 2                      ; ADPCM: mono or stereo, 4 bits
    ja   .fail
    cmp  word [r12 + rsi + 14], 4
    jne  .fail
    movzx r8d, word [r12 + rsi + 12]  ; block align
    cmp  eax, 0x11
    je   .ima
    cmp  eax, 2
    jne  .fail
    lea  eax, [r10 * 8]               ; MS ADPCM: header 7 * ch bytes, then at least one byte of codes
    sub  eax, r10d
    cmp  r8d, eax
    jbe  .fail
    cmp  ecx, 22
    jb   .fail
    movzx r9d, word [r12 + rsi + 20]  ; number of coefficient pairs
    test r9d, r9d
    jz   .fail
    lea  eax, [r9 * 4 + 22]
    cmp  eax, ecx
    ja   .fail
    mov  [rbx + P_CTX], r9            ; kept until the data chunk, then copied to the workspace
    lea  rax, [r12 + rsi + 22]
    mov  [rbx + S_COEF], rax
    lea  eax, [r10 * 8]
    sub  eax, r10d
    mov  r11d, eax                    ; 7 * ch
    mov  eax, r8d
    sub  eax, r11d
    add  eax, eax
    xor  edx, edx
    div  r10d
    add  eax, 2                       ; frames per block = 2 + (ba - 7ch) * 2 / ch
    mov  edx, 4
    jmp  .setfmt
.ima:
    lea  r11d, [r10 * 4]              ; IMA ADPCM: 4 * ch header bytes, then whole groups of 4 * ch bytes
    lea  eax, [r11 + r11]
    cmp  r8d, eax
    jb   .fail
    mov  eax, r8d
    xor  edx, edx
    div  r11d
    test edx, edx
    jnz  .fail
    mov  eax, r8d
    sub  eax, r11d
    add  eax, eax
    xor  edx, edx
    div  r10d
    inc  eax                          ; frames per block = (ba - 4ch) * 2 / ch + 1
    mov  edx, 3
    jmp  .setfmt
.law:
    cmp  word [r12 + rsi + 14], 8
    jne  .fail
    lea  edx, [rax - 5]               ; 6 -> 1, 7 -> 2
    movzx r8d, word [r12 + rsi + 12]
    xor  eax, eax
.setfmt:
    mov  [rbx + S_FMT], edx
    mov  [rbx + S_SPB], eax
    mov  [rbx + S_BA], r8d
    mov  [rbx + P_CH], r10d
    mov  eax, [r12 + rsi + 4]
    mov  [rbx + P_RATE], eax
    mov  word [rbx + P_BITS], 16
    jmp  .next
.data:
    mov  edx, [rbx + S_FMT]
    test edx, edx
    jz   .fail
    mov  rax, r13
    sub  rax, rsi                     ; bytes actually present
    cmp  rcx, rax
    cmova rcx, rax                    ; clamp truncated / unknown-length files
    lea  rax, [r12 + rsi]
    mov  [rbx + S_BASE], rax
    mov  r9, rcx                      ; r9 = bytes of data
    mov  r10d, [rbx + P_CH]
    cmp  edx, 2
    ja   .adpcm
    mov  rax, r9                      ; A-law / mu-law: frames = bytes / channels
    xor  edx, edx
    div  r10
    jmp  .total
.adpcm:
    cmp  qword [rbx + P_WORK], 0      ; the decoder state lives in the host's workspace
    je   .need
    cmp  qword [rbx + P_WSIZE], WORKNEED
    jb   .need
    mov  rax, [rbx + P_WORK]
    mov  rdx, [rbx + P_CTX]
    mov  [rax + 64], edx              ; number of coefficient pairs (MS ADPCM)
    mov  r8d, [rbx + S_BA]
    mov  rax, r9
    xor  edx, edx
    div  r8                           ; rax = whole blocks, rdx = bytes left over
    mov  r11d, [rbx + S_SPB]
    imul rax, r11
    mov  r11, rax                     ; frames of the whole blocks
    cmp  dword [rbx + S_FMT], 3
    jne  .msrem
    lea  r8, [r10 * 4]                ; IMA: a partial block holds 1 + 8 frames per whole group after the header
    cmp  rdx, r8
    jb   .remdone
    sub  rdx, r8
    mov  rax, rdx
    xor  edx, edx
    div  r8
    lea  rax, [rax * 8 + 1]
    add  r11, rax
    jmp  .remdone
.msrem:
    lea  r8, [r10 * 8]                ; MS: a partial block holds 2 + (bytes - 7ch) * 2 / ch frames
    sub  r8, r10
    cmp  rdx, r8
    jb   .remdone
    sub  rdx, r8
    lea  rax, [rdx * 2]
    xor  edx, edx
    div  r10
    add  rax, 2
    add  r11, rax
.remdone:
    mov  rax, r11
    test r15d, r15d                   ; a 'fact' chunk trims the padding of the last block
    jz   .total
    cmp  rax, r15
    jbe  .total
    mov  eax, r15d
.total:
    mov  [rbx + P_TOTAL], rax
    mov  qword [rbx + S_POS], 0
    mov  qword [rbx + S_DPOS], -1
    mov  dword [rbx + S_W], 0
    mov  eax, 1
    RET_
.need:
    mov  qword [rbx + P_WNEED], WORKNEED
.fail:
    xor  eax, eax
    RET_

; const peep_codec *peep_wavc(void)
%ifdef WIN64
global peep_wavc
peep_wavc:
    lea  rax, [rel peep_codec_wavc]
    ret
%else
global peep_wavc:function
peep_wavc:
    mov  rax, [rel peep_codec_wavc wrt ..got]
    ret
%endif

; ============================================================================
%ifdef WIN64
section .rdata align=8
%else
section .data.rel.ro progbits alloc noexec write align=8
%endif
global peep_codec_wavc
peep_codec_wavc: dq wc_open, wc_read, wc_seek, 0, wc_read32

%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
