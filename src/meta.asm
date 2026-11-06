; ============================================================================
; Peep — tag reader (player thread only)
;
;   meta_parse(data, len, info)
;       fills INFO_TITLE / INFO_ARTIST (UTF-8) if found and points
;       meta_art_ptr / meta_art_len at the best embedded picture
;       (front cover preferred). Pictures usually point straight into the
;       mapped file; base64 or de-unsynchronised copies live in buffers
;       that meta_done() frees.
;
;   Formats: ID3v2.2/2.3/2.4, ID3v1, FLAC metadata blocks, Ogg Vorbis
;   comments (incl. METADATA_BLOCK_PICTURE / COVERART), WAV LIST-INFO and
;   embedded "id3 " chunks. Every read is bounds-checked against the file.
; ============================================================================
default rel
%include "abi.inc"

extern malloc, free, memcpy, realloc
global meta_parse, meta_done, meta_art_ptr, meta_art_len

NOWN equ 64

section .data
align 8
k_title     db "TITLE"
k_artist    db "ARTIST"
k_mbp       db "METADATA_BLOCK_PICTURE"
k_cover     db "COVERART"

; base64 alphabet -> value, 0xFF = skip
b64tab:
%assign i 0
%rep 256
  %if i >= 'A' && i <= 'Z'
    db i - 'A'
  %elif i >= 'a' && i <= 'z'
    db i - 'a' + 26
  %elif i >= '0' && i <= '9'
    db i - '0' + 52
  %elif i == '+' || i == '-'
    db 62
  %elif i == '/' || i == '_'
    db 63
  %else
    db 0xFF
  %endif
  %assign i i+1
%endrep

section .bss
alignb 8
meta_info     resq 1
meta_art_ptr  resq 1
meta_art_len  resq 1
meta_art_type resd 1
own_n         resd 1
own_ptrs      resq NOWN

section .text

; ---------------------------------------------------------------- helpers
; be32 / syncsafe / le32 as leaf macros: %1 = dest reg32, %2 = address
%macro BE32 2
    mov  %1, [%2]
    bswap %1
%endmacro

%macro SYNCSAFE 2                       ; 4 x 7-bit big-endian
    movzx eax, byte [%2]
    shl  eax, 7
    movzx ecx, byte [%2 + 1]
    or   eax, ecx
    shl  eax, 7
    movzx ecx, byte [%2 + 2]
    or   eax, ecx
    shl  eax, 7
    movzx ecx, byte [%2 + 3]
    or   eax, ecx
    mov  %1, eax
%endmacro

; own_alloc(size) -> rax (freed by meta_done)
FUNC own_alloc, 0
    ARGS rbx
    cmp  dword [own_n], NOWN
    jae  .no
    mov  A1, rbx
    call malloc
    test rax, rax
    jz   .no
    mov  ecx, [own_n]
    lea  rdx, [own_ptrs]
    mov  [rdx + rcx*8], rax
    inc  dword [own_n]
    RET_
.no:xor  eax, eax
    RET_

FUNC meta_done, 0
    xor  ebx, ebx
.l: cmp  ebx, [own_n]
    jae  .d
    lea  rax, [own_ptrs]
    mov  A1, [rax + rbx*8]
    call free
    inc  ebx
    jmp  .l
.d: mov  dword [own_n], 0
    mov  qword [meta_art_ptr], 0
    mov  qword [meta_art_len], 0
    RET_

; consider_pic(type, ptr, len): keep the first picture, but a front cover
; (type 3) beats anything else
FUNC consider_pic, 0
    test A3, A3
    jz   .r
    cmp  qword [meta_art_ptr], 0
    je   .take
    cmp  A1d, 3
    jne  .r
    cmp  dword [meta_art_type], 3
    je   .r
.take:
    mov  [meta_art_type], A1d
    mov  [meta_art_ptr], A2
    mov  [meta_art_len], A3
.r: RET_

; putcp: eax = code point -> UTF-8 at [rdi], rdi advanced. Leaf; clobbers ecx.
putcp:
    cmp  eax, 0x80
    jae  .2
    mov  [rdi], al
    inc  rdi
    ret
.2: cmp  eax, 0x800
    jae  .3
    mov  ecx, eax
    shr  ecx, 6
    or   cl, 0xC0
    mov  [rdi], cl
    and  al, 0x3F
    or   al, 0x80
    mov  [rdi + 1], al
    add  rdi, 2
    ret
