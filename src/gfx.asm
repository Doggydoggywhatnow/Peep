; ============================================================================
; Peep — graphics (UI thread only)
;
;   * cover art: letterboxed into a cached, window-sized image
;     (box-filter halving for big downscales, then SSE2 bilinear)
;   * Tab overlay: gradient, title / artist / time, progress bar and
;     previous / play-pause / next buttons (clickable)
;   * text: UTF-8, either the built-in 8x8 bitmap font or a TrueType /
;     OpenType font from the fonts folder (F cycles, notice top-left)
;   * window sizing rules: follow the cover's shape and the user's scaling
; ============================================================================
default rel
%include "abi.inc"

extern g_ui, g_blank, g_paused, g_volstep
extern cur_idx, st_count, st_playing, st_rate, st_pos, st_total, cmd_seek
extern pending_info, info_free, core_key
extern core_list_new, core_list_free, core_list_sort
extern plat_ms, plat_map, plat_unmap, plat_title, plat_font_scan, plat_font_dir
extern malloc, free, memcpy
%ifndef PURE
extern font_load, font_free, font_ascent, font_advance, font_kern
extern font_glyph, font_glyph_free
%endif

global core_render, core_click, core_take_info, core_target_size
global core_note_size, core_art_aspect, core_next_wake, gfx_font_cycle
global core_hover, core_tick_needed, gfx_show_version
global core_set_fullscreen, core_motion, core_cursor_hidden

; colours (0x00RRGGBB)
C_TITLE   equ 0x00F2F2F2
C_ARTIST  equ 0x00B4B4B4
C_DIM     equ 0x009A9A9A
C_ICON    equ 0x00F2F2F2
C_BAR_BG  equ 0x00505050
C_BAR_FG  equ 0x00EDEDED
C_HINT    equ 0x00808080

; 5th / 6th argument for an outgoing call
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

section .data
s_drop      db "drop music here", 0
s_slash     db " / ", 0
s_sep       db "  ", 0
s_vol       db "vol ", 0
s_dots      db "...", 0
s_q         db "--:--", 0
s_fontpfx   db "Font: ", 0
; PEEP_VERSION comes from the README title (see the Makefile), so the version
; Peep shows can't drift from the release.
%ifndef PEEP_VERSION
%define PEEP_VERSION "dev"
%endif
s_version   db "Peep ", PEEP_VERSION, 0
s_default   db "Default", 0
s_bad       db "  (can't read)", 0
s_hint      db "put .ttf / .otf files in ", 0
s_nofonts   db "this build has no font support", 0
%include "font.inc"

section .bss
alignb 8
cur_info    resq 1
cache_px    resq 1
cache_art   resq 1
cache_w     resd 1
cache_h     resd 1
exp_w       resd 1
exp_h       resd 1
user_sized  resd 1
font_idx    resd 1
font_h      resq 1
font_map    resq 1
font_mlen   resq 1
font_list   resq 1
dlg_until   resq 1
rc_buf      resq 1
rc_w        resd 1
rc_h        resd 1
btn_ok      resd 1
hover       resd 1             ; the pointer is over the window
ui_a        resd 1             ; overlay opacity this frame, 0..256
leave_ms    resq 1             ; when the pointer left
ov_top      resd 1             ; first row the overlay drew on (fade from here)
last_sec    resq 1             ; the clock reading in the last frame drawn
drawn_a     resd 1             ; overlay opacity in the last frame (0: none drawn)
fs_mode     resd 1             ; fullscreen: controls and pointer follow pointer activity
act_ms      resq 1             ; when the pointer last moved
GC_N        equ 512            ; glyph cache entries (direct mapped)
GC_SZ       equ 32             ; cp, px, bitmap, w, h, xoff, yoff
alignb 8
gcache      resb GC_N * GC_SZ
btn         resd 12            ; 3 x (x0, y0, x1, y1)
tl_bytes    resq 1
; scaler parameters
sc_src      resq 1
sc_sw       resd 1
sc_sh       resd 1
sc_dst      resq 1
sc_dw       resd 1
sc_dh       resd 1
sc_dstride  resd 1
dlg1        resb 320
dlg2        resb 1100
tbuf        resb 600
tbuf2       resb 600

section .text

; ============================================================================
; primitives
; ============================================================================

; fill_rect(x, y, w, h, color) — clipped to the framebuffer
FUNC fill_rect, 0
    mov  rax, IN5
    movsxd r12, A1d
    movsxd r13, A2d
    movsxd r14, A3d
    add  r14, r12
    movsxd r15, A4d
    add  r15, r13
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
    shl  rbx, 2
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

; darken_rect(x, y, w, h, mul): every channel *= mul/256
FUNC darken_rect, 0
    mov  rax, IN5
    movd xmm1, eax
    pshuflw xmm1, xmm1, 0
    punpcklqdq xmm1, xmm1              ; mul in all 8 words
    pxor xmm2, xmm2
    movsxd r12, A1d
    movsxd r13, A2d
    movsxd r14, A3d
    add  r14, r12
    movsxd r15, A4d
    add  r15, r13
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
    shl  rbx, 2
.row:
    cmp  r13, r15
    jge  .r
    mov  rdi, r13
    imul rdi, rbx
    add  rdi, [rc_buf]
    lea  rdi, [rdi + r12*4]
    mov  rcx, r14
    sub  rcx, r12
.p4:cmp  rcx, 4                        ; 4 pixels a step
    jb   .p1
    movdqu xmm0, [rdi]
    movdqa xmm3, xmm0
    punpcklbw xmm0, xmm2
    punpckhbw xmm3, xmm2
    pmullw xmm0, xmm1
    pmullw xmm3, xmm1
    psrlw xmm0, 8
    psrlw xmm3, 8
    packuswb xmm0, xmm3
    movdqu [rdi], xmm0
    add  rdi, 16
    sub  rcx, 4
    jmp  .p4
.p1:test rcx, rcx
    jz   .nx
.px:movd xmm0, [rdi]
    punpcklbw xmm0, xmm2
    pmullw xmm0, xmm1
    psrlw xmm0, 8
    packuswb xmm0, xmm2
    movd [rdi], xmm0
    add  rdi, 4
    dec  rcx
    jnz  .px
.nx:inc  r13
    jmp  .row
.r: RET_

; tri(x0, y0, w, h, color, pointing_left)
FUNC tri, 16
    ARGS r12, r13, r14, r15
    mov  rax, IN5
    mov  [L(0)], rax
    mov  rax, IN6
    mov  [L(8)], rax
    test r15d, r15d
    jle  .r
    xor  ebx, ebx                     ; row
.l: cmp  ebx, r15d
    jge  .r
    lea  eax, [rbx*2 + 1]             ; |2r+1-h|
    sub  eax, r15d
    cdq
    xor  eax, edx
    sub  eax, edx
    mov  ecx, r15d
    sub  ecx, eax                     ; h - dist
    mov  eax, r14d
    imul eax, ecx
    cdq
    idiv r15d                         ; run length
    mov  A3d, eax
    mov  ecx, r12d
    cmp  dword [L(8)], 0
    je   .rt
    add  ecx, r14d
    sub  ecx, eax                     ; flush right
.rt:mov  A1d, ecx
    lea  A2d, [r13d + ebx]
    mov  A4, 1
    mov  rax, [L(0)]
    SET5 rax
    call fill_rect
    inc  ebx
    jmp  .l
.r: RET_

; ============================================================================
; text
; ============================================================================

; next_cp: UTF-8 at [rsi] -> eax code point, rsi advanced (0 at end, not
; advanced). Leaf; clobbers ecx, edx.
next_cp:
    movzx eax, byte [rsi]
    test eax, eax
    jz   .ret
    inc  rsi
    cmp  eax, 0x80
    jb   .ret
    cmp  eax, 0xC0
    jb   .bad
    mov  edx, 1
    and  eax, 0x1F
    cmp  byte [rsi - 1], 0xE0
    jb   .more
    mov  edx, 2
    and  eax, 0x0F
    cmp  byte [rsi - 1], 0xF0
    jb   .more
    mov  edx, 3
    and  eax, 0x07
    cmp  byte [rsi - 1], 0xF8
    jae  .bad
