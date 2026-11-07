; Liberated Peep FLAC codec: a native assembly FLAC decoder behind the peep_codec interface.
;
;   * freestanding: no libc, no malloc, no syscalls, no writable globals
;   * workspace lent by the host: channels * max_blocksize * 4 + 16 bytes (16 of them in front of the first plane)
;   * 4..24 bits per sample, 1..8 channels, fixed and variable block sizes,
;     constant/verbatim/fixed/LPC subframes, every Rice mode, all stereo modes
;   * seeking by binary search over frame headers (CRC-8 checked), no seek table needed
;   * damaged data is skipped: the decoder resynchronises on the next valid frame header
;
; Register convention inside this file (private; the exported entry points are
; ordinary C-ABI functions that set it up):
;   rbx = peep *            r12 = read pointer into the file
;   r13 = bit cache (MSB first, left aligned)   r14 = valid bits in the cache
;   r15 = end of file
; br_get/br_refill clobber only rax, rcx, rdx. Locals live at [rbp - 576 + L_*].

default rel
%include "abi.inc"

; struct peep
P_SRC    equ 8
P_LEN    equ 16
P_TOTAL  equ 32
P_RATE   equ 40
P_CH     equ 44
P_WORK   equ 128
P_WSIZE  equ 136
P_WNEED  equ 144

; FLAC state inside peep.state[] (offsets from the start of struct peep)
S_NEXT   equ 72                   ; u64 offset of the next frame
S_START  equ 80                   ; u64 offset of the first frame
S_BLKLEN equ 88                   ; u32 samples in the decoded block
S_BLKPOS equ 92                   ; u32 next sample to hand out
S_MAXBLK equ 96                   ; u32 STREAMINFO max block size = plane stride
S_BLK0   equ 100                  ; u32 STREAMINFO min block size (fixed-size streams)
S_BPS    equ 104                  ; u32 bits per sample of the decoded block
S_SIBPS  equ 108                  ; u32 STREAMINFO bits per sample
S_SPOS   equ 112                  ; u64 first sample number of the decoded block
S_PLANE0 equ 120                  ; u64 address of plane 0 (work + 16)

FLOC     equ 512
%define LOC(o) [rbp - 576 + (o)]

L_COEF   equ 0                    ; 32 x int64, reversed (oldest sample first)
L_BS     equ 256
L_CA     equ 260
L_BPS    equ 264
L_ORDER  equ 268
L_SHIFT  equ 272
L_WASTED equ 276
L_WIDTH  equ 280
L_PRECIS equ 284
L_NUM    equ 288
L_HSTART equ 296
L_START  equ 304
L_PLANE  equ 312
L_OUT    equ 320
L_FRAMES equ 328
L_GOT    equ 336
L_CH     equ 344
L_CHIDX  equ 348
L_VARBS  equ 352
L_PSIZE  equ 356
L_PBITS  equ 360
L_NPART  equ 364
L_LS     equ 368
L_RS     equ 372
L_SPOS   equ 376
L_SLIM   equ 384
L_LO     equ 392
L_HI     equ 400
L_TGT    equ 408
L_MID    equ 416
L_FIX    equ 424                  ; order of a fixed predictor, 0 for LPC

section .text

fixtab: dd 1, -1, 2, 1, -3, 3, -1, 4, -6, 4     ; fixed predictors 1..4, oldest first

; ============================================================================
; Bit reader
; ============================================================================
br_init:                          ; r8 = byte offset
    mov  r12, [rbx + P_SRC]
    mov  r15, r12
    add  r15, [rbx + P_LEN]
    add  r12, r8
    xor  r13d, r13d
    xor  r14d, r14d
    ret

; Top up the cache by 32 bits (call only with r14d < 32). Past the end of the
; file it supplies zero bits; callers detect that with CHECK_OVERRUN.
br_refill:
    lea  rax, [r12 + 4]
    cmp  rax, r15
    ja   .slow
    mov  eax, [r12]
    bswap eax
.add:
    mov  ecx, 32
    sub  ecx, r14d
    shl  rax, cl
    or   r13, rax
    add  r14d, 32
    add  r12, 4
    ret
.slow:
    xor  eax, eax
    mov  rdx, r12
    mov  ecx, 4
.sl:shl  eax, 8
    cmp  rdx, r15
    jae  .z
    mov  al, [rdx]
.z: inc  rdx
    dec  ecx
    jnz  .sl
    jmp  .add

br_get:                           ; ecx = n (0..32) -> rax
    test ecx, ecx
    jz   .zero
    cmp  r14d, ecx
    jae  .have
    push rcx
    call br_refill
    pop  rcx
.have:
    mov  edx, ecx
    mov  rax, r13
    mov  ecx, 64
    sub  ecx, edx
    shr  rax, cl
    mov  ecx, edx
    shl  r13, cl
    sub  r14d, edx
    ret
.zero:
    xor  eax, eax
    ret

br_gets:                          ; ecx = n (0..32) -> rax, sign extended
    push rcx
    call br_get
    pop  rcx
    test ecx, ecx
    jz   .r
    neg  ecx
    add  ecx, 64
    shl  rax, cl
    sar  rax, cl
.r: ret