.3: cmp  eax, 0x10000
    jae  .4
    mov  ecx, eax
    shr  ecx, 12
    or   cl, 0xE0
    mov  [rdi], cl
    mov  ecx, eax
    shr  ecx, 6
    and  cl, 0x3F
    or   cl, 0x80
    mov  [rdi + 1], cl
    and  al, 0x3F
    or   al, 0x80
    mov  [rdi + 2], al
    add  rdi, 3
    ret
.4: mov  ecx, eax
    shr  ecx, 18
    or   cl, 0xF0
    mov  [rdi], cl
    mov  ecx, eax
    shr  ecx, 12
    and  cl, 0x3F
    or   cl, 0x80
    mov  [rdi + 1], cl
    mov  ecx, eax
    shr  ecx, 6
    and  cl, 0x3F
    or   cl, 0x80
    mov  [rdi + 2], cl
    and  al, 0x3F
    or   al, 0x80
    mov  [rdi + 3], al
    add  rdi, 4
    ret

; set_text(field_offset, src, len, enc)
;   enc 0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8, 4 UTF-16LE
;   Writes only if the field is still empty. Stops at the first NUL.
FUNC set_text, 0
    ARGS r15, rbx, r12, r14
    mov  rdi, [meta_info]
    add  rdi, r15
    cmp  byte [rdi], 0
    jne  .r
    mov  rsi, rdi                     ; field start
    lea  r13, [rdi + 250]             ; leave room for one 4-byte sequence
    add  r12, rbx                     ; src end
    cmp  r14d, 1
    jne  .loop
    mov  r14d, 4
    lea  rax, [rbx + 2]
    cmp  rax, r12
    ja   .loop
    cmp  word [rbx], 0xFEFF           ; bytes FF FE: little endian
    jne  .be
    add  rbx, 2
    jmp  .loop
.be:cmp  word [rbx], 0xFFFE           ; bytes FE FF: big endian
    jne  .loop
    mov  r14d, 2
    add  rbx, 2
.loop:
    cmp  rdi, r13
    jae  .end
    cmp  rbx, r12
    jae  .end
    cmp  r14d, 0
    je   .latin
    cmp  r14d, 3
    je   .utf8
    ; UTF-16
    lea  rax, [rbx + 2]
    cmp  rax, r12
    ja   .end
    movzx eax, word [rbx]
    add  rbx, 2
    cmp  r14d, 2
    jne  .le
    xchg al, ah
.le:test eax, eax
    jz   .end
    cmp  eax, 0xD800
    jb   .put
    cmp  eax, 0xDBFF
    ja   .lone
    lea  rdx, [rbx + 2]
    cmp  rdx, r12
    ja   .lone
    movzx edx, word [rbx]
    cmp  r14d, 2
    jne  .le2
    xchg dl, dh
.le2:
    cmp  edx, 0xDC00
    jb   .lone
    cmp  edx, 0xDFFF
    ja   .lone
    add  rbx, 2
    sub  eax, 0xD800
    shl  eax, 10
    sub  edx, 0xDC00
    add  eax, edx
    add  eax, 0x10000
    jmp  .put
.lone:
    cmp  eax, 0xE000
    jae  .put
    mov  eax, 0xFFFD
.put:
    call putcp
    jmp  .loop
.latin:
    movzx eax, byte [rbx]
    inc  rbx
    test eax, eax
    jz   .end
    call putcp
    jmp  .loop
.utf8:
    mov  al, [rbx]
    inc  rbx
    test al, al
    jz   .end
    mov  [rdi], al
    inc  rdi
    jmp  .loop
.end:                                 ; trim trailing spaces
    cmp  rdi, rsi
    jbe  .z
    cmp  byte [rdi - 1], ' '
    jne  .z
    dec  rdi
    jmp  .end
.z: mov  byte [rdi], 0
.r: RET_

; deunsync(src, len, &newlen) -> rax copy with every FF 00 turned into FF
FUNC deunsync, 0
    ARGS rbx, r12, r13
    mov  A1, r12
    call own_alloc
    test rax, rax
    jz   .fail
    mov  rdi, rax
    mov  r14, rax
    mov  rsi, rbx
    lea  rdx, [rbx + r12]