.more:
    movzx ecx, byte [rsi]
    mov  r10d, ecx
    and  r10d, 0xC0
    cmp  r10d, 0x80
    jne  .bad
    shl  eax, 6
    and  ecx, 0x3F
    or   eax, ecx
    inc  rsi
    dec  edx
    jnz  .more
.ret:
    ret
.bad:
    mov  eax, 0xFFFD
    ret

; bscale: built-in font pixel size -> integer scale. eax in/out. Leaf.
bscale:
    add  eax, 4
    shr  eax, 3
    jnz  .ok
    mov  eax, 1
.ok:ret

; text_h(px) -> eax rendered line height
FUNC text_h, 0
    mov  eax, A1d
    cmp  qword [font_h], 0
    jne  .r
    call bscale
    shl  eax, 3
.r: RET_

; tlayout(str, px, limit) -> eax width of the longest prefix that fits in
; `limit` pixels; [tl_bytes] = its length in bytes
FUNC tlayout, 32
    ARGS rbx, r12, r13
    mov  rsi, rbx
    xor  r14d, r14d                   ; pen, 26.6
    xor  r15d, r15d                   ; previous code point
.l: mov  [L(0)], rsi
    call next_cp
    test eax, eax
    jz   .end
    mov  [L(8)], eax
    mov  [L(16)], rsi
    cmp  qword [font_h], 0
    jne  .ttf
    mov  eax, r12d
    call bscale
    shl  eax, 3 + 6
    jmp  .adv
.ttf:
%ifndef PURE
    xor  eax, eax
    test r15d, r15d
    jz   .nk
    mov  A1, [font_h]
    mov  A2d, r15d
    mov  A3d, [L(8)]
    mov  A4d, r12d
    call font_kern
.nk:mov  [L(24)], eax
    mov  A1, [font_h]
    mov  A2d, [L(8)]
    mov  A3d, r12d
    call font_advance
    add  eax, [L(24)]
%endif
.adv:
    lea  ecx, [r14d + eax]
    lea  edx, [ecx + 63]
    sar  edx, 6
    cmp  edx, r13d
    jg   .stop
    mov  r14d, ecx
    mov  eax, [L(8)]
    mov  r15d, eax
    mov  rsi, [L(16)]
    jmp  .l
.stop:
    mov  rsi, [L(0)]
.end:
    sub  rsi, rbx
    mov  [tl_bytes], rsi
    lea  eax, [r14d + 63]
    sar  eax, 6
    RET_

; text_width(str, px) -> eax
FUNC text_width, 0
    mov  A3, 0x7FFFFFFF
    call tlayout
    RET_

; text_fit(src, px, maxw, dst): copy src, cut with "..." if wider than maxw
FUNC text_fit, 16
    ARGS rbx, r12, r13, r14
    mov  A1, rbx
    mov  A2, r12
    mov  A3, r13
    call tlayout
    mov  r15, [tl_bytes]
    cmp  byte [rbx + r15], 0
    je   .all                         ; everything fit
    lea  A1, [s_dots]
    mov  A2, r12
    call text_width
    mov  A3d, r13d
    sub  A3d, eax
    jg   .cut
    xor  A3d, A3d
.cut:
    mov  A1, rbx
    mov  A2, r12
    call tlayout
    mov  r15, [tl_bytes]
    mov  A1, r14
    mov  A2, rbx
    mov  A3, r15
    call memcpy
    mov  dword [r14 + r15], '...'
    RET_
.all:
    mov  A1, r14
    mov  A2, rbx
    lea  A3, [r15 + 1]
    call memcpy
    RET_

; blit_alpha(coverage, w, h, x, y, color): blend an 8-bit mask in
FUNC blit_alpha, 16
    ARGS rbx, r12, r13, r14
    mov  rax, IN5
    movsxd r15, eax                   ; y
    mov  rax, IN6
    mov  [L(0)], eax
    xor  esi, esi                     ; row
.row:
    cmp  esi, r13d
    jge  .r
    lea  eax, [r15d + esi]
    cmp  eax, 0
    jl   .nr
    cmp  eax, [rc_h]
    jge  .r
    imul eax, [rc_w]
    mov  [L(4)], eax                  ; row base (pixels)
    xor  edi, edi                     ; col
.col:
    cmp  edi, r12d
    jge  .nr
    lea  ecx, [r14d + edi]
    cmp  ecx, 0
    jl   .nc
    cmp  ecx, [rc_w]
    jge  .nr
    mov  eax, esi
    imul eax, r12d
    add  eax, edi
    movzx edx, byte [rbx + rax]       ; coverage
    test edx, edx
    jz   .nc
    mov  eax, edx
    shr  eax, 7
    add  edx, eax                     ; 0..256
    add  ecx, [L(4)]
    mov  r8, [rc_buf]
    lea  r8, [r8 + rcx*4]
    ; three channels
%assign ch 0
%rep 3
    movzx eax, byte [r8 + ch]
    movzx ecx, byte [rsp + OUTSZ + ch]  ; colour byte (L(0)+ch)
    sub  ecx, eax
    imul ecx, edx
    sar  ecx, 8
    add  eax, ecx
    mov  [r8 + ch], al
%assign ch ch+1
%endrep
.nc:inc  edi
    jmp  .col
.nr:inc  esi
    jmp  .row
.r: RET_

; text_draw(x, y, str, px, color)
FUNC text_draw, 64
    ARGS r12, r13, rbx, r14
    mov  rax, IN5
    mov  [L(0)], rax
    cmp  qword [font_h], 0
    jne  .ttf
    ; ---- built-in bitmap font
    mov  eax, r14d
    call bscale
    mov  r14d, eax                    ; scale
.bch:
    mov  rsi, rbx
    call next_cp
    test eax, eax
    jz   .r
    mov  rbx, rsi
    cmp  eax, 32
    jb   .q
    cmp  eax, 126
    jbe  .ok
.q: mov  eax, '?'
.ok:sub  eax, 32
    lea  rcx, [font8x8]
    lea  rcx, [rcx + rax*8]
    mov  [L(8)], rcx
    xor  r15d, r15d                   ; row
.brow:
    cmp  r15d, 8
    jae  .bnext
    mov  rcx, [L(8)]
    movzx eax, byte [rcx + r15]
    mov  [L(16)], eax
    mov  dword [L(20)], 0             ; col
.bcol:
    mov  ecx, [L(20)]
    cmp  ecx, 8
    jae  .bnrow
    mov  eax, [L(16)]
    bt   eax, ecx
    jnc  .bskip
    imul ecx, r14d
    add  ecx, r12d
    mov  A1d, ecx
    mov  eax, r15d
    imul eax, r14d
    add  eax, r13d
    mov  A2d, eax
    mov  A3d, r14d
    mov  A4d, r14d
    mov  rax, [L(0)]
    SET5 rax
    call fill_rect
.bskip:
    inc  dword [L(20)]
    jmp  .bcol
.bnrow:
    inc  r15d
    jmp  .brow
.bnext:
    lea  eax, [r14d*8]
    add  r12d, eax
    jmp  .bch
.ttf:
%ifndef PURE
    mov  A1, [font_h]
    mov  A2d, r14d
    call font_ascent
    add  r13d, eax                    ; baseline
    shl  r12d, 6                      ; pen, 26.6
    xor  r15d, r15d                   ; previous code point
.tch:
    mov  rsi, rbx
    call next_cp
    test eax, eax
    jz   .r
    mov  rbx, rsi
    mov  [L(8)], eax
    test r15d, r15d
    jz   .tnk
    mov  A1, [font_h]
    mov  A2d, r15d
    mov  A3d, eax
    mov  A4d, r14d
    call font_kern
    add  r12d, eax
.tnk:
    mov  A1d, [L(8)]
    mov  A2d, r14d
    call glyph_get                    ; rasterized once, then reused
    test rax, rax
    jz   .tadv
    mov  r10, rax                     ; not an argument register on either ABI
    mov  A1, [r10 + 8]                ; coverage
    test A1, A1
    jz   .tadv                        ; blank glyph (space)
    mov  A2d, [r10 + 16]              ; w
    mov  A3d, [r10 + 20]              ; h
    mov  eax, r12d
    sar  eax, 6
    add  eax, [r10 + 24]              ; xoff
    mov  A4d, eax
    mov  eax, r13d
    add  eax, [r10 + 28]              ; yoff
    movsxd rax, eax
    SET5 rax
    mov  rax, [L(0)]
    SET6 rax
    call blit_alpha