; jump to %1 if more bits were consumed than the file holds
%macro CHECK_OVERRUN 1
    mov  rax, r12
    shl  rax, 3
    sub  rax, r14
    mov  rdx, r15
    shl  rdx, 3
    cmp  rax, rdx
    ja   %1
%endmacro

; crc8: rsi = bytes, rcx = count -> eax. Clobbers rcx, rdx, rsi.
crc8:
    xor  eax, eax
.l: test rcx, rcx
    jz   .d
    xor  al, [rsi]
    mov  edx, 8
.b: add  al, al
    jnc  .n
    xor  al, 7
.n: dec  edx
    jnz  .b
    inc  rsi
    dec  rcx
    jmp  .l
.d: movzx eax, al
    ret

; ============================================================================
; Frame header: leaves block size, channel assignment, bits per sample and the
; first sample number in locals. eax = 1 ok, 0 not a valid header.
; ============================================================================
parse_header:
    mov  rax, r12
    sub  rax, [rbx + P_SRC]
    shl  rax, 3
    sub  rax, r14
    shr  rax, 3
    mov  LOC(L_HSTART), rax
    mov  ecx, 14
    call br_get
    cmp  eax, 0x3FFE
    jne  .bad
    mov  ecx, 1
    call br_get                       ; reserved
    test eax, eax
    jnz  .bad
    mov  ecx, 1
    call br_get                       ; blocking strategy: 0 fixed, 1 variable
    mov  LOC(L_VARBS), eax
    mov  ecx, 4
    call br_get
    mov  r8d, eax                     ; block size code
    mov  ecx, 4
    call br_get
    mov  r9d, eax                     ; sample rate code
    mov  ecx, 4
    call br_get
    mov  r10d, eax                    ; channel assignment
    cmp  eax, 10
    ja   .bad
    mov  LOC(L_CA), eax
    mov  ecx, 3
    call br_get
    mov  r11d, eax                    ; sample size code
    mov  ecx, 1
    call br_get
    test eax, eax
    jnz  .bad
    mov  eax, [rbx + S_SIBPS]
    test r11d, r11d
    jz   .bpsok
    mov  eax, 8
    cmp  r11d, 1
    je   .bpsok
    mov  eax, 12
    cmp  r11d, 2
    je   .bpsok
    mov  eax, 16
    cmp  r11d, 4
    je   .bpsok
    mov  eax, 20
    cmp  r11d, 5
    je   .bpsok
    mov  eax, 24
    cmp  r11d, 6
    jne  .bad
.bpsok:
    mov  LOC(L_BPS), eax
    ; ---- UTF-8 coded frame / sample number --------------------------------
    mov  ecx, 8
    call br_get
    mov  esi, eax
    cmp  eax, 0x80
    jb   .num
    cmp  eax, 0xC0
    jb   .bad
    cmp  eax, 0xFF
    je   .bad
    mov  edi, 1                       ; continuation bytes
    mov  ecx, 0x20
.lz:test eax, ecx
    jz   .lzd
    inc  edi
    shr  ecx, 1
    jmp  .lz
.lzd:
    mov  ecx, 6
    sub  ecx, edi
    mov  eax, 1
    shl  eax, cl
    dec  eax
    and  esi, eax                     ; payload bits of the first byte
.ub:mov  ecx, 8
    call br_get
    mov  edx, eax
    and  edx, 0xC0
    cmp  edx, 0x80
    jne  .bad
    and  eax, 0x3F
    shl  rsi, 6
    or   rsi, rax
    dec  edi
    jnz  .ub
.num:
    mov  LOC(L_NUM), rsi
    ; ---- block size ----------------------------------------------------------
    test r8d, r8d
    jz   .bad
    cmp  r8d, 1
    jne  .b2
    mov  eax, 192
    jmp  .bs
.b2:cmp  r8d, 5
    ja   .b6
    lea  ecx, [r8 - 2]
    mov  eax, 576
    shl  eax, cl
    jmp  .bs
.b6:cmp  r8d, 6
    jne  .b7
    mov  ecx, 8
    call br_get
    inc  eax
    jmp  .bs
.b7:cmp  r8d, 7
    jne  .b8
    mov  ecx, 16
    call br_get
    inc  eax
    jmp  .bs
.b8:lea  ecx, [r8 - 8]
    mov  eax, 256
    shl  eax, cl
.bs:cmp  eax, [rbx + S_MAXBLK]
    ja   .bad
    mov  LOC(L_BS), eax
    ; ---- explicit sample rate (skipped) --------------------------------------
    cmp  r9d, 15
    je   .bad
    cmp  r9d, 12
    jb   .rd
    mov  ecx, 8
    je   .rg
    mov  ecx, 16
.rg:call br_get
.rd:
    ; ---- header CRC-8 ---------------------------------------------------------
    mov  rax, r12
    sub  rax, [rbx + P_SRC]
    shl  rax, 3
    sub  rax, r14
    shr  rax, 3                       ; offset of the CRC byte
    cmp  rax, [rbx + P_LEN]
    jae  .bad
    mov  rcx, rax
    sub  rcx, LOC(L_HSTART)
    mov  rsi, [rbx + P_SRC]
    add  rsi, LOC(L_HSTART)
    call crc8
    mov  r11d, eax
    mov  ecx, 8
    call br_get
    cmp  eax, r11d
    jne  .bad
    ; ---- channels must match STREAMINFO ------------------------------------
    mov  eax, LOC(L_CA)
    cmp  eax, 8
    jb   .ind
    mov  eax, 1
