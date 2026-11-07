; Liberated Peep WAV extension codec (x86-64): the PCM and float WAV files the built-in
; 16-bit decoder does not take.
;
;   * unsigned 8-bit, signed 16 / 24 / 32-bit PCM (any valid-bits value up to the container size,
;     so 12-bit and 20-bit files work), 32-bit and 64-bit IEEE float; plain or WAVE_FORMAT_EXTENSIBLE
;   * 1 to 8 channels, odd chunks, unknown-length data, truncated files (the same parser rules as the core)
;   * freestanding like everything else here: no libc, no allocation, no workspace (work_need stays 0)
;   * read32() gives every sample left-justified in an int32 (value << (32 - container bits)); float is
;     scaled by 2^31, rounded to nearest even and clipped (NaN is 0); read() gives the top 16 bits
;   * p->bits is the file's valid bit depth (float: 32), so peep_fill32 and the dithered 16-bit output
;     of the core use the full resolution
;
; Plug it in with the other codecs:  const peep_codec *c[] = { &peep_codec_wavx, &peep_codec_flac, NULL };
;
default rel
%include "abi.inc"


P_TOTAL  equ 32
P_RATE   equ 40
P_CH     equ 44
P_BITS   equ 158

S_BASE   equ 72                   ; u64 address of the first sample frame
S_POS    equ 80                   ; u64 next frame to hand out
S_FSZ    equ 88                   ; u32 bytes per frame
S_FMT    equ 92                   ; u32 1 u8, 2 s16, 3 s24, 4 s32, 5 f32, 6 f64

%define LOC(o) [rbp - 64 - 1024 + (o)]

section .text

align 8
c_hi:   dq 0x41DFFFFFFFE00000     ; 2147483647.5: at or above this a float sample saturates
c_scl:  dq 0x41E0000000000000     ; 2147483648.0 = 2^31

; wx_conv: rsi = source, rdi = destination int32, rcx = sample count, edx = format code.
; Clobbers rax, rcx, rsi, rdi, r8, xmm0. Does not touch r9-r15.
wx_conv:
    test rcx, rcx
    jz   .ret
    cmp  edx, 2
    je   .s16
    ja   .hi
.u8:                              ; unsigned: flip the sign bit
    movzx eax, byte [rsi]
    inc  rsi
    xor  eax, 0x80
    shl  eax, 24
    mov  [rdi], eax
    add  rdi, 4
    dec  rcx
    jnz  .u8
.ret:
    ret
.s16:
    movzx eax, word [rsi]
    add  rsi, 2
    shl  eax, 16
    mov  [rdi], eax
    add  rdi, 4
    dec  rcx
    jnz  .s16
    ret
.hi:
    cmp  edx, 4
    je   .s32
    jb   .s24
    cmp  edx, 5
    je   .f32
.f64:
    movsd xmm0, [rsi]
    add  rsi, 8
    call .fd
    dec  rcx
    jnz  .f64
    ret
.f32:
    cvtss2sd xmm0, [rsi]          ; float to double is exact
    add  rsi, 4
    call .fd
    dec  rcx
    jnz  .f32
    ret
.fd:                              ; xmm0 = sample (double) -> store int32 at rdi
    mulsd xmm0, [rel c_scl]       ; exact: a power of two
    ucomisd xmm0, [rel c_hi]
    jp   .nan                     ; unordered: NaN
    jae  .sat
    cvtsd2si eax, xmm0            ; nearest even; anything below -2^31 comes out as -2^31 as well
    jmp  .st
.nan:
    xor  eax, eax
    jmp  .st
.sat:
    mov  eax, 0x7FFFFFFF
.st:mov  [rdi], eax
    add  rdi, 4
    ret
.s24:
    movzx eax, word [rsi]
    movzx r8d, byte [rsi + 2]
    add  rsi, 3
    shl  r8d, 16
    or   eax, r8d
    shl  eax, 8
    mov  [rdi], eax
    add  rdi, 4
    dec  rcx
    jnz  .s24
    ret
.s32:
    mov  eax, [rsi]
    add  rsi, 4
    mov  [rdi], eax
    add  rdi, 4
    dec  rcx
    jnz  .s32
    ret

; int open(peep *p, const void *data, size_t len)
FUNCL wx_open, 0
    ARGS rbx, r12, r13
    cmp  r13, 44
    jb   .fail
    cmp  dword [r12], 'RIFF'
    jne  .fail
    cmp  dword [r12 + 8], 'WAVE'
    jne  .fail
    mov  dword [rbx + S_FMT], 0       ; no fmt chunk seen yet
    mov  r14d, 12                     ; chunk cursor
.chunk:
    lea  rax, [r14 + 8]
    cmp  rax, r13
    ja   .fail
    mov  eax, [r12 + r14]             ; chunk id
    mov  ecx, [r12 + r14 + 4]         ; chunk size
    lea  rsi, [r14 + 8]               ; body offset
    cmp  eax, 'fmt '
    jne  .notfmt
    cmp  ecx, 16
    jb   .fail
    lea  rdx, [rsi + 16]
    cmp  rdx, r13
    ja   .fail
    movzx eax, word [r12 + rsi]       ; format tag
    movzx r8d, word [r12 + rsi + 14]  ; bits per sample
    cmp  eax, 1
    je   .tag
    cmp  eax, 3
    je   .tag
    cmp  eax, 0xFFFE                  ; extensible: valid bits and the sub-format decide
    jne  .fail
    cmp  ecx, 40
    jb   .fail
    lea  rdx, [rsi + 40]
    cmp  rdx, r13
    ja   .fail
    movzx r8d, word [r12 + rsi + 18]  ; valid bits
    movzx eax, word [r12 + rsi + 24]  ; sub-format
    cmp  eax, 1
    je   .tag
    cmp  eax, 3
    jne  .fail