.tadv:
    mov  A1, [font_h]
    mov  A2d, [L(8)]
    mov  A3d, r14d
    call font_advance
    add  r12d, eax
    mov  r15d, [L(8)]
    jmp  .tch
%endif
.r: RET_

; ---- tiny string builders: dst in A1, return the new end in rax
FUNC s_cat, 0
    mov  rax, A1
.l: mov  cl, [A2]
    mov  [rax], cl
    test cl, cl
    jz   .r
    inc  rax
    inc  A2
    jmp  .l
.r: RET_

FUNC s_num, 32                          ; (dst, value, min_digits)
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

FUNC s_time, 0                          ; (dst, seconds) -> "m:ss"
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

; ============================================================================
; cover art
; ============================================================================

; halve(src, w, h) -> rax new w/2 x h/2 image (2x2 box filter), caller frees
FUNC halve, 0
    ARGS rbx, r12, r13
    lea  r15d, [r12d*4]               ; source stride (odd widths too)
    shr  r12d, 1
    shr  r13d, 1
    mov  eax, r12d
    imul eax, r13d
    lea  A1, [rax*4]
    call malloc
    test rax, rax
    jz   .r
    mov  r14, rax
    mov  rdi, rax
    xor  esi, esi                     ; y
.y: cmp  esi, r13d
    jae  .d
    mov  eax, esi
    imul eax, r15d
    lea  r8, [rbx + rax*2]            ; source row 2y
    lea  r9, [r8 + r15]               ; source row 2y+1
    mov  ecx, r12d
.x: movq xmm0, [r8]                   ; two pixels
    movq xmm1, [r9]
    pavgb xmm0, xmm1
    pshuflw xmm1, xmm0, 0x4E          ; swap the two pixels
    pavgb xmm0, xmm1
    movd [rdi], xmm0
    add  r8, 8
    add  r9, 8
    add  rdi, 4
    dec  ecx
    jnz  .x
    inc  esi
    jmp  .y
.d: mov  rax, r14
.r: RET_

; scale_run(): bilinear sc_src(sw x sh) -> sc_dst(dw x dh, stride sc_dstride)
FUNC scale_run, 80
    movdqu [L(32)], xmm6              ; callee-saved on Windows
    movdqu [L(48)], xmm7
    movdqu [L(64)], xmm8
    ; x table: per destination column, x0 (dword) and weight (dword)
    mov  eax, [sc_dw]
    lea  A1, [rax*8]
    call malloc
    test rax, rax
    jz   .r
    mov  [L(0)], rax
    mov  rbx, rax
    xor  ecx, ecx
.xt:cmp  ecx, [sc_dw]
    jae  .xtd
    mov  r8d, ecx
    call coord                        ; r8d dest index, uses sc_sw/sc_dw
    mov  [rbx + rcx*8], eax           ; x0
    mov  [rbx + rcx*8 + 4], edx       ; weight
    inc  ecx
    jmp  .xt
.xtd:
    pxor xmm7, xmm7
    mov  r15d, [sc_sw]
    shl  r15d, 2                      ; source stride
    xor  r12d, r12d                   ; y
.y: cmp  r12d, [sc_dh]
    jae  .done
    mov  r8d, r12d
    call ycoord                       ; eax y0, edx wy
    mov  r13, [sc_src]
    mov  r9d, eax
    imul r9, r15
    add  r13, r9                      ; row y0
    lea  r14, [r13 + r15]             ; row y0+1
    mov  ecx, [sc_sh]
    dec  ecx
    cmp  eax, ecx
    jb   .y1
    mov  r14, r13
.y1:mov  eax, 256
    sub  eax, edx
    movd xmm5, eax
    pshuflw xmm5, xmm5, 0             ; 256 - wy
    movd xmm6, edx
    pshuflw xmm6, xmm6, 0             ; wy
    mov  rdi, [sc_dst]
    mov  eax, r12d
    imul eax, [sc_dstride]
    add  rdi, rax
    xor  esi, esi                     ; x
    mov  r10d, [sc_sw]
    dec  r10d                         ; last column
.x: cmp  esi, [sc_dw]
    jae  .nexty
    mov  eax, [rbx + rsi*8]           ; x0
    mov  edx, [rbx + rsi*8 + 4]       ; wx
    mov  r9d, eax
    cmp  eax, r10d
    jae  .xl
    inc  r9d
.xl:movd xmm0, [r13 + rax*4]
    movd xmm1, [r13 + r9*4]
    movd xmm2, [r14 + rax*4]
    movd xmm3, [r14 + r9*4]
    punpcklbw xmm0, xmm7
    punpcklbw xmm1, xmm7
    punpcklbw xmm2, xmm7
    punpcklbw xmm3, xmm7
    mov  eax, 256
    sub  eax, edx
    movd xmm4, eax
    pshuflw xmm4, xmm4, 0
    movd xmm8, edx
    pshuflw xmm8, xmm8, 0
    pmullw xmm0, xmm4
    pmullw xmm1, xmm8
    paddw xmm0, xmm1
    psrlw xmm0, 8                     ; top
    pmullw xmm2, xmm4
    pmullw xmm3, xmm8
    paddw xmm2, xmm3
    psrlw xmm2, 8                     ; bottom
    pmullw xmm0, xmm5
    pmullw xmm2, xmm6
    paddw xmm0, xmm2
    psrlw xmm0, 8
    packuswb xmm0, xmm7
    movd [rdi + rsi*4], xmm0
    inc  esi
    jmp  .x
.nexty:
    inc  r12d
    jmp  .y
.done:
    mov  A1, [L(0)]
    call free
.r: movdqu xmm6, [L(32)]
    movdqu xmm7, [L(48)]
    movdqu xmm8, [L(64)]
    RET_

; coord: r8d = destination index along x -> eax source index, edx weight
; src = (i + 0.5) * sw / dw - 0.5, in 1/256 steps. Leaf; keeps rcx.
coord:
    push rcx
    mov  eax, r8d
    lea  eax, [rax*2 + 1]
    imul rax, rax, 128                ; (2i+1) * 128
    mov  ecx, [sc_sw]
    imul rax, rcx
    mov  ecx, [sc_dw]
    jmp  coord_tail
ycoord:
    push rcx
    mov  eax, r8d
    lea  eax, [rax*2 + 1]
    imul rax, rax, 128
    mov  ecx, [sc_sh]
    imul rax, rcx
    mov  ecx, [sc_dh]
coord_tail:
    xor  edx, edx
    div  rcx
    sub  rax, 128
    jns  .p
    xor  eax, eax
.p: mov  edx, eax
    and  edx, 255
    shr  eax, 8
    pop  rcx
    ret

; build_cache(): letterbox the current art into a window-sized image
FUNC build_cache, 16
    mov  eax, [rc_w]
    cmp  eax, [cache_w]
    jne  .re
    mov  eax, [rc_h]
    cmp  eax, [cache_h]
    jne  .re
    cmp  qword [cache_px], 0
    jne  .fill
.re:mov  A1, [cache_px]
    call free
    mov  eax, [rc_w]
    imul eax, [rc_h]
    lea  A1, [rax*4]
    call malloc
    mov  [cache_px], rax
    test rax, rax
    jz   .r
    mov  eax, [rc_w]
    mov  [cache_w], eax
    mov  eax, [rc_h]
    mov  [cache_h], eax
.fill:
    mov  rdi, [cache_px]
    mov  ecx, [rc_w]
    imul ecx, [rc_h]
    xor  eax, eax
    rep  stosd
    mov  rax, [cur_info]
    xor  ebx, ebx
    test rax, rax
    jz   .done
    mov  rbx, [rax + INFO_ART]
    test rbx, rbx
    jz   .done
    ; fit: the art is taller than the window if aw*H <= ah*W
    mov  r12d, [rbx + ART_W]
    mov  r13d, [rbx + ART_H]
    mov  eax, [rc_h]
    mov  r8, r12
    imul r8, rax                      ; aw*H
    mov  eax, [rc_w]
    mov  r9, r13
    imul r9, rax                      ; ah*W
    cmp  r8, r9
    ja   .wide
    mov  r15d, [rc_h]                 ; dh = H
    mov  rax, r8
    xor  edx, edx
    div  r13                          ; dw = aw*H/ah
    mov  r14d, eax
    jmp  .fit