.ind:
    inc  eax
    cmp  eax, [rbx + P_CH]
    jne  .bad
    ; ---- first sample of this frame ----------------------------------------
    mov  rax, LOC(L_NUM)
    cmp  dword LOC(L_VARBS), 0
    jne  .var
    mov  ecx, [rbx + S_BLK0]
    imul rax, rcx
.var:
    mov  LOC(L_START), rax
    mov  eax, 1
    ret
.bad:
    xor  eax, eax
    ret

; ff_scan: find the next valid frame header. r8 = first offset to try,
; r9 = headers must start below this. -> eax 1 and r8 = offset, or 0.
ff_scan:
    mov  rax, [rbx + P_LEN]
    cmp  r9, rax
    cmova r9, rax
    mov  LOC(L_SLIM), r9
    mov  LOC(L_SPOS), r8
    mov  rsi, [rbx + P_SRC]
.f: cmp  r8, LOC(L_SLIM)
    jae  .fail
    lea  rax, [r8 + 1]
    cmp  rax, [rbx + P_LEN]
    jae  .fail
    cmp  byte [rsi + r8], 0xFF
    jne  .adv
    movzx eax, byte [rsi + r8 + 1]
    and  eax, 0xFE
    cmp  eax, 0xF8
    je   .cand
.adv:
    inc  r8
    jmp  .f
.cand:
    mov  LOC(L_SPOS), r8
    call br_init
    call parse_header
    mov  r8, LOC(L_SPOS)
    test eax, eax
    jnz  .ok
    inc  r8
    mov  LOC(L_SPOS), r8
    mov  rsi, [rbx + P_SRC]
    jmp  .f
.ok:mov  eax, 1
    ret
.fail:
    xor  eax, eax
    ret

; ============================================================================
; Residual: Rice-coded, writes plane[order .. blocksize). Hot loop.
; ============================================================================
decode_residual:
    mov  ecx, 2
    call br_get
    cmp  eax, 1
    ja   .bad
    lea  eax, [rax + 4]
    mov  LOC(L_PBITS), eax            ; 4 or 5 bit Rice parameters
    mov  ecx, 4
    call br_get
    mov  ecx, eax                     ; partition order
    mov  r11d, 1
    shl  r11d, cl
    mov  LOC(L_NPART), r11d
    mov  r10d, LOC(L_BS)
    lea  eax, [r11 - 1]
    test eax, r10d                    ; block size must divide into the partitions
    jnz  .bad
    mov  eax, r10d
    shr  eax, cl
    mov  LOC(L_PSIZE), eax
    mov  r9d, eax
    sub  r9d, LOC(L_ORDER)            ; first partition holds order fewer samples
    jb   .bad
    mov  rdi, LOC(L_PLANE)
    mov  eax, LOC(L_ORDER)
    lea  rdi, [rdi + rax * 4]
.part:
    mov  ecx, LOC(L_PBITS)
    call br_get
    mov  r10d, eax                    ; Rice parameter k, or the escape code
    mov  ecx, LOC(L_PBITS)
    mov  edx, 1
    shl  edx, cl
    dec  edx
    cmp  r10d, edx
    je   .escape
    test r9d, r9d
    jz   .pdone
.rs:cmp  r14d, 32
    jb   .rf1
.c1:bsr  rax, r13                     ; unary part: leading zero bits
    jz   .long
    xor  eax, 63                      ; q
    lea  edx, [rax + r10 + 1]         ; t = q + 1 + k bits for this sample
    cmp  edx, r14d
    ja   .more                        ; not all in the cache: slow path
    mov  r8, r13                      ; value, computed from the old cache:
    mov  ecx, 64                      ;   V = top t bits = (1 << k) | low
    sub  ecx, edx
    shr  r8, cl
    lea  r11, [rax - 1]               ;   u = V + ((q - 1) << k)
    mov  ecx, r10d
    shl  r11, cl
    add  r8, r11
    mov  ecx, edx                     ; the only loop-carried work: drop t bits
    shl  r13, cl
    sub  r14d, edx
.zz:mov  rax, r8
    shr  rax, 1
    and  r8d, 1
    neg  r8
    xor  rax, r8                      ; zig-zag: (u >> 1) ^ -(u & 1)
    mov  [rdi], eax
    add  rdi, 4
    dec  r9d
    jnz  .rs
    jmp  .pdone
.more:                                ; eax = q: consume the unary part, then top up for the rest
    mov  r8d, eax
    mov  ecx, eax
    shl  r13, cl
    shl  r13, 1
    inc  ecx
    sub  r14d, ecx
.kc:cmp  r14d, r10d
    jb   .rf2
.c2:mov  rax, r13
    shr  rax, 1
    mov  ecx, 63
    sub  ecx, r10d
    shr  rax, cl                      ; k low bits
    mov  ecx, r10d
    shl  r13, cl
    sub  r14d, r10d
    shl  r8, cl
    or   r8, rax                      ; u = q << k | low
    jmp  .zz
.rf1:
    call br_refill
    jmp  .c1
.rf2:
    call br_refill
    jmp  .c2