.l: cmp  rsi, rdx
    jae  .d
    mov  al, [rsi]
    inc  rsi
    mov  [rdi], al
    inc  rdi
    cmp  al, 0xFF
    jne  .l
    cmp  rsi, rdx
    jae  .d
    cmp  byte [rsi], 0
    jne  .l
    inc  rsi
    jmp  .l
.d: sub  rdi, r14
    mov  [r13], rdi
    mov  rax, r14
    RET_
.fail:
    mov  [r13], r12                   ; out of buffers: use as is
    mov  rax, rbx
    RET_

; ---------------------------------------------------------------- ID3v2
; skip_str(p, end, enc) -> rax just past the terminator (or end)
FUNC skip_str, 0
    mov  rax, A1
    cmp  A3d, 1
    je   .w
    cmp  A3d, 2
    je   .w
.b: cmp  rax, A2
    jae  .r
    inc  rax
    cmp  byte [rax - 1], 0
    jne  .b
    RET_
.w: lea  rcx, [rax + 2]
    cmp  rcx, A2
    ja   .end
    mov  rax, rcx
    cmp  word [rax - 2], 0
    jne  .w
    RET_
.end:
    mov  rax, A2
.r: RET_

; id3v2(p, n) -> rax total tag size in bytes (0 if none)
FUNC id3v2, 64
    ARGS rbx, r12
    xor  eax, eax
    mov  [L(0)], rax
    cmp  r12, 10
    jb   .done
    cmp  word [rbx], 'ID'
    jne  .done
    cmp  byte [rbx + 2], '3'
    jne  .done
    movzx r13d, byte [rbx + 3]        ; major version
    cmp  r13d, 2
    jb   .done
    cmp  r13d, 4
    ja   .done
    movzx r14d, byte [rbx + 5]        ; flags
    SYNCSAFE eax, rbx + 6
    lea  rcx, [rax + 10]
    test r14d, 0x10                   ; footer
    jz   .nf
    add  rcx, 10
.nf:mov  [L(0)], rcx
    lea  rcx, [r12 - 10]
    cmp  rax, rcx
    cmova rax, rcx
    mov  [L(8)], rax                  ; body size
    lea  rax, [rbx + 10]
    mov  [L(16)], rax                 ; body
    test r14d, 0x80                   ; whole-tag unsynchronisation (<= 2.3)
    jz   .nu
    cmp  r13d, 4
    je   .nu
    mov  A1, [L(16)]
    mov  A2, [L(8)]
    lea  A3, [L(8)]
    call deunsync
    mov  [L(16)], rax
.nu:test r14d, 0x40                   ; extended header
    jz   .frames
    cmp  r13d, 2
    je   .done                        ; 2.2: compressed tag, unsupported
    mov  rsi, [L(16)]
    cmp  qword [L(8)], 4
    jb   .done
    cmp  r13d, 3
    jne  .x4
    BE32 eax, rsi
    add  rax, 4
    jmp  .xs
.x4:SYNCSAFE eax, rsi
.xs:cmp  rax, [L(8)]
    ja   .done
    add  [L(16)], rax
    sub  [L(8)], rax
.frames:
    mov  r15, [L(16)]                 ; cursor
    mov  rax, r15
    add  rax, [L(8)]
    mov  [L(24)], rax                 ; end
.frame:
    mov  rsi, r15
    cmp  r13d, 2
    jne  .h34
    lea  rax, [rsi + 6]
    cmp  rax, [L(24)]
    ja   .done
    cmp  byte [rsi], 0
    je   .done
    mov  eax, [rsi]
    and  eax, 0xFFFFFF
    mov  [L(32)], eax                 ; id
    movzx eax, byte [rsi + 3]
    shl  eax, 8
    mov  al, [rsi + 4]
    shl  eax, 8
    mov  al, [rsi + 5]
    mov  r14, rax                     ; size
    xor  ecx, ecx
    mov  [L(36)], ecx                 ; format flags
    lea  rdi, [rsi + 6]               ; data
    jmp  .have
.h34:
    lea  rax, [rsi + 10]
    cmp  rax, [L(24)]
    ja   .done
    cmp  byte [rsi], 0
    je   .done
    mov  eax, [rsi]
    mov  [L(32)], eax
    cmp  r13d, 4
    jne  .s3
    SYNCSAFE eax, rsi + 4
    jmp  .s