.wide:
    mov  r14d, [rc_w]                 ; dw = W
    mov  rax, r9
    xor  edx, edx
    div  r12                          ; dh = ah*W/aw
    mov  r15d, eax
.fit:
    cmp  r14d, 1
    jae  .f1
    mov  r14d, 1
.f1:cmp  r15d, 1
    jae  .f2
    mov  r15d, 1
.f2:
    ; destination origin
    mov  eax, [rc_h]
    sub  eax, r15d
    shr  eax, 1
    imul eax, [rc_w]
    mov  ecx, [rc_w]
    sub  ecx, r14d
    shr  ecx, 1
    add  eax, ecx
    mov  rcx, [cache_px]
    lea  rcx, [rcx + rax*4]
    mov  [sc_dst], rcx
    mov  [sc_dw], r14d
    mov  [sc_dh], r15d
    mov  eax, [rc_w]
    shl  eax, 2
    mov  [sc_dstride], eax
    ; halve big pictures first so the bilinear step never skips pixels
    mov  rax, [rbx + ART_PX]
    mov  [sc_src], rax
    mov  [sc_sw], r12d
    mov  [sc_sh], r13d
    mov  qword [L(0)], 0              ; temporary to free
.halve:
    mov  eax, r14d
    shl  eax, 1
    cmp  [sc_sw], eax
    jb   .bil
    mov  eax, r15d
    shl  eax, 1
    cmp  [sc_sh], eax
    jb   .bil
    mov  A1, [sc_src]
    mov  A2d, [sc_sw]
    mov  A3d, [sc_sh]
    call halve
    test rax, rax
    jz   .bil
    mov  r12, rax
    mov  A1, [L(0)]
    call free
    mov  [L(0)], r12
    mov  [sc_src], r12
    shr  dword [sc_sw], 1
    shr  dword [sc_sh], 1
    jmp  .halve
.bil:
    call scale_run
    mov  A1, [L(0)]
    call free
.done:
    mov  [cache_art], rbx
.r: RET_

; ============================================================================
; overlay
; ============================================================================

; icon(index 0..2, cx, cy, size)
FUNC icon, 16
    ARGS rbx, r12, r13, r14
    ; hit box = centre +/- 3/4 size
    lea  eax, [r14d*2 + r14d]
    shr  eax, 2
    lea  rcx, [btn]
    shl  ebx, 4
    add  rcx, rbx
    shr  ebx, 4
    mov  edx, r12d
    sub  edx, eax
    mov  [rcx], edx
    mov  edx, r13d
    sub  edx, eax
    mov  [rcx + 4], edx
    lea  edx, [r12d + eax]
    mov  [rcx + 8], edx
    lea  edx, [r13d + eax]
    mov  [rcx + 12], edx
    cmp  ebx, 1
    je   .play
    ; previous / next: a bar and a triangle in a size*3/4 x size*4/5 box
    mov  r15d, r14d
    imul r15d, 4
    mov  eax, r15d
    xor  edx, edx
    mov  ecx, 5
    div  ecx
    mov  r15d, eax                    ; height
    mov  eax, r14d
    shr  eax, 3
    jnz  .bw
    mov  eax, 1
.bw:mov  [L(0)], eax                  ; bar width
    mov  esi, r13d
    mov  eax, r15d
    shr  eax, 1
    sub  esi, eax                     ; top
    cmp  ebx, 2
    je   .next
    ; previous: bar at cx - 3/8 s, triangle pointing left from cx - s/4
    mov  eax, r14d
    imul eax, 3
    shr  eax, 3
    mov  A1d, r12d
    sub  A1d, eax
    mov  A2d, esi
    mov  A3d, [L(0)]
    mov  A4d, r15d
    SET5 C_ICON
    call fill_rect
    mov  eax, r14d
    shr  eax, 2
    mov  A1d, r12d
    sub  A1d, eax
    mov  A2d, esi
    mov  eax, r14d
    imul eax, 3
    shr  eax, 2
    mov  A3d, eax
    mov  A4d, r15d
    SET5 C_ICON
    SET6 1
    call tri
    RET_
.next:
    mov  eax, r14d
    shr  eax, 1
    mov  A1d, r12d
    sub  A1d, eax
    mov  A2d, esi
    mov  eax, r14d
    imul eax, 3
    shr  eax, 2
    mov  A3d, eax
    mov  A4d, r15d
    SET5 C_ICON
    SET6 0
    call tri
    mov  eax, r14d
    shr  eax, 2
    mov  A1d, r12d
    add  A1d, eax
    mov  A2d, esi
    mov  A3d, [L(0)]
    mov  A4d, r15d
    SET5 C_ICON
    call fill_rect
    RET_
.play:
    cmp  dword [g_paused], 0          ; paused or finished: show "play"
    jne  .tri
    cmp  dword [st_playing], 0
    je   .tri
    ; pause: two bars
    mov  esi, r13d
    mov  eax, r14d
    shr  eax, 1
    sub  esi, eax
    mov  r15d, r14d
    shr  r15d, 2                      ; bar width
    mov  eax, r14d
    imul eax, 3
    shr  eax, 3
    mov  A1d, r12d
    sub  A1d, eax
    mov  A2d, esi
    mov  A3d, r15d
    mov  A4d, r14d
    SET5 C_ICON
    call fill_rect
    mov  eax, r14d
    shr  eax, 3
    mov  A1d, r12d
    add  A1d, eax
    mov  A2d, esi
    mov  A3d, r15d
    mov  A4d, r14d
    SET5 C_ICON
    call fill_rect
    RET_
.tri:
    mov  ecx, 5
    mov  eax, r14d
    imul eax, 2
    xor  edx, edx
    div  ecx
    mov  r15d, eax                    ; 2/5 size: left of centre
    mov  eax, r14d
    imul eax, 4
    xor  edx, edx
    div  ecx
    mov  [L(0)], eax                  ; 4/5 size: width
    mov  ebx, r13d
    mov  eax, r14d
    shr  eax, 1
    sub  ebx, eax                     ; top
    mov  A1d, r12d
    sub  A1d, r15d
    mov  A2d, ebx
    mov  A3d, [L(0)]
    mov  A4d, r14d
    SET5 C_ICON
    SET6 0
    call tri
    RET_

; overlay(): everything Tab shows
;   locals: 0 u, 4 pad, 8 px_title, 12 px_artist, 16 px_small, 20 bar_y,
;           24 bar_h, 28 time_y, 32 artist_y, 36 title_y, 40 icon_s,
;           44 icon_cy, 48 band_top
FUNC overlay, 64
    mov  dword [btn_ok], 0
    mov  dword [ov_top], 0             ; until the layout says otherwise
    mov  eax, [rc_w]
    mov  ecx, [rc_h]
    cmp  eax, ecx
    cmova eax, ecx
    shr  eax, 5
    cmp  eax, 6
    jae  .u
    mov  eax, 6
.u: imul eax, 19                      ; with the button row merged into the
    xor  edx, edx                     ; time row the controls are about 30% shorter
    mov  ecx, 20                      ; than before: unit = 0.95 * side / 32
    div  ecx
    mov  [L(0)], eax
    mov  r12d, eax                    ; u
    lea  eax, [r12d*3]
    shr  eax, 1
    mov  [L(4)], eax                  ; pad
    imul eax, r12d, 7
    shr  eax, 2
    mov  [L(8)], eax                  ; title px
    lea  eax, [r12d*5]
    shr  eax, 2
    mov  [L(12)], eax                 ; artist px
    lea  eax, [r12d*3]
    shr  eax, 2
    mov  [L(16)], eax                 ; small px: 3u/4, so the time row text
                                      ; fits beside the buttons at every size
    cmp  dword [st_count], 0
    jne  .player
    ; ---- nothing loaded yet
    lea  A1, [s_drop]
    mov  A2d, [L(12)]
    call text_width
    mov  ecx, [rc_w]
    sub  ecx, eax
    sar  ecx, 1
    mov  ebx, ecx
    mov  A1d, [L(12)]
    call text_h
    mov  ecx, [rc_h]
    sub  ecx, eax
    sar  ecx, 1
    mov  A1d, ebx
    mov  A2d, ecx
    lea  A3, [s_drop]
    mov  A4d, [L(12)]
    SET5 C_HINT
    call text_draw
    RET_