.long:                                ; the cache holds only zeros: keep counting
    mov  r8, r14
    xor  r13d, r13d
    xor  r14d, r14d
.lg:lea  rax, [r15 + 16]
    cmp  r12, rax
    ja   .bad                         ; ran far past the end of the file
    call br_refill
    bsr  rax, r13
    jnz  .lgf
    add  r8, r14
    xor  r13d, r13d
    xor  r14d, r14d
    jmp  .lg
.lgf:
    mov  ecx, 63
    sub  ecx, eax
    add  r8, rcx
    shl  r13, cl
    shl  r13, 1
    inc  ecx
    sub  r14d, ecx
    jmp  .kc
.escape:                              ; partition stored as n-bit signed integers
    mov  ecx, 5
    call br_get
    mov  r8d, eax
    test r9d, r9d
    jz   .pdone
    test r8d, r8d
    jnz  .eraw
    xor  eax, eax
    mov  ecx, r9d
    rep  stosd
    jmp  .pdone
.eraw:
    mov  ecx, r8d
    call br_gets
    mov  [rdi], eax
    add  rdi, 4
    dec  r9d
    jnz  .eraw
.pdone:
    mov  r9d, LOC(L_PSIZE)
    dec  dword LOC(L_NPART)
    jnz  .part
    mov  eax, 1
    ret
.bad:
    xor  eax, eax
    ret

; ============================================================================
; LPC / fixed prediction, in place. 64-bit accumulator, so any precision and
; any sample width is exact.
; ============================================================================
predict:
    mov  r8d, LOC(L_ORDER)
    test r8d, r8d
    jz   .done
    mov  r9d, LOC(L_BS)
    sub  r9d, r8d
    jbe  .done
    mov  eax, LOC(L_FIX)
    test eax, eax
    jnz  .fixed
    lea  rdi, LOC(L_COEF)
    lea  eax, [r8 + 3]
    and  eax, -4                      ; P = order rounded up to a multiple of 4
    mov  edx, eax
    sub  edx, r8d                     ; d zero coefficients go on the OLD side
    jz   .padded
    mov  ecx, r8d
.mv:dec  ecx
    mov  r10, [rdi + rcx * 8]
    lea  r11d, [rcx + rdx]
    mov  [rdi + r11 * 8], r10
    test ecx, ecx
    jnz  .mv
.zp:mov  qword [rdi + rcx * 8], 0
    inc  ecx
    cmp  ecx, edx
    jb   .zp
.padded:
    mov  r11, LOC(L_PLANE)
    lea  rsi, [r11 + r8 * 4]          ; output: x[i], first predicted sample
    shl  rdx, 2
    sub  r11, rdx                     ; window start x[order - P] (up to 3 slots of front slack)
    movsxd r10, dword [rsi - 4]       ; x[i-1] lives in a register: no store->load round trip
    lea  r8d, [rax - 4]               ; the last 4 window slots are handled outside the loop
.sample:
    xor  eax, eax
    xor  ecx, ecx
    cmp  ecx, r8d
    jae  .tail
.mac:                                 ; 4 multiply-adds per pass, oldest samples first
    movsxd rdx, dword [r11 + rcx * 4]
    imul rdx, [rdi + rcx * 8]
    add  rax, rdx
    movsxd rdx, dword [r11 + rcx * 4 + 4]
    imul rdx, [rdi + rcx * 8 + 8]
    add  rax, rdx
    movsxd rdx, dword [r11 + rcx * 4 + 8]
    imul rdx, [rdi + rcx * 8 + 16]
    add  rax, rdx
    movsxd rdx, dword [r11 + rcx * 4 + 12]
    imul rdx, [rdi + rcx * 8 + 24]
    add  rax, rdx
    add  ecx, 4
    cmp  ecx, r8d
    jb   .mac
.tail:                                ; x[i-4..i-2] from memory, newest term last, from the register
    movsxd rdx, dword [r11 + rcx * 4]
    imul rdx, [rdi + rcx * 8]
    add  rax, rdx
    movsxd rdx, dword [r11 + rcx * 4 + 4]
    imul rdx, [rdi + rcx * 8 + 8]
    add  rax, rdx
    movsxd rdx, dword [r11 + rcx * 4 + 8]
    imul rdx, [rdi + rcx * 8 + 16]
    add  rax, rdx
    mov  rdx, r10
    imul rdx, [rdi + rcx * 8 + 24]
    add  rax, rdx
    mov  ecx, LOC(L_SHIFT)
    sar  rax, cl
    add  eax, [rsi]
    mov  [rsi], eax
    movsxd r10, eax
    add  rsi, 4
    add  r11, 4
    dec  r9d
    jnz  .sample
.done:
    ret
.fixed:                               ; fixed predictors: previous samples in registers, wrap-around int32
    mov  rsi, LOC(L_PLANE)
    lea  rsi, [rsi + r8 * 4]          ; &x[order]
    cmp  eax, 2
    jb   .f1
    je   .f2
    cmp  eax, 3
    je   .f3
    mov  r10d, [rsi - 16]             ; order 4: 4c1 - 6c2 + 4c3 - c4
    mov  r11d, [rsi - 12]
    mov  edx, [rsi - 8]
    mov  ecx, [rsi - 4]