.s3:BE32 eax, rsi + 4
.s: mov  r14, rax
    movzx eax, byte [rsi + 9]
    mov  [L(36)], eax
    lea  rdi, [rsi + 10]
.have:
    mov  rax, [L(24)]
    sub  rax, rdi
    cmp  r14, rax
    ja   .done
    lea  rax, [rdi + r14]             ; next frame
    mov  [L(40)], rax
    mov  r15, rdi                     ; frame data (rdi is an argument register)
    ; ---- frame format flags
    mov  eax, [L(36)]
    cmp  r13d, 3
    jne  .f4
    test eax, 0xC0                    ; compressed / encrypted
    jnz  .next
    test eax, 0x20                    ; grouping id
    jz   .go
    inc  r15
    dec  r14
    jmp  .go
.f4:cmp  r13d, 4
    jne  .go
    test eax, 0x0C
    jnz  .next
    test eax, 0x40
    jz   .g4
    inc  r15
    dec  r14
.g4:test eax, 0x01                    ; data length indicator
    jz   .u4
    add  r15, 4
    sub  r14, 4
.u4:test eax, 0x02                    ; frame unsynchronisation
    jz   .go
    test r14, r14
    jle  .next
    mov  A1, r15
    mov  A2, r14
    lea  A3, [L(8)]                   ; body size no longer needed
    call deunsync
    mov  r15, rax
    mov  r14, [L(8)]
.go:test r14, r14
    jle  .next
    mov  eax, [L(32)]
    cmp  eax, 'TIT2'
    je   .title
    cmp  eax, 'TT2'
    je   .title
    cmp  eax, 'TPE1'
    je   .artist
    cmp  eax, 'TP1'
    je   .artist
    cmp  eax, 'APIC'
    je   .apic
    cmp  eax, 'PIC'
    je   .pic
    jmp  .next
.title:
    mov  A1, INFO_TITLE
    jmp  .text
.artist:
    mov  A1, INFO_ARTIST
.text:
    lea  A2, [r15 + 1]
    lea  A3, [r14 - 1]
    movzx eax, byte [r15]
    mov  A4, rax
    call set_text
    jmp  .next
.apic:                                ; enc, mime\0, type, desc\0, data
    movzx eax, byte [r15]
    mov  [L(48)], eax
    lea  rsi, [r15 + r14]             ; frame end
    mov  [L(16)], rsi
    lea  A1, [r15 + 1]
    mov  A2, rsi
    xor  A3, A3
    call skip_str
    jmp  .ptype
.pic:                                 ; enc, fmt[3], type, desc\0, data
    movzx eax, byte [r15]
    mov  [L(48)], eax
    lea  rsi, [r15 + r14]
    mov  [L(16)], rsi
    lea  rax, [r15 + 4]
.ptype:
    cmp  rax, [L(16)]
    jae  .next
    movzx ecx, byte [rax]
    mov  [L(32)], ecx                 ; picture type
    lea  A1, [rax + 1]
    mov  A2, [L(16)]
    mov  A3d, [L(48)]
    call skip_str
    mov  r14, [L(16)]
    sub  r14, rax
    jbe  .next
    mov  A2, rax
    mov  A3, r14
    mov  A1d, [L(32)]
    call consider_pic
.next:
    mov  r15, [L(40)]
    jmp  .frame
.done:
    mov  rax, [L(0)]
    RET_

; id3v1(p, n): Latin-1 title/artist from the last 128 bytes
FUNC id3v1, 0
    ARGS rbx, r12
    cmp  r12, 128
    jb   .r
    lea  r13, [rbx + r12 - 128]
    cmp  word [r13], 'TA'
    jne  .r
    cmp  byte [r13 + 2], 'G'
    jne  .r
    mov  A1, INFO_TITLE
    lea  A2, [r13 + 3]
    mov  A3, 30
    xor  A4, A4
    call set_text
    mov  A1, INFO_ARTIST
    lea  A2, [r13 + 33]
    mov  A3, 30
    xor  A4, A4
    call set_text
.r: RET_