.player:
    ; ---- vertical layout, bottom up
    mov  eax, r12d
    mov  ecx, 5
    xor  edx, edx
    div  ecx
    cmp  eax, 2
    jae  .bh
    mov  eax, 2
.bh:mov  [L(24)], eax                 ; bar height
    mov  ecx, [rc_h]
    sub  ecx, [L(4)]
    sub  ecx, eax
    mov  [L(20)], ecx                 ; bar y
    ; the buttons sit centred directly above the progress bar, and the time
    ; and track text share their row on either side
    lea  eax, [r12d*2]
    mov  [L(40)], eax                 ; icon size
    mov  edx, r12d
    shr  edx, 1
    sub  ecx, edx                     ; u/2 above the bar
    sub  ecx, r12d                    ; and half the icon size up: the centre
    mov  [L(44)], ecx                 ; icon centre y
    mov  A1d, [L(16)]
    call text_h
    shr  eax, 1
    mov  ecx, [L(44)]
    sub  ecx, eax
    mov  [L(28)], ecx                 ; time row y: centred on the buttons
    mov  ecx, [L(44)]
    sub  ecx, r12d
    mov  [L(52)], ecx                 ; top of the button row
    mov  [L(32)], ecx                 ; artist y (if none: the button row)
    mov  rbx, [cur_info]
    test rbx, rbx
    jz   .noart
    cmp  byte [rbx + INFO_ARTIST], 0
    je   .noart
    mov  A1d, [L(12)]
    call text_h
    mov  ecx, [L(52)]
    sub  ecx, eax
    mov  eax, r12d
    shr  eax, 1
    sub  ecx, eax
    mov  [L(32)], ecx
.noart:
    mov  A1d, [L(8)]
    call text_h
    mov  ecx, [L(32)]
    sub  ecx, eax
    mov  eax, r12d
    shr  eax, 1
    sub  ecx, eax
    mov  [L(36)], ecx                 ; title y
    lea  edx, [rcx]
    lea  ecx, [r12d*2]
    sub  edx, ecx
    mov  [L(48)], edx                 ; gradient top
    ; ---- gradient: fade to ~78% darkness over 3u
    mov  ebx, edx
    cmp  ebx, 0
    jge  .g0
    xor  ebx, ebx
.g0:mov  [ov_top], ebx                ; nothing is drawn above the gradient
.g: cmp  ebx, [rc_h]
    jge  .gd
    mov  eax, ebx
    sub  eax, [L(48)]
    imul eax, 200
    lea  ecx, [r12d*3]
    xor  edx, edx
    div  ecx
    cmp  eax, 200
    jbe  .ga
    mov  eax, 200
.ga:mov  r13d, 256
    sub  r13d, eax
    xor  A1d, A1d
    mov  A2d, ebx
    mov  A3d, [rc_w]
    mov  A4, 1
    SET5 r13
    call darken_rect
    inc  ebx
    jmp  .g
.gd:
    ; ---- progress bar
    mov  A1d, [L(4)]
    mov  A2d, [L(20)]
    mov  eax, [rc_w]
    sub  eax, [L(4)]
    sub  eax, [L(4)]
    mov  A3d, eax
    mov  A4d, [L(24)]
    SET5 C_BAR_BG
    call fill_rect
    call disp_pos
    mov  rcx, [st_total]
    test rcx, rcx
    jz   .nobar
    mov  edx, [rc_w]
    sub  edx, [L(4)]
    sub  edx, [L(4)]
    imul rax, rdx
    xor  edx, edx
    div  rcx
    mov  A3d, eax
    mov  A1d, [L(4)]
    mov  A2d, [L(20)]
    mov  A4d, [L(24)]
    SET5 C_BAR_FG
    call fill_rect
.nobar:
    ; ---- time row, left: m:ss / m:ss
    lea  rbx, [tbuf]
    call disp_pos
    FR2SEC rax
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
    jmp  .tl
.tt:FR2SEC [st_total]
    mov  A1, rbx
    mov  A2, rax
    call s_time
.tl:mov  A1d, [L(4)]
    mov  A2d, [L(28)]
    lea  A3, [tbuf]
    mov  A4d, [L(16)]
    SET5 C_DIM
    call text_draw
    ; ---- time row, right: N/M  vol V
    mov  eax, [cur_idx]
    mov  ecx, [st_count]
    cmp  eax, ecx
    jb   .ix
    lea  eax, [ecx - 1]
.ix:inc  eax
    lea  A1, [tbuf]
    mov  A2, rax
    mov  A3, 1
    call s_num
    mov  byte [rax], '/'
    lea  A1, [rax + 1]
    mov  A2d, [st_count]
    mov  A3, 1
    call s_num
    mov  A1, rax
    lea  A2, [s_sep]
    call s_cat
    mov  A1, rax
    lea  A2, [s_vol]
    call s_cat
    mov  A1, rax
    mov  eax, [g_volstep]
    imul eax, 5
    mov  A2, rax
    mov  A3, 1
    call s_num
    lea  A1, [tbuf]
    mov  A2d, [L(16)]
    call text_width
    mov  ecx, [rc_w]
    sub  ecx, [L(4)]
    sub  ecx, eax
    mov  A1d, ecx
    mov  A2d, [L(28)]
    lea  A3, [tbuf]
    mov  A4d, [L(16)]
    SET5 C_DIM
    call text_draw
    ; ---- title and artist
    mov  rbx, [cur_info]
    test rbx, rbx
    jz   .icons
    mov  r13d, [rc_w]
    sub  r13d, [L(4)]
    sub  r13d, [L(4)]                 ; text width available
    lea  A1, [rbx + INFO_TITLE]
    mov  A2d, [L(8)]
    mov  A3d, r13d
    lea  A4, [tbuf]
    call text_fit
    lea  A1, [tbuf]
    mov  A2d, [L(8)]
    mov  A3d, [L(4)]
    call centre_x                      ; centred above the buttons
    mov  A1d, eax
    mov  A2d, [L(36)]
    lea  A3, [tbuf]
    mov  A4d, [L(8)]
    SET5 C_TITLE
    call text_draw
    cmp  byte [rbx + INFO_ARTIST], 0
    je   .icons
    lea  A1, [rbx + INFO_ARTIST]
    mov  A2d, [L(12)]
    mov  A3d, r13d
    lea  A4, [tbuf]
    call text_fit
    lea  A1, [tbuf]
    mov  A2d, [L(12)]
    mov  A3d, [L(4)]
    call centre_x
    mov  A1d, eax
    mov  A2d, [L(32)]
    lea  A3, [tbuf]
    mov  A4d, [L(12)]
    SET5 C_ARTIST
    call text_draw
.icons:
    ; ---- previous / play-pause / next, centred
    mov  r13d, [rc_w]
    shr  r13d, 1                      ; cx
    mov  r14d, [L(40)]                ; size
    mov  r15d, r14d
    shr  r15d, 1
    add  r15d, r14d                   ; spacing 1.5 x size = 3u: the hit boxes
                                      ; (3u wide) just touch, text keeps its room
    xor  A1, A1
    mov  A2d, r13d
    sub  A2d, r15d
    mov  A3d, [L(44)]
    mov  A4d, r14d
    call icon
    mov  A1, 1
    mov  A2d, r13d
    mov  A3d, [L(44)]
    mov  A4d, r14d
    call icon
    mov  A1, 2
    lea  A2d, [r13d + r15d]
    mov  A3d, [L(44)]
    mov  A4d, r14d
    call icon
    mov  dword [btn_ok], 1
    RET_

; centre_x(str, px, margin) -> eax: the x that centres the string in the window.
; A string as wide as the margins allow stays flush with the left margin.
FUNC centre_x, 0
    mov  r12d, A3d                    ; margin
    call text_width                   ; (str, px) are still in A1, A2
    mov  ecx, [rc_w]
    sub  ecx, eax
    shr  ecx, 1
    cmp  ecx, r12d
    jge  .r
    mov  ecx, r12d
.r: mov  eax, ecx
    RET_

; dialog(): font notice, top-left
FUNC dialog, 32
    mov  eax, [rc_w]
    mov  ecx, [rc_h]
    cmp  eax, ecx
    cmova eax, ecx
    shr  eax, 5
    cmp  eax, 6
    jae  .u
    mov  eax, 6