.l4:lea  eax, [rcx + r11]
    shl  eax, 2
    lea  edi, [rdx + rdx * 2]
    add  edi, edi
    sub  eax, edi
    sub  eax, r10d
    add  eax, [rsi]
    mov  [rsi], eax
    mov  r10d, r11d
    mov  r11d, edx
    mov  edx, ecx
    mov  ecx, eax
    add  rsi, 4
    dec  r9d
    jnz  .l4
    ret
.f3:mov  r11d, [rsi - 12]             ; order 3: 3(c1 - c2) + c3
    mov  edx, [rsi - 8]
    mov  ecx, [rsi - 4]
.l3:mov  eax, ecx
    sub  eax, edx
    lea  eax, [rax + rax * 2]
    add  eax, r11d
    add  eax, [rsi]
    mov  [rsi], eax
    mov  r11d, edx
    mov  edx, ecx
    mov  ecx, eax
    add  rsi, 4
    dec  r9d
    jnz  .l3
    ret
.f2:mov  edx, [rsi - 8]               ; order 2: 2c1 - c2
    mov  ecx, [rsi - 4]
.l2:lea  eax, [rcx + rcx]
    sub  eax, edx
    add  eax, [rsi]
    mov  [rsi], eax
    mov  edx, ecx
    mov  ecx, eax
    add  rsi, 4
    dec  r9d
    jnz  .l2
    ret
.f1:mov  ecx, [rsi - 4]               ; order 1: c1
.l1:add  ecx, [rsi]
    mov  [rsi], ecx
    add  rsi, 4
    dec  r9d
    jnz  .l1
    ret

; ============================================================================
; One subframe into plane L_PLANE, width L_WIDTH bits. eax = 1 ok, 0 error.
; ============================================================================
decode_subframe:
    mov  ecx, 1
    call br_get
    test eax, eax
    jnz  .bad
    mov  ecx, 6
    call br_get
    mov  r8d, eax                     ; subframe type
    mov  ecx, 1
    call br_get
    xor  r9d, r9d                     ; wasted bits
    test eax, eax
    jz   .nw
.wl:mov  ecx, 1
    call br_get
    inc  r9d
    cmp  r9d, 32
    ja   .bad
    test eax, eax
    jz   .wl
.nw:mov  LOC(L_WASTED), r9d
    mov  eax, LOC(L_WIDTH)
    sub  eax, r9d
    jbe  .bad
    mov  LOC(L_WIDTH), eax
    mov  rdi, LOC(L_PLANE)
    mov  r10d, LOC(L_BS)
    test r8d, r8d
    jz   .const
    cmp  r8d, 1
    je   .verb
    cmp  r8d, 8
    jb   .bad
    cmp  r8d, 12
    jbe  .fixed
    cmp  r8d, 32
    jb   .bad
    lea  eax, [r8 - 31]               ; LPC order 1..32
    mov  LOC(L_ORDER), eax
    mov  dword LOC(L_FIX), 0
    jmp  .warm
.const:
    mov  ecx, LOC(L_WIDTH)
    call br_gets
    mov  ecx, r10d
    rep  stosd
    jmp  .wasted
.verb:
    mov  ecx, LOC(L_WIDTH)
    call br_gets
    mov  [rdi], eax
    add  rdi, 4
    dec  r10d
    jnz  .verb
    jmp  .wasted
.fixed:
    lea  eax, [r8 - 8]                ; order 0..4
    mov  LOC(L_ORDER), eax
    mov  LOC(L_FIX), eax
    mov  dword LOC(L_SHIFT), 0
    test eax, eax
    jz   .warm
    lea  ecx, [rax - 1]
    imul ecx, eax
    shr  ecx, 1
    lea  rsi, [fixtab]
    lea  rsi, [rsi + rcx * 4]
    lea  rdi, LOC(L_COEF)
    mov  ecx, eax
.fc:movsxd rdx, dword [rsi]
    mov  [rdi], rdx
    add  rsi, 4
    add  rdi, 8
    dec  ecx
    jnz  .fc
.warm:
    mov  eax, LOC(L_ORDER)
    cmp  eax, r10d
    ja   .bad
    mov  r11d, eax
    test r11d, r11d
    jz   .nowarm
    mov  rdi, LOC(L_PLANE)
.wu:mov  ecx, LOC(L_WIDTH)
    call br_gets
    mov  [rdi], eax
    add  rdi, 4
    dec  r11d
    jnz  .wu
.nowarm:
    cmp  r8d, 32
    jb   .resid
    mov  ecx, 4
    call br_get
    cmp  eax, 15
    je   .bad
    inc  eax
    mov  LOC(L_PRECIS), eax
    mov  ecx, 5
    call br_gets
    test eax, eax
    js   .bad
    mov  LOC(L_SHIFT), eax
    mov  r11d, LOC(L_ORDER)
    lea  rsi, LOC(L_COEF)
.cf:mov  ecx, LOC(L_PRECIS)
    call br_gets
    mov  [rsi + r11 * 8 - 8], rax     ; first coefficient is the newest sample's
    dec  r11d
    jnz  .cf
.resid:
    call decode_residual
    test eax, eax
    jz   .bad
    call predict
.wasted:
    mov  ecx, LOC(L_WASTED)
    test ecx, ecx
    jz   .ok
    mov  rdi, LOC(L_PLANE)
    mov  edx, LOC(L_BS)