; ---------------------------------------------------------------- pictures
; flac_pic(p, n): METADATA_BLOCK_PICTURE layout (big endian)
FUNC flac_pic, 0
    ARGS rbx, r12
    cmp  r12, 32
    jb   .r
    BE32 r13d, rbx                    ; picture type
    mov  r14d, 4
    BE32 eax, rbx + r14               ; mime length
    add  r14, 4
    mov  rcx, r12
    sub  rcx, r14
    cmp  rax, rcx
    ja   .r
    add  r14, rax
    lea  rax, [r14 + 4]
    cmp  rax, r12
    ja   .r
    BE32 eax, rbx + r14               ; description length
    add  r14, 4
    mov  rcx, r12
    sub  rcx, r14
    cmp  rax, rcx
    ja   .r
    add  r14, rax
    lea  rax, [r14 + 20]
    cmp  rax, r12
    ja   .r
    add  r14, 16                      ; width, height, depth, colours
    BE32 eax, rbx + r14               ; data length
    add  r14, 4
    mov  rcx, r12
    sub  rcx, r14
    cmp  rax, rcx
    ja   .r
    mov  A1d, r13d
    lea  A2, [rbx + r14]
    mov  A3, rax
    call consider_pic
.r: RET_

; b64(src, n, &outlen) -> rax decoded buffer (owned) or 0
FUNC b64, 0
    ARGS rbx, r12, r13
    mov  rax, r12
    shr  rax, 2
    lea  A1, [rax*3 + 4]
    call own_alloc
    test rax, rax
    jz   .r
    mov  r14, rax
    mov  rdi, rax
    lea  rsi, [b64tab]
    lea  rdx, [rbx + r12]
    xor  r8d, r8d                     ; bit accumulator
    xor  r9d, r9d                     ; bits held
.l: cmp  rbx, rdx
    jae  .d
    movzx eax, byte [rbx]
    inc  rbx
    cmp  al, '='
    je   .d
    movzx eax, byte [rsi + rax]
    cmp  eax, 0xFF
    je   .l
    shl  r8d, 6
    or   r8d, eax
    add  r9d, 6
    cmp  r9d, 8
    jb   .l
    sub  r9d, 8
    mov  eax, r8d
    mov  ecx, r9d
    shr  eax, cl
    mov  [rdi], al
    inc  rdi
    jmp  .l
.d: sub  rdi, r14
    mov  [r13], rdi
    mov  rax, r14
.r: RET_

; ---------------------------------------------------------------- Vorbis
; keyeq(p, klen, word, wlen) -> eax 1 if equal ignoring ASCII case
FUNC keyeq, 0
    xor  eax, eax
    cmp  A2, A4
    jne  .r
    xor  r10d, r10d
.l: cmp  r10, A2
    jae  .y
    movzx r11d, byte [A1 + r10]
    cmp  r11d, 'a'
    jb   .c
    cmp  r11d, 'z'
    ja   .c
    sub  r11d, 32
.c: cmp  r11b, [A3 + r10]
    jne  .r
    inc  r10
    jmp  .l
.y: mov  eax, 1
.r: RET_

; comment(p, n): one "KEY=value" entry
FUNC comment, 16
    ARGS rbx, r12
    xor  r13d, r13d                   ; '=' position
.f: cmp  r13, r12
    jae  .r
    cmp  byte [rbx + r13], '='
    je   .got
    inc  r13
    jmp  .f
.got:
    lea  r14, [rbx + r13 + 1]         ; value
    mov  r15, r12
    sub  r15, r13
    dec  r15                          ; value length
%macro KEY 3                          ; label, key, keylen
    mov  A1, rbx
    mov  A2, r13
    lea  A3, [%2]
    mov  A4, %3
    call keyeq
    test eax, eax
    jnz  %1
%endmacro
    KEY  .title, k_title, 5
    KEY  .artist, k_artist, 6
    KEY  .mbp, k_mbp, 22
    KEY  .cover, k_cover, 8
    RET_
.title:
    mov  A1, INFO_TITLE
    jmp  .txt
.artist:
    mov  A1, INFO_ARTIST
.txt:
    mov  A2, r14
    mov  A3, r15
    mov  A4, 3
    call set_text
    RET_
.mbp:
    mov  A1, r14
    mov  A2, r15
    lea  A3, [L(0)]
    call b64
    test rax, rax
    jz   .r
    mov  A1, rax
    mov  A2, [L(0)]
    call flac_pic
    RET_