.u: mov  r12d, eax                    ; u
    lea  eax, [r12d*5]
    shr  eax, 2
    mov  r13d, eax                    ; px line 1
    lea  eax, [r12d*2]
    xor  edx, edx
    mov  ecx, 3
    div  ecx
    mov  r14d, eax                    ; px line 2 (smaller)
    lea  eax, [r12d*2]
    xor  edx, edx
    mov  ecx, 3
    div  ecx
    mov  r15d, eax                    ; inner padding
    ; box size
    lea  A1, [dlg1]
    mov  A2d, r13d
    call text_width
    mov  ebx, eax
    mov  A1d, r13d
    call text_h
    mov  [L(0)], eax                  ; box height
    cmp  byte [dlg2], 0
    je   .one
    lea  A1, [dlg2]
    mov  A2d, r14d
    call text_width
    cmp  eax, ebx
    cmova ebx, eax
    mov  A1d, r14d
    call text_h
    add  [L(0)], eax
    mov  eax, r12d
    shr  eax, 2
    add  [L(0)], eax
.one:
    mov  A1d, r12d
    mov  A2d, r12d
    lea  A3d, [rbx + r15*2]
    mov  eax, [L(0)]
    lea  A4d, [rax + r15*2]
    SET5 72                           ; darken to ~28%
    call darken_rect
    lea  eax, [r12d + r15d]
    mov  ebx, eax                     ; text x / y
    mov  A1d, ebx
    mov  A2d, ebx
    lea  A3, [dlg1]
    mov  A4d, r13d
    SET5 C_TITLE
    call text_draw
    cmp  byte [dlg2], 0
    je   .r
    mov  A1d, r13d
    call text_h
    add  eax, ebx
    mov  ecx, r12d
    shr  ecx, 2
    add  eax, ecx
    mov  A1d, ebx
    mov  A2d, eax
    lea  A3, [dlg2]
    mov  A4d, r14d
    SET5 C_ARTIST
    call text_draw
.r: RET_

; ============================================================================
; entry points
; ============================================================================

; core_render(buf, w, h)
FUNC core_render, 0
    mov  [rc_buf], A1
    mov  [rc_w], A2d
    mov  [rc_h], A3d
    mov  dword [btn_ok], 0
    mov  dword [drawn_a], 0
    call disp_secs                     ; remember what the clock shows now, so
    mov  [last_sec], rax               ; a tick can tell if it must redraw
    call plat_ms
    cmp  qword [dlg_until], 0
    je   .t
    cmp  rax, [dlg_until]
    jb   .t
    mov  qword [dlg_until], 0
.t: cmp  dword [g_blank], 0
    je   .art
    mov  rdi, [rc_buf]                ; Shift+Tab: nothing but black
    mov  ecx, [rc_w]
    imul ecx, [rc_h]
    xor  eax, eax
    rep  stosd
    jmp  .dlg
.art:
    mov  rax, [cur_info]
    xor  ecx, ecx
    test rax, rax
    jz   .c
    mov  rcx, [rax + INFO_ART]
.c: cmp  rcx, [cache_art]
    jne  .build
    mov  eax, [rc_w]
    cmp  eax, [cache_w]
    jne  .build
    mov  eax, [rc_h]
    cmp  eax, [cache_h]
    jne  .build
    cmp  qword [cache_px], 0
    jne  .copy
.build:
    call build_cache
    cmp  qword [cache_px], 0
    je   .r
.copy:
    mov  A1, [rc_buf]
    mov  A2, [cache_px]
    mov  eax, [rc_w]
    imul eax, [rc_h]
    lea  A3, [rax*4]
    call memcpy
    call ui_alpha                      ; Tab on, and pointer over us (or fading)
    test eax, eax
    jz   .dlg
    mov  [ui_a], eax
    mov  [drawn_a], eax
    call overlay
    cmp  dword [ui_a], 256
    jae  .dlg
    call fade_overlay
.dlg:
    cmp  qword [dlg_until], 0
    je   .r
    call dialog
.r: RET_

; core_click(x, y) -> eax 1 if a control was hit (0: the click is free,
; e.g. for dragging the window)
FUNC core_click, 0
    ARGS r12, r13
    cmp  dword [btn_ok], 0
    je   .no
    call ui_alpha
    test eax, eax
    jz   .no
    cmp  dword [g_ui], 0
    je   .no
    cmp  dword [g_blank], 0
    jne  .no
    xor  ebx, ebx
.l: cmp  ebx, 3
    jae  .no
    lea  rax, [btn]
    mov  ecx, ebx
    shl  ecx, 4
    add  rax, rcx
    cmp  r12d, [rax]
    jl   .n
    cmp  r12d, [rax + 8]
    jg   .n
    cmp  r13d, [rax + 4]
    jl   .n
    cmp  r13d, [rax + 12]
    jg   .n
    mov  A1d, K_PREV
    cmp  ebx, 0
    je   .k
    mov  A1d, K_PAUSE
    cmp  ebx, 1
    je   .k
    mov  A1d, K_NEXT
.k: call core_key
    mov  eax, 1
    RET_
.n: inc  ebx
    jmp  .l
.no:xor  eax, eax
    RET_

; core_take_info() -> eax 1 if a new track's info arrived
FUNC core_take_info, 0
    xor  eax, eax
    xchg rax, [pending_info]
    test rax, rax
    jz   .r
    mov  rbx, rax
    mov  rcx, [cur_info]
    test rcx, rcx
    jz   .f
    mov  rcx, [rcx + INFO_ART]
    cmp  rcx, [rbx + INFO_ART]
    je   .f
    mov  qword [cache_art], 1         ; force a rebuild even if freed art's
.f: mov  A1, [cur_info]               ; address gets reused
    call info_free
    mov  [cur_info], rbx
    mov  eax, 1
.r: RET_

; core_art_aspect(&w, &h) -> eax 1 if there is cover art
FUNC core_art_aspect, 0
    mov  rax, [cur_info]
    test rax, rax
    jz   .no
    mov  rax, [rax + INFO_ART]
    test rax, rax
    jz   .no
    mov  r10d, [rax + ART_W]           ; (ecx is A1 on Windows)
    mov  [A1], r10d
    mov  r10d, [rax + ART_H]
    mov  [A2], r10d
    mov  eax, 1
    RET_
.no:xor  eax, eax
    RET_

; core_target_size(screen_w, screen_h, cur_w, cur_h, out[2]) -> eax 1 if a
; resize is wanted. First cover: its own pixel size (fitted to 85% of the
; screen). After the user scales the window: keep their size, follow the
; new cover's shape.
FUNC core_target_size, 16
    ARGS r12, r13, r14, r15
    mov  rax, IN5
    mov  [L(0)], rax
    mov  rax, [cur_info]
    test rax, rax
    jz   .no
    mov  rbx, [rax + INFO_ART]
    test rbx, rbx
    jz   .no
    mov  esi, [rbx + ART_W]           ; w
    mov  edi, [rbx + ART_H]           ; h
    cmp  dword [user_sized], 0
    je   .fit
    mov  ecx, r14d                    ; L = longest side of the window
    cmp  ecx, r15d
    cmovb ecx, r15d
    cmp  esi, edi
    jb   .tall
    mov  eax, edi                     ; wide: w = L, h = L*ah/aw
    imul rax, rcx
    xor  edx, edx
    div  rsi
    mov  edi, eax
    mov  esi, ecx
    jmp  .fit
.tall:
    mov  eax, esi                     ; tall: h = L, w = L*aw/ah
    imul rax, rcx
    xor  edx, edx
    div  rdi
    mov  esi, eax
    mov  edi, ecx
.fit:
    ; ---- clamp to 85% of the screen
    mov  eax, r12d
    imul eax, 85
    xor  edx, edx
    mov  ecx, 100
    div  ecx
    mov  r8d, eax                     ; max w
    mov  eax, r13d
    imul eax, 85
    xor  edx, edx
    div  ecx
    mov  r9d, eax                     ; max h
    cmp  esi, r8d
    jbe  .cw
    mov  eax, edi
    imul rax, r8
    xor  edx, edx
    div  rsi
    mov  edi, eax
    mov  esi, r8d
.cw:cmp  edi, r9d
    jbe  .ch
    mov  eax, esi
    imul rax, r9
    xor  edx, edx
    div  rdi
    mov  esi, eax
    mov  edi, r9d