.ws:shl  dword [rdi], cl
    add  rdi, 4
    dec  edx
    jnz  .ws
.ok:mov  eax, 1
    ret
.bad:
    xor  eax, eax
    ret

; ============================================================================
; Undo stereo decorrelation on planes 0 and 1
; ============================================================================
stereo_fix:
    mov  eax, LOC(L_CA)
    cmp  eax, 8
    jb   .r
    mov  ecx, LOC(L_BS)
    mov  rsi, [rbx + S_PLANE0]
    mov  edx, [rbx + S_MAXBLK]
    lea  rdi, [rsi + rdx * 4]
    mov  edx, ecx
    and  edx, 3                       ; scalar tail
    shr  ecx, 2                       ; groups of 4 samples
    pcmpeqd xmm3, xmm3
    psrld xmm3, 31                    ; 1 in every lane
    cmp  eax, 8
    je   .ls
    cmp  eax, 9
    je   .sr
.ms:test ecx, ecx                     ; mid / side
    jz   .mt
.m4:movdqu xmm0, [rsi]
    movdqu xmm1, [rdi]
    pslld xmm0, 1
    movdqa xmm2, xmm1
    pand xmm2, xmm3
    por  xmm0, xmm2                   ; mid = (mid << 1) | (side & 1)
    movdqa xmm4, xmm0
    paddd xmm0, xmm1
    psrad xmm0, 1                     ; left  = (mid + side) >> 1
    psubd xmm4, xmm1
    psrad xmm4, 1                     ; right = (mid - side) >> 1
    movdqu [rsi], xmm0
    movdqu [rdi], xmm4
    add  rsi, 16
    add  rdi, 16
    dec  ecx
    jnz  .m4
.mt:test edx, edx
    jz   .r
.m1:mov  eax, [rsi]
    mov  ecx, [rdi]
    add  eax, eax
    mov  r8d, ecx
    and  r8d, 1
    or   eax, r8d
    mov  r9d, eax
    add  eax, ecx
    sar  eax, 1
    sub  r9d, ecx
    sar  r9d, 1
    mov  [rsi], eax
    mov  [rdi], r9d
    add  rsi, 4
    add  rdi, 4
    dec  edx
    jnz  .m1
.r: ret
.ls:test ecx, ecx                     ; left / side: right = left - side
    jz   .lt
.l4:movdqu xmm0, [rsi]
    movdqu xmm1, [rdi]
    psubd xmm0, xmm1
    movdqu [rdi], xmm0
    add  rsi, 16
    add  rdi, 16
    dec  ecx
    jnz  .l4
.lt:test edx, edx
    jz   .r
.l1:mov  eax, [rsi]
    sub  eax, [rdi]
    mov  [rdi], eax
    add  rsi, 4
    add  rdi, 4
    dec  edx
    jnz  .l1
    ret
.sr:test ecx, ecx                     ; side / right: left = side + right
    jz   .st
.s4:movdqu xmm0, [rsi]
    movdqu xmm1, [rdi]
    paddd xmm0, xmm1
    movdqu [rsi], xmm0
    add  rsi, 16
    add  rdi, 16
    dec  ecx
    jnz  .s4
.st:test edx, edx
    jz   .r
.s1:mov  eax, [rsi]
    add  eax, [rdi]
    mov  [rsi], eax
    add  rsi, 4
    add  rdi, 4
    dec  edx
    jnz  .s1
    ret

; ============================================================================
; Body of a frame whose header was just parsed. eax = 1 ok, 0 error.
; ============================================================================
decode_body:
    mov  eax, [rbx + P_CH]
    mov  LOC(L_CH), eax
    mov  dword LOC(L_CHIDX), 0
.chan:
    mov  eax, LOC(L_CHIDX)
    mov  ecx, [rbx + S_MAXBLK]
    imul rax, rcx
    shl  rax, 2
    add  rax, [rbx + S_PLANE0]
    mov  LOC(L_PLANE), rax
    mov  eax, LOC(L_BPS)
    mov  ecx, LOC(L_CA)
    mov  edx, LOC(L_CHIDX)
    cmp  ecx, 8                       ; the side channel carries one extra bit
    jne  .n8
    cmp  edx, 1
    jne  .wd
    inc  eax
    jmp  .wd
.n8:cmp  ecx, 9
    jne  .n9
    test edx, edx
    jnz  .wd
    inc  eax
    jmp  .wd
.n9:cmp  ecx, 10
    jne  .wd
    cmp  edx, 1
    jne  .wd
    inc  eax
.wd:mov  LOC(L_WIDTH), eax
    call decode_subframe
    test eax, eax
    jz   .fail
    CHECK_OVERRUN .fail
    inc  dword LOC(L_CHIDX)
    mov  eax, LOC(L_CHIDX)
    cmp  eax, LOC(L_CH)
    jb   .chan
    mov  ecx, r14d                    ; pad to a byte, then skip the CRC-16
    and  ecx, 7
    call br_get
    mov  ecx, 16
    call br_get
    CHECK_OVERRUN .fail
    mov  rax, r12
    sub  rax, [rbx + P_SRC]
    shl  rax, 3
    sub  rax, r14
    shr  rax, 3
    mov  [rbx + S_NEXT], rax
    call stereo_fix
    mov  eax, LOC(L_BS)
    mov  [rbx + S_BLKLEN], eax
    mov  dword [rbx + S_BLKPOS], 0
    mov  eax, LOC(L_BPS)
    mov  [rbx + S_BPS], eax
    mov  rax, LOC(L_START)
    mov  [rbx + S_SPOS], rax
    mov  eax, 1
    ret