.cover:
    mov  A1, r14
    mov  A2, r15
    lea  A3, [L(0)]
    call b64
    test rax, rax
    jz   .r
    mov  A1, 3
    mov  A2, rax
    mov  A3, [L(0)]
    call consider_pic
.r: RET_

; vcomments(p, n): vendor string, count, entries (little endian lengths)
FUNC vcomments, 0
    ARGS rbx, r12
    cmp  r12, 8
    jb   .r
    mov  eax, [rbx]
    lea  r13, [rax + 4]
    lea  rax, [r13 + 4]
    cmp  rax, r12
    ja   .r
    mov  r14d, [rbx + r13]            ; count
    add  r13, 4
.l: test r14d, r14d
    jz   .r
    dec  r14d
    lea  rax, [r13 + 4]
    cmp  rax, r12
    ja   .r
    mov  r15d, [rbx + r13]
    add  r13, 4
    mov  rax, r12
    sub  rax, r13
    cmp  r15, rax
    ja   .r
    lea  A1, [rbx + r13]
    mov  A2, r15
    call comment
    add  r13, r15
    jmp  .l
.r: RET_

; flac(p, n): metadata blocks after "fLaC"
FUNC flac, 0
    ARGS rbx, r12
    mov  r13d, 4
.l: lea  rax, [r13 + 4]
    cmp  rax, r12
    ja   .r
    movzx r15d, byte [rbx + r13]      ; last flag | type
    movzx eax, byte [rbx + r13 + 1]
    shl  eax, 8
    mov  al, [rbx + r13 + 2]
    shl  eax, 8
    mov  al, [rbx + r13 + 3]
    mov  r14, rax                     ; block length
    add  r13, 4
    mov  rax, r12
    sub  rax, r13
    cmp  r14, rax
    ja   .r
    mov  eax, r15d
    and  eax, 0x7F
    cmp  eax, 4
    jne  .p
    lea  A1, [rbx + r13]
    mov  A2, r14
    call vcomments
    jmp  .n
.p: cmp  eax, 6
    jne  .n
    lea  A1, [rbx + r13]
    mov  A2, r14
    call flac_pic
.n: add  r13, r14
    test r15d, 0x80
    jz   .l
.r: RET_

; ogg(p, n): reassemble packet #1 (the comment header) across pages
FUNC ogg, 48
    ARGS rbx, r12
    xor  r13d, r13d                   ; page cursor
    xor  r14d, r14d                   ; packet index
    mov  qword [L(0)], 0              ; buffer
    mov  qword [L(8)], 0              ; length
.page:
    lea  rax, [r13 + 27]
    cmp  rax, r12
    ja   .eof
    cmp  dword [rbx + r13], 'OggS'
    jne  .eof
    movzx r15d, byte [rbx + r13 + 26] ; segments
    lea  rsi, [r13 + 27]              ; segment table
    lea  rdi, [rsi + r15]             ; data cursor
    cmp  rdi, r12
    ja   .eof
.seg:
    test r15d, r15d
    jz   .pagedone
    dec  r15d
    movzx ecx, byte [rbx + rsi]
    inc  rsi
    lea  rax, [rdi + rcx]
    cmp  rax, r12
    ja   .eof
    cmp  r14d, 1
    jne  .skip
    ; append to the comment packet buffer (C calls clobber rsi/rdi/rcx)
    mov  [L(16)], rsi
    mov  [L(24)], rdi
    mov  [L(32)], rcx
    mov  rax, [L(8)]
    add  rax, rcx
    cmp  rax, 1 << 25                 ; 32 MB is plenty
    ja   .eof
    lea  A2, [rax + 1]
    mov  A1, [L(0)]
    call realloc
    test rax, rax
    jz   .eof
    mov  [L(0)], rax
    mov  A1, rax
    add  A1, [L(8)]
    mov  rax, [L(24)]
    lea  A2, [rbx + rax]
    mov  A3, [L(32)]
    call memcpy
    mov  rsi, [L(16)]
    mov  rdi, [L(24)]
    mov  rcx, [L(32)]
    add  [L(8)], rcx
.skip:
    add  rdi, rcx
    cmp  ecx, 255
    je   .seg
    inc  r14d                         ; packet finished
    cmp  r14d, 2
    jae  .eof
    jmp  .seg