.tag:
    mov  r9d, eax                     ; 1 PCM, 3 float
    movzx r10d, word [r12 + rsi + 2]  ; channels
    lea  eax, [r10 - 1]
    cmp  eax, 7
    ja   .fail
    movzx eax, word [r12 + rsi + 12]  ; block align
    xor  edx, edx
    div  r10d                         ; eax = bytes per sample
    test edx, edx
    jnz  .fail
    lea  edx, [rax * 8]
    test r8d, r8d
    jnz  .vb
    mov  r8d, edx                     ; 0 means all of the container
.vb:cmp  r8d, edx
    ja   .fail
    cmp  r9d, 3
    je   .isfl
    cmp  eax, 1
    jb   .fail
    cmp  eax, 4
    ja   .fail
    mov  edx, eax                     ; PCM: format code = bytes per sample
    jmp  .setfmt
.isfl:
    mov  r8d, 32
    mov  edx, 5
    cmp  eax, 4
    je   .setfmt
    mov  edx, 6
    cmp  eax, 8
    jne  .fail
.setfmt:
    mov  [rbx + S_FMT], edx
    imul eax, r10d
    mov  [rbx + S_FSZ], eax
    mov  [rbx + P_CH], r10d
    mov  eax, [r12 + rsi + 4]
    mov  [rbx + P_RATE], eax
    mov  [rbx + P_BITS], r8w
    jmp  .next
.notfmt:
    cmp  eax, 'data'
    jne  .next
    cmp  dword [rbx + S_FMT], 0       ; data before fmt: not understood
    je   .fail
    mov  rax, r13
    sub  rax, rsi                     ; bytes actually present
    cmp  rcx, rax
    cmova rcx, rax                    ; clamp truncated / unknown-length files
    lea  rax, [r12 + rsi]
    mov  [rbx + S_BASE], rax
    mov  eax, [rbx + S_FSZ]
    xchg rax, rcx                     ; rax = bytes, rcx = frame size
    xor  edx, edx
    div  rcx
    mov  [rbx + P_TOTAL], rax
    mov  qword [rbx + S_POS], 0
    mov  eax, 1
    RET_
.next:
    mov  eax, ecx
    and  eax, 1                       ; odd-sized chunks carry a pad byte
    add  rsi, rcx
    add  rsi, rax
    mov  r14, rsi
    jmp  .chunk
.fail:
    xor  eax, eax
    RET_

; Common start of both reads: r13 = frames wanted -> frames available, rsi = source of the next frame.
; Returns CF set (and r13 = 0) when nothing is left.
wx_take:
    mov  rax, [rbx + P_TOTAL]
    mov  rcx, [rbx + S_POS]
    sub  rax, rcx
    jbe  .none
    cmp  r13, rax
    cmova r13, rax
    test r13, r13
    jz   .none
    mov  edx, [rbx + S_FSZ]
    imul rdx, rcx
    add  rdx, [rbx + S_BASE]
    mov  rsi, rdx
    add  [rbx + S_POS], r13
    clc
    ret
.none:
    xor  r13d, r13d
    stc
    ret

; size_t read32(peep *p, int32_t *out, size_t frames): native channel count, left-justified
FUNCL wx_read32, 0
    ARGS rbx, r12, r13
    call wx_take
    jc   .z
    mov  ecx, [rbx + P_CH]
    imul rcx, r13
    mov  rdi, r12
    mov  edx, [rbx + S_FMT]
    call wx_conv
.z: mov  rax, r13
    RET_

; size_t read(peep *p, int16_t *out, size_t frames): the top 16 bits of each sample
FUNCL wx_read, 1024
    ARGS rbx, r12, r13
    call wx_take
    jc   .done
    mov  ecx, [rbx + P_CH]
    imul rcx, r13
    mov  r14, rcx                     ; samples left
    mov  r15, rsi
.chunk:
    test r14, r14
    jz   .done
    mov  rcx, r14
    cmp  rcx, 256
    jbe  .c1
    mov  ecx, 256
.c1:sub  r14, rcx
    mov  r11, rcx
    mov  rsi, r15
    lea  rdi, LOC(0)
    mov  edx, [rbx + S_FMT]
    call wx_conv
    mov  r15, rsi
    lea  rsi, LOC(0)
    mov  rcx, r11
.n: mov  eax, [rsi]
    sar  eax, 16
    mov  [r12], ax
    add  rsi, 4
    add  r12, 2
    dec  rcx
    jnz  .n
    jmp  .chunk
.done:
    mov  rax, r13
    RET_

; void seek(peep *p, uint64_t frame)
FUNCL wx_seek, 0
    ARGS rbx, r12
    mov  rax, [rbx + P_TOTAL]
    cmp  r12, rax
    cmova r12, rax
    mov  [rbx + S_POS], r12
    RET_

; const peep_codec *peep_wavx(void): the codec table's address, for languages whose FFI cannot read data symbols
%ifdef WIN64
global peep_wavx
peep_wavx:
    lea  rax, [rel peep_codec_wavx]
    ret
%else
global peep_wavx:function
peep_wavx:
    mov  rax, [rel peep_codec_wavx wrt ..got]
    ret
%endif

; ============================================================================
%ifdef WIN64
section .rdata align=8
%else
section .data.rel.ro progbits alloc noexec write align=8
%endif
global peep_codec_wavx
peep_codec_wavx: dq wx_open, wx_read, wx_seek, 0, wx_read32

%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