.ch:
    ; ---- small covers: grow to 320 on the long side (first fit only)
    cmp  dword [user_sized], 0
    jne  .min
    mov  eax, esi
    cmp  eax, edi
    cmovb eax, edi
    cmp  eax, 320
    jae  .min
    mov  r10d, eax                    ; long side
    mov  eax, esi
    imul eax, 320
    xor  edx, edx
    div  r10d
    mov  esi, eax
    mov  eax, edi
    imul eax, 320
    xor  edx, edx
    div  r10d
    mov  edi, eax
.min:
    cmp  esi, 32
    jae  .m1
    mov  esi, 32
.m1:cmp  edi, 32
    jae  .m2
    mov  edi, 32
.m2:mov  [exp_w], esi
    mov  [exp_h], edi
    mov  rax, [L(0)]
    mov  [rax], esi
    mov  [rax + 4], edi
    xor  eax, eax
    cmp  esi, r14d
    jne  .yes
    cmp  edi, r15d
    jne  .yes
    RET_
.yes:
    mov  eax, 1
    RET_
.no:xor  eax, eax
    RET_

; core_note_size(w, h): a size we didn't ask for means the user scaled
FUNC core_note_size, 0
    ARGS r12, r13
    cmp  dword [exp_w], 0
    je   .r
    mov  eax, r12d                    ; within 2 px of what we asked for:
    sub  eax, [exp_w]                 ; window managers round aspect sizes
    cdq
    xor  eax, edx
    sub  eax, edx
    cmp  eax, 2
    ja   .u
    mov  eax, r13d
    sub  eax, [exp_h]
    cdq
    xor  eax, edx
    sub  eax, edx
    cmp  eax, 2
    jbe  .r
.u: mov  dword [user_sized], 1
.r: RET_

; disp_pos() -> rax the position to show: where playback is plus any seek
; still queued for the player thread (cmd_seek), clamped to the track. The
; clock and bar then react to an arrow key in the same frame instead of
; waiting for the player to carry it out. Leaf: clobbers rax, rcx.
disp_pos:
    movsxd rax, dword [cmd_seek]
    mov  ecx, [st_rate]
    imul rax, rcx
    add  rax, [st_pos]
    jns  .p
    xor  eax, eax
.p: mov  rcx, [st_total]
    test rcx, rcx
    jz   .r
    cmp  rax, rcx
    cmova rax, rcx
.r: ret

; disp_secs() -> rax whole seconds shown on the clock. Leaf-ish: clobbers
; rax, rcx, rdx.
disp_secs:
    call disp_pos
    mov  ecx, [st_rate]
    test ecx, ecx
    jnz  .ok
    mov  ecx, 1
.ok:xor  edx, edx
    div  rcx
    ret

; core_tick_needed() -> eax 1 if a timer tick has anything new to draw. The
; clock only changes once a second, so most ticks need no redraw at all.
FUNC core_tick_needed, 0
    mov  eax, 1
    cmp  qword [dlg_until], 0          ; a notice is up: it may expire
    jne  .r
    call ui_alpha
    test eax, eax
    jnz  .vis
    cmp  dword [drawn_a], 0            ; controls just went away: one last
    jne  .yes                          ; frame to wipe them
    jmp  .no
.vis:
    cmp  eax, 256
    jb   .yes                          ; fading out: every frame counts
    call disp_secs
    cmp  rax, [last_sec]
    jne  .yes
.no:xor  eax, eax
    RET_
.yes:
    mov  eax, 1
.r: RET_

; core_set_fullscreen(on): entering or leaving fullscreen. The pointer is
; then over the window by definition, and counts as just moved.
FUNC core_set_fullscreen, 0
    ARGS r12
    mov  [fs_mode], r12d
    call plat_ms
    mov  [act_ms], rax
    test r12d, r12d
    jz   .r
    mov  dword [hover], 1
.r: RET_

; core_motion() -> eax 1 if the controls must be redrawn: the pointer moved.
; Only fullscreen cares: the controls come back at once, and the pointer shows.
FUNC core_motion, 0
    xor  ebx, ebx
    cmp  dword [fs_mode], 0
    je   .r
    call ui_alpha                      ; how visible they were
    cmp  dword [g_ui], 0
    je   .t
    cmp  dword [g_blank], 0
    jne  .t
    cmp  eax, 256
    setb bl                            ; faded or fading: they come back now
.t: call plat_ms
    mov  [act_ms], rax
    mov  dword [hover], 1
.r: mov  eax, ebx
    RET_

; core_cursor_hidden() -> eax 1 if the pointer should be hidden: fullscreen,
; and still long enough for the controls to have faded out (it goes with them).
FUNC core_cursor_hidden, 0
    xor  ebx, ebx
    cmp  dword [fs_mode], 0
    je   .r
    call plat_ms
    sub  rax, [act_ms]
    cmp  rax, IDLE_MS + FADE_MS
    setae bl
.r: mov  eax, ebx
    RET_

; core_hover(inside): the pointer entered (1) or left (0) the window.
; -> eax 1 if a redraw is needed
FUNC core_hover, 0
    ARGS r12
    cmp  r12d, [hover]
    je   .no
    mov  [hover], r12d
    test r12d, r12d
    jnz  .yes
    call plat_ms
    mov  [leave_ms], rax
.yes:
    xor  eax, eax
    cmp  dword [g_ui], 0
    setne al
    RET_
.no:xor  eax, eax
    RET_

; ui_alpha() -> eax overlay opacity 0..256: full while the pointer is over
; the window, then a FADE_MS fade-out after it leaves. 0 when Tab is off.
FADE_MS equ 500
IDLE_MS equ 2000                       ; fullscreen: pointer still this long, then fade
FUNC ui_alpha, 0
    xor  ebx, ebx
    cmp  dword [g_ui], 0
    je   .r
    cmp  dword [g_blank], 0
    jne  .r
    mov  ebx, 256
    cmp  dword [hover], 0
    jne  .held
    call plat_ms
    sub  rax, [leave_ms]               ; windowed: time since the pointer left
    jmp  .fade
.held:
    cmp  dword [fs_mode], 0
    je   .r                            ; windowed: shown while the pointer is over us
    call plat_ms
    sub  rax, [act_ms]
    sub  rax, IDLE_MS                  ; fullscreen: time since the pointer went still,
    jle  .r                            ; after the hold
.fade:
    xor  ebx, ebx
    cmp  rax, FADE_MS
    jae  .r
    mov  ecx, FADE_MS
    sub  rcx, rax                      ; time left
    shl  rcx, 8
    mov  rax, rcx
    xor  edx, edx
    mov  ecx, FADE_MS
    div  rcx
    mov  ebx, eax
.r: mov  eax, ebx
    RET_

; fade_overlay(): rc_buf = cache + (rc_buf - cache) * ui_a/256, the frame
; with controls blended back toward the bare cover. SSE2, 4 pixels a step.
FUNC fade_overlay, 0
    mov  eax, [ov_top]                 ; rows above it are the bare cover
    cmp  eax, [rc_h]
    jae  .r
    imul eax, [rc_w]
    shl  rax, 2
    mov  rdi, [rc_buf]
    mov  rsi, [cache_px]
    add  rdi, rax
    add  rsi, rax
    mov  ecx, [rc_h]
    sub  ecx, [ov_top]
    imul ecx, [rc_w]
    shl  rcx, 2                        ; bytes
    mov  eax, [ui_a]
    shr  eax, 1                        ; 0..128: products fit in a signed word
    mov  ebx, eax
    movd xmm5, eax
    pshuflw xmm5, xmm5, 0
    punpcklqdq xmm5, xmm5
    pxor xmm4, xmm4
.v: cmp  rcx, 16
    jb   .tail
    movdqu xmm0, [rdi]
    movdqu xmm1, [rsi]
    movdqa xmm2, xmm0
    punpcklbw xmm2, xmm4
    movdqa xmm3, xmm1
    punpcklbw xmm3, xmm4
    psubw xmm2, xmm3
    pmullw xmm2, xmm5
    psraw xmm2, 7
    paddw xmm2, xmm3
    punpckhbw xmm0, xmm4
    punpckhbw xmm1, xmm4
    psubw xmm0, xmm1
    pmullw xmm0, xmm5
    psraw xmm0, 7
    paddw xmm0, xmm1
    packuswb xmm2, xmm0
    movdqu [rdi], xmm2
    add  rdi, 16
    add  rsi, 16
    sub  rcx, 16
    jmp  .v