.pagedone:
    mov  r13, rdi
    jmp  .page
.eof:
    mov  rsi, [L(0)]
    test rsi, rsi
    jz   .r
    cmp  qword [L(8)], 7
    jb   .free
    cmp  byte [rsi], 3
    jne  .free
    cmp  dword [rsi + 1], 'vorb'
    jne  .free
    lea  A1, [rsi + 7]
    mov  A2, [L(8)]
    sub  A2, 7
    call vcomments
.free:
    ; keep it alive until meta_done: pictures may point inside
    cmp  dword [own_n], NOWN
    jae  .drop
    mov  ecx, [own_n]
    lea  rdx, [own_ptrs]
    mov  rax, [L(0)]
    mov  [rdx + rcx*8], rax
    inc  dword [own_n]
    RET_
.drop:
    mov  A1, [L(0)]
    call free
.r: RET_

; riff(p, n): WAV LIST/INFO and embedded ID3
FUNC riff, 0
    ARGS rbx, r12
    mov  r13d, 12
.l: lea  rax, [r13 + 8]
    cmp  rax, r12
    ja   .r
    mov  r14d, [rbx + r13 + 4]        ; chunk size
    lea  r15, [r13 + 8]               ; body
    mov  rax, r12
    sub  rax, r15
    cmp  r14, rax
    cmova r14, rax
    mov  eax, [rbx + r13]
    cmp  eax, 'id3 '
    je   .id3
    cmp  eax, 'ID3 '
    je   .id3
    cmp  eax, 'LIST'
    jne  .n
    cmp  r14, 4
    jb   .n
    cmp  dword [rbx + r15], 'INFO'
    jne  .n
    lea  A1, [rbx + r15 + 4]
    lea  A2, [r14 - 4]
    call riff_info
    jmp  .n
.id3:
    lea  A1, [rbx + r15]
    mov  A2, r14
    call id3v2
.n: mov  eax, r14d
    and  eax, 1
    add  r14, rax
    lea  r13, [r15 + r14]
    jmp  .l
.r: RET_

FUNC riff_info, 0
    ARGS rbx, r12
    xor  r13d, r13d
.l: lea  rax, [r13 + 8]
    cmp  rax, r12
    ja   .r
    mov  r14d, [rbx + r13 + 4]
    lea  r15, [r13 + 8]
    mov  rax, r12
    sub  rax, r15
    cmp  r14, rax
    cmova r14, rax
    mov  eax, [rbx + r13]
    cmp  eax, 'INAM'
    jne  .a
    mov  A1, INFO_TITLE
    jmp  .t
.a: cmp  eax, 'IART'
    jne  .n
    mov  A1, INFO_ARTIST
.t: lea  A2, [rbx + r15]
    mov  A3, r14
    mov  A4, 3
    call set_text
.n: mov  eax, r14d
    and  eax, 1
    add  r14, rax
    lea  r13, [r15 + r14]
    jmp  .l
.r: RET_

; ---------------------------------------------------------------- entry
FUNC meta_parse, 0
    ARGS rbx, r12, r13
    mov  [meta_info], r13
    mov  qword [meta_art_ptr], 0
    mov  qword [meta_art_len], 0
    mov  dword [meta_art_type], -1
    cmp  r12, 12
    jb   .r
    mov  A1, rbx
    mov  A2, r12
    call id3v2
    cmp  rax, r12
    cmova rax, r12
    mov  r14, rax                     ; offset past an ID3v2 tag
    lea  rax, [r14 + 4]
    cmp  rax, r12
    ja   .other
    cmp  dword [rbx + r14], 'fLaC'
    jne  .other
    lea  A1, [rbx + r14]
    mov  A2, r12
    sub  A2, r14
    call flac
    jmp  .v1
.other:
    cmp  dword [rbx], 'OggS'
    jne  .wav
    mov  A1, rbx
    mov  A2, r12
    call ogg
    jmp  .v1
.wav:
    cmp  dword [rbx], 'RIFF'
    jne  .v1
    cmp  dword [rbx + 8], 'WAVE'
    jne  .v1
    mov  A1, rbx
    mov  A2, r12
    call riff
.v1:
    mov  A1, rbx
    mov  A2, r12
    call id3v1
.r: RET_

%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