.fail:
    xor  eax, eax
    ret

; decode_next: decode the frame at S_NEXT, resynchronising over damage.
; eax = 1 a block is ready, 0 end of stream.
decode_next:
.retry:
    mov  r8, [rbx + S_NEXT]
    cmp  r8, [rbx + P_LEN]
    jae  .eof
    call br_init
    call parse_header
    test eax, eax
    jnz  .body
.resync:
    mov  r8, [rbx + S_NEXT]
    inc  r8
    mov  r9, [rbx + P_LEN]
    call ff_scan
    test eax, eax
    jz   .eof
    mov  [rbx + S_NEXT], r8
    jmp  .retry
.body:
    call decode_body
    test eax, eax
    jz   .resync
    ret
.eof:
    mov  rax, [rbx + P_LEN]
    mov  [rbx + S_NEXT], rax
    mov  dword [rbx + S_BLKLEN], 0
    mov  dword [rbx + S_BLKPOS], 0
    xor  eax, eax
    ret

; ============================================================================
; Exported (through peep_codec_flac)
; ============================================================================

; int open(peep *p, const void *data, size_t len)
FUNCL flac_open, FLOC
    ARGS rbx, r12, r13
    cmp  r13, 42
    jb   .fail
    cmp  dword [r12], 'fLaC'
    jne  .fail
    test byte [r12 + 4], 0x7F         ; first block must be STREAMINFO
    jnz  .fail
    mov  eax, [r12 + 4]
    bswap eax
    and  eax, 0xFFFFFF
    cmp  eax, 34
    jb   .fail
    mov  eax, [r12 + 8]
    bswap eax
    mov  edx, eax
    shr  edx, 16                      ; min block size
    movzx eax, ax                     ; max block size
    test edx, edx
    jz   .fail
    test eax, eax
    jz   .fail
    mov  [rbx + S_BLK0], edx
    mov  [rbx + S_MAXBLK], eax
    mov  rax, [r12 + 18]
    bswap rax                         ; rate:20 channels-1:3 bps-1:5 samples:36
    mov  rcx, rax
    shr  rcx, 44
    jz   .fail
    mov  [rbx + P_RATE], ecx
    mov  rcx, rax
    shr  rcx, 41
    and  ecx, 7
    inc  ecx
    mov  [rbx + P_CH], ecx
    mov  rcx, rax
    shr  rcx, 36
    and  ecx, 31
    inc  ecx
    cmp  ecx, 4
    jb   .fail
    cmp  ecx, 24
    ja   .fail
    mov  [rbx + S_SIBPS], ecx
    mov  rcx, 0xFFFFFFFFF
    and  rax, rcx
    mov  [rbx + P_TOTAL], rax
    mov  esi, 4                       ; skip metadata blocks
.mb:lea  rax, [rsi + 4]
    cmp  rax, r13
    ja   .fail
    movzx ecx, byte [r12 + rsi]
    mov  eax, [r12 + rsi]
    bswap eax
    and  eax, 0xFFFFFF
    lea  rsi, [rsi + rax + 4]
    cmp  rsi, r13
    ja   .fail
    test cl, 0x80
    jz   .mb
    mov  eax, [rbx + P_CH]            ; workspace: one plane of int32 per channel
    mov  ecx, [rbx + S_MAXBLK]
    imul rax, rcx
    shl  rax, 2
    add  rax, 16                      ; front slack: predict reads (and ignores) up to 3 slots before plane 0
    mov  [rbx + P_WNEED], rax
    cmp  qword [rbx + P_WORK], 0
    je   .fail
    cmp  [rbx + P_WSIZE], rax
    jb   .fail
    mov  [rbx + S_NEXT], rsi
    mov  [rbx + S_START], rsi
    mov  rax, [rbx + P_WORK]
    add  rax, 16
    mov  [rbx + S_PLANE0], rax
    mov  eax, 1
    RET_
.fail:
    xor  eax, eax
    RET_

; size_t read(peep *p, int16_t *out, size_t frames)
FUNCL flac_read, FLOC
    ARGS rbx, rax, rcx
    mov  LOC(L_OUT), rax
    mov  LOC(L_FRAMES), rcx
    mov  qword LOC(L_GOT), 0
.loop:
    cmp  qword LOC(L_FRAMES), 0
    je   .done
    mov  ecx, [rbx + S_BLKLEN]
    sub  ecx, [rbx + S_BLKPOS]
    jnz  .have
    call decode_next
    test eax, eax
    jnz  .loop
    jmp  .done
.have:
    mov  rax, LOC(L_FRAMES)
    cmp  rcx, rax
    cmova rcx, rax
    call interleave
    jmp  .loop
.done:
    mov  rax, LOC(L_GOT)
    RET_