.tail:
    test rcx, rcx
    jz   .r
    movzx eax, byte [rdi]
    movzx edx, byte [rsi]
    sub  eax, edx
    imul eax, ebx
    sar  eax, 7
    add  eax, edx
    mov  [rdi], al
    inc  rdi
    inc  rsi
    dec  rcx
    jmp  .tail
.r: RET_

; core_next_wake() -> eax milliseconds until a redraw is due, -1 if none
FUNC core_next_wake, 0
    mov  ebx, -1
    cmp  qword [dlg_until], 0
    je   .ui
    call plat_ms
    mov  rcx, [dlg_until]
    sub  rcx, rax
    jg   .pos
    mov  ecx, 1
.pos:
    cmp  rcx, 10000
    jb   .s
    mov  ecx, 10000
.s: mov  ebx, ecx
.ui:cmp  dword [fs_mode], 0
    je   .ui2
    call plat_ms                       ; fullscreen: wake when the pointer is due
    mov  rcx, [act_ms]                 ; to hide, even if no controls are showing
    add  rcx, IDLE_MS + FADE_MS + 1
    sub  rcx, rax
    jle  .ui2
    cmp  ecx, ebx
    jae  .ui2
    mov  ebx, ecx
.ui2:
    call ui_alpha
    test eax, eax
    jz   .r
    cmp  eax, 256
    jb   .fade                         ; fading out, either way
    cmp  dword [hover], 0
    jne  .full
.fade:
    cmp  ebx, 16                       ; fading: ~60 frames a second
    jbe  .r
    mov  ebx, 16
    jmp  .r
.full:
    cmp  dword [fs_mode], 0
    je   .clk
    call plat_ms                       ; fullscreen: wake when the pointer has been
    mov  rcx, [act_ms]                 ; still long enough for the fade to start
    add  rcx, IDLE_MS + 1
    sub  rcx, rax
    jg   .f1
    mov  ecx, 1
.f1:cmp  ecx, ebx
    jae  .clk
    mov  ebx, ecx
.clk:
    ; The clock moves once a second: sleep until the next whole second,
    ; and not at all while paused or stopped.
    cmp  dword [st_count], 0
    je   .r
    cmp  dword [st_playing], 0
    je   .r
    cmp  dword [g_paused], 0
    jne  .r
    mov  ecx, [st_rate]
    test ecx, ecx
    jz   .r
    mov  rax, [st_pos]
    xor  edx, edx
    div  rcx                           ; rdx = frames into this second
    sub  rcx, rdx                      ; frames left in it
    imul rcx, 1000
    mov  rax, rcx
    xor  edx, edx
    mov  ecx, [st_rate]
    div  rcx
    add  eax, 4                        ; land just after the boundary
    cmp  eax, ebx
    jae  .r                            ; a notice expires sooner
    mov  ebx, eax
.r: mov  eax, ebx
    RET_

; ============================================================================
; fonts
; ============================================================================
%ifndef PURE
; glyph_get(cp, px) -> rax cache entry {cp, px, bitmap, w, h, xoff, yoff},
; 0 on failure. Rasterizing a glyph (stb_truetype) costs far more than
; drawing it, and the overlay redraws the same text many times a second.
FUNC glyph_get, 0
    ARGS r12, r13
    mov  eax, r12d
    imul eax, 31
    add  eax, r13d
    and  eax, GC_N - 1
    shl  eax, 5                        ; * GC_SZ
    lea  rbx, [gcache]
    add  rbx, rax
    cmp  [rbx], r12d
    jne  .miss
    cmp  [rbx + 4], r13d
    je   .hit
.miss:
    mov  A1, [rbx + 8]                 ; evict
    test A1, A1
    jz   .e
    call font_glyph_free
.e: mov  qword [rbx + 8], 0
    mov  dword [rbx], 0
    mov  A1, [font_h]
    mov  A2d, r12d
    mov  A3d, r13d
    lea  A4, [rbx + 16]                ; w, h, xoff, yoff
    call font_glyph
    mov  [rbx + 8], rax                ; may be 0: a glyph with no pixels
    mov  [rbx], r12d
    mov  [rbx + 4], r13d
.hit:
    mov  rax, rbx
    RET_

; glyph_flush(): forget every cached glyph (the font changed)
FUNC glyph_flush, 0
    lea  rbx, [gcache]
    lea  r12, [rbx + GC_N * GC_SZ]
.l: cmp  rbx, r12
    jae  .r
    mov  A1, [rbx + 8]
    test A1, A1
    jz   .n
    call font_glyph_free
.n: mov  qword [rbx + 8], 0
    mov  dword [rbx], 0
    add  rbx, GC_SZ
    jmp  .l
.r: RET_
%endif

FUNC unload_font, 0
%ifndef PURE
    call glyph_flush
    mov  A1, [font_h]
    test A1, A1
    jz   .m
    call font_free
    mov  qword [font_h], 0
%endif
.m: mov  A1, [font_map]
    test A1, A1
    jz   .r
    mov  A2, [font_mlen]
    call plat_unmap
    mov  qword [font_map], 0
.r: RET_

; gfx_font_cycle(): F — rescan the fonts folder, move to the next font
FUNC gfx_font_cycle, 0
    mov  byte [dlg2], 0
    lea  A1, [dlg1]
    lea  A2, [s_fontpfx]
    call s_cat
    mov  rbx, rax                     ; where the name goes
%ifdef PURE
    mov  A1, rbx
    lea  A2, [s_default]
    call s_cat
    lea  A1, [dlg2]
    lea  A2, [s_nofonts]
    call s_cat
    jmp  .show
%else
    call core_list_new
    test rax, rax
    jz   .r
    mov  r12, rax
    mov  A1, r12
    call plat_font_scan
    mov  A1, r12
    call core_list_sort
    mov  A1, [font_list]
    call core_list_free
    mov  [font_list], r12
    call unload_font
    ; next index, wrapping through "Default" (0)
    mov  eax, [font_idx]
    inc  eax
    mov  rcx, [r12 + PL_COUNT]
    cmp  rax, rcx
    jbe  .ix
    xor  eax, eax
.ix:mov  [font_idx], eax
    test eax, eax
    jnz  .load
    mov  A1, rbx
    lea  A2, [s_default]
    call s_cat
    cmp  qword [r12 + PL_COUNT], 0
    jne  .show
    lea  A1, [dlg2]                   ; no fonts yet: say where they go
    lea  A2, [s_hint]
    call s_cat
    mov  A1, rax
    mov  A2, 500
    mov  A3, 1                        ; short form for display
    call plat_font_dir
    jmp  .show
.load:
    dec  eax
    mov  rcx, [r12 + PL_ITEMS]
    mov  r13, [rcx + rax*8]           ; path
    mov  A1, r13
    mov  A2, rbx
    mov  A3, 200
    call plat_title                   ; display name = file name
    mov  A1, r13
    lea  A2, [font_mlen]
    call plat_map
    test rax, rax
    jz   .bad
    mov  [font_map], rax
    mov  A1, rax
    mov  A2, [font_mlen]
    call font_load
    test rax, rax
    jz   .bad
    mov  [font_h], rax
    jmp  .show
.bad:
    call unload_font
    mov  A1, rbx
    call s_end
    mov  A1, rax
    lea  A2, [s_bad]
    call s_cat
%endif
.show:
    call plat_ms
    add  rax, 2200
    cmp  byte [dlg2], 0
    je   .t
    add  rax, 2300
.t: mov  [dlg_until], rax
.r: RET_

; gfx_show_version(): V — "Peep X.Y.Z" in the notice box for 2 s. No timer of
; its own: the box expires through core_next_wake like any notice, so this
; costs two frames (now, and when it goes) and nothing in between.
FUNC gfx_show_version, 0
    mov  byte [dlg2], 0                ; one line
    lea  A1, [dlg1]
    lea  A2, [s_version]
    call s_cat
    call plat_ms
    add  rax, 2000
    mov  [dlg_until], rax
    RET_

FUNC s_end, 0                          ; (str) -> pointer to its NUL
    mov  rax, A1
.l: cmp  byte [rax], 0
    je   .r
    inc  rax
    jmp  .l
.r: RET_

%ifndef WIN64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