; interleave: ecx = frames to hand out from the decoded block, to L_OUT.
; Output int16 = (sample << max(0,16-bps)) >> max(0,bps-16).
interleave:
    mov  r8d, ecx
    mov  r10d, [rbx + P_CH]
    mov  eax, [rbx + S_BPS]
    xor  edx, edx
    mov  ecx, 16
    sub  ecx, eax
    cmovs ecx, edx
    mov  LOC(L_LS), ecx
    movd xmm4, ecx
    mov  ecx, eax
    sub  ecx, 16
    cmovs ecx, edx
    mov  LOC(L_RS), ecx
    movd xmm5, ecx
    cmp  r10d, 2
    jne  .gen
    mov  r9d, [rbx + S_BLKPOS]
    mov  rsi, [rbx + S_PLANE0]
    mov  eax, [rbx + S_MAXBLK]
    lea  rdi, [rsi + rax * 4]
    lea  rsi, [rsi + r9 * 4]
    lea  rdi, [rdi + r9 * 4]
    mov  rdx, LOC(L_OUT)
    mov  ecx, r8d
    shr  ecx, 2
    jz   .tail
.v: movdqu xmm0, [rsi]
    movdqu xmm1, [rdi]
    pslld xmm0, xmm4
    psrad xmm0, xmm5
    pslld xmm1, xmm4
    psrad xmm1, xmm5
    packssdw xmm0, xmm0
    packssdw xmm1, xmm1
    punpcklwd xmm0, xmm1
    movdqu [rdx], xmm0
    add  rsi, 16
    add  rdi, 16
    add  rdx, 16
    dec  ecx
    jnz  .v
.tail:
    mov  r9d, r8d
    and  r9d, 3
    jz   .done
.t1:mov  eax, [rsi]
    mov  ecx, LOC(L_LS)
    shl  eax, cl
    mov  ecx, LOC(L_RS)
    sar  eax, cl
    mov  [rdx], ax
    mov  eax, [rdi]
    mov  ecx, LOC(L_LS)
    shl  eax, cl
    mov  ecx, LOC(L_RS)
    sar  eax, cl
    mov  [rdx + 2], ax
    add  rsi, 4
    add  rdi, 4
    add  rdx, 4
    dec  r9d
    jnz  .t1
    jmp  .done
.gen:                                 ; mono and 3..8 channels: one pass per channel
    xor  r11d, r11d
    lea  rdi, [r10 * 2]               ; output bytes per frame
.gc:mov  eax, [rbx + S_MAXBLK]
    imul rax, r11
    mov  ecx, [rbx + S_BLKPOS]
    add  rax, rcx
    mov  rsi, [rbx + S_PLANE0]
    lea  rsi, [rsi + rax * 4]
    mov  rdx, LOC(L_OUT)
    lea  rdx, [rdx + r11 * 2]
    mov  r9d, r8d
.gl:mov  eax, [rsi]
    mov  ecx, LOC(L_LS)
    shl  eax, cl
    mov  ecx, LOC(L_RS)
    sar  eax, cl
    mov  [rdx], ax
    add  rsi, 4
    add  rdx, rdi
    dec  r9d
    jnz  .gl
    inc  r11d
    cmp  r11d, r10d
    jb   .gc
.done:
    mov  eax, r8d
    add  [rbx + S_BLKPOS], eax
    sub  LOC(L_FRAMES), rax
    add  LOC(L_GOT), rax
    imul rax, r10
    shl  rax, 1
    add  LOC(L_OUT), rax
    ret

; void seek(peep *p, uint64_t frame)
FUNCL flac_seek, FLOC
    ARGS rbx, r12
    mov  dword [rbx + S_BLKLEN], 0
    mov  dword [rbx + S_BLKPOS], 0
    mov  rax, [rbx + S_START]
    mov  [rbx + S_NEXT], rax
    test r12, r12
    jz   .r
    mov  LOC(L_TGT), r12
    mov  LOC(L_LO), rax               ; frame at lo starts at or before the target
    mov  rax, [rbx + P_LEN]
    mov  LOC(L_HI), rax
.bs:mov  rax, LOC(L_HI)
    sub  rax, LOC(L_LO)
    cmp  rax, 2
    jb   .found
    shr  rax, 1
    add  rax, LOC(L_LO)
    mov  LOC(L_MID), rax
    mov  r8, rax
    mov  r9, LOC(L_HI)
    call ff_scan
    test eax, eax
    jz   .nf
    mov  rax, LOC(L_START)
    cmp  rax, LOC(L_TGT)
    ja   .gt
    mov  LOC(L_LO), r8
    jmp  .bs
.gt:mov  LOC(L_HI), r8
    jmp  .bs
.nf:mov  rax, LOC(L_MID)
    mov  LOC(L_HI), rax
    jmp  .bs
.found:
    mov  rax, LOC(L_LO)
    mov  [rbx + S_NEXT], rax
    call decode_next
    test eax, eax
    jz   .r
    mov  rax, LOC(L_TGT)
    sub  rax, [rbx + S_SPOS]
    jb   .r
    mov  ecx, [rbx + S_BLKLEN]
    cmp  rax, rcx
    cmova rax, rcx
    mov  [rbx + S_BLKPOS], eax
.r: RET_

; ============================================================================
%ifdef WIN64
section .rdata align=8
%else
section .data.rel.ro progbits alloc noexec write align=8
%endif
global peep_codec_flac
peep_codec_flac: dq flac_open, flac_read, flac_seek, 0

%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
