; ============================================================================
; Peep — Wayland window (the Wayland build; the X11 one is in linux.asm)
;   speaks the Wayland wire protocol straight over the compositor's socket:
;   no libwayland, no libxkbcommon, no X11
;   xdg-shell window on shared-memory buffers, pointer, keyboard (own key
;   repeat, letters found in the compositor's keymap), drag & drop
;   (text/uri-list), fullscreen, hidden pointer, move and edge resize
;   Audio, files and threads are the shared half of linux.asm (-DWAYLAND).
; ============================================================================
default rel
%include "abi.inc"

extern core_key, core_render, g_quit
extern core_take_info, core_target_size, core_note_size, core_art_aspect
extern core_next_wake, core_click, core_hover, core_tick_needed
extern core_set_fullscreen, core_motion, core_cursor_hidden
extern start_player, parse_uris, wake_fd, wake_buf, plat_ms, drop_append
extern socket, connect, sendmsg, recvmsg, memfd_create, ftruncate, mmap, munmap
extern poll, read, write, close, getenv, pipe2, malloc, free, memmove, _exit

global main

START_SIZE  equ 480                    ; opens as a square
FIRST_WAIT  equ 300                    ; ms to wait for the first cover
OUTMAX      equ 4096
INMAX       equ 8192
NBUF        equ 6                      ; window buffers alive at once
BUF_SZ      equ 24                     ; id, w, h, busy, ptr
EDGE        equ 6                      ; px at the border that resize (undecorated)
DROPMAX     equ 1 << 20
BTN_LEFT    equ 0x110

; WL obj, opcode, args...: one request whose arguments are all 32-bit words.
; Arguments must be memory, immediates or callee-saved registers.
%macro WL 2-*
    mov  A1d, %1
    mov  A2d, %2
    call wl_begin
    %rotate 2
    %rep %0 - 2
    mov  A1d, %1
    call wl_u32
    %rotate 1
    %endrep
    call wl_end
%endmacro

section .data
align 8
; interface, highest version we speak, where its object id goes
ifaces:
    dq i_comp, 4, o_comp
    dq i_shm, 1, o_shm
    dq i_wm, 2, o_wm
    dq i_seat, 5, o_seat
    dq i_ddm, 1, o_ddm
    dq i_out, 2, o_out
%ifndef BARE                           ; (BARE: a test build that ignores these two,
    dq i_decom, 1, o_decom             ; to stand in for a compositor without them)
    dq i_csm, 1, o_csm
%endif
    dq 0
i_comp      db "wl_compositor", 0
i_shm       db "wl_shm", 0
i_wm        db "xdg_wm_base", 0
i_seat      db "wl_seat", 0
i_ddm       db "wl_data_device_manager", 0
i_out       db "wl_output", 0
i_decom     db "zxdg_decoration_manager_v1", 0
i_csm       db "wp_cursor_shape_manager_v1", 0
s_wd        db "WAYLAND_DISPLAY", 0
s_xrd       db "XDG_RUNTIME_DIR", 0
s_wl0       db "wayland-0", 0
s_uri       db "text/uri-list", 0
s_title     db "Peep", 0
s_appid     db "peep", 0
s_nodisp    db "peep: cannot connect to a Wayland display", 10
s_nodisp_l  equ $ - s_nodisp
s_nl        db 10

; the keys Peep knows, by the name the keymap gives them (as XLookupKeysym
; does on X11), what each does, and where it is when there is no keymap (QWERTY)
NKEYS       equ 17
knames      db "space", 0, "Left", 0, "Right", 0, "Up", 0, "Down", 0, "Next", 0, "Prior", 0
            db "Tab", 0, "Escape", 0, "n", 0, "p", 0, "g", 0, "v", 0, "f", 0, "q", 0, "j", 0, "h", 0
kact        db K_PAUSE, K_SEEKBACK, K_SEEKFWD, K_VOLUP, K_VOLDN, K_NEXT, K_PREV
            db KX_TAB, KX_ESC, K_NEXT, K_PREV, K_FONT, K_VERSION, KX_FS, KX_QUIT
            db K_FONTUP, K_FONTDN
kdef        dw 57, 105, 106, 103, 108, 109, 104, 15, 1, 49, 25, 34, 47, 33, 16, 36, 35
KX_TAB      equ 100
KX_ESC      equ 101
KX_FS       equ 102
KX_QUIT     equ 103
; resize edges (1 top, 2 bottom, 4 left, 8 right) -> wp_cursor_shape name
edge_shape  db 1, 19, 22, 1, 25, 21, 24, 1, 18, 20, 23, 1, 1, 1, 1, 1
; the pointer drawn when the compositor has no cursor-shape protocol:
; 16 rows of (outline, fill), bit 0 is the left pixel
arrow:
    dw 0x0001, 0x0000, 0x0003, 0x0000, 0x0005, 0x0002, 0x0009, 0x0006
    dw 0x0011, 0x000e, 0x0021, 0x001e, 0x0041, 0x003e, 0x0081, 0x007e
    dw 0x0101, 0x00fe, 0x0201, 0x01fe, 0x07c1, 0x003e, 0x0049, 0x0036
    dw 0x0095, 0x0062, 0x0093, 0x0060, 0x0121, 0x00c0, 0x00c0, 0x0000

section .bss
alignb 8
wfd         resd 1
out_len     resd 1
out_fd      resd 1                     ; fd + 1 to send with the next flush
msg_at      resd 1
in_len      resd 1
next_id     resd 1
nfree       resd 1
nfds        resd 1
freeids     resd 64
fdq         resd 16
; object ids (0: none)
o_comp      resd 1
o_shm       resd 1
o_wm        resd 1
o_seat      resd 1
o_ddm       resd 1
o_out       resd 1
o_decom     resd 1
o_csm       resd 1
o_surf      resd 1
o_xsurf     resd 1
o_top       resd 1
o_deco      resd 1
o_ptr       resd 1
o_kbd       resd 1
o_dd        resd 1
o_csdev     resd 1
o_csurf     resd 1
o_frame     resd 1                     ; frame callback we are waiting for
o_sync      resd 1
new_offer   resd 1                     ; the offer being described
offer_ok    resd 1                     ; ... has text/uri-list
dnd_offer   resd 1                     ; the offer over the window
dnd_ok      resd 1
fb_w        resd 1
fb_h        resd 1
win_w       resd 1                     ; size when not fullscreen / maximized
win_h       resd 1
scr_w       resd 1
scr_h       resd 1
pend_w      resd 1                     ; from xdg_toplevel.configure, applied on
pend_h      resd 1                     ; xdg_surface.configure
pend_fs     resd 1
pend_exact  resd 1
fullscreen  resd 1
exact       resd 1                     ; fullscreen, maximized or tiled: size is not ours
ssd         resd 1                     ; the compositor draws a title bar and borders
configured  resd 1
dirty       resd 1
px          resd 1
py          resd 1
ptr_serial  resd 1
cur_shape   resd 1                     ; -1 unknown, 0 hidden, else shape shown
moving      resd 1                     ; the compositor is dragging the window
shift       resd 1
rep_key     resd 1
rep_rate    resd 1
rep_delay   resd 1
rep_at      resq 1
kcode       resw NKEYS + 1             ; evdev code of each key in knames
shm_pool    resd 1
shm_buf     resd 1
shm_stride  resd 1
shm_ptr     resq 1
art_asp       resd 2
tsz         resd 2
bufs        resb NBUF * BUF_SZ
pfds        resq 2
iov         resq 2
msg         resq 7
cmsg        resb 256
addr        resb 112
outbuf      resb OUTMAX
inbuf       resb INMAX

section .text

; ============================================================================
; main
; ============================================================================
FUNC main, 0
    ARGS r12, r13                      ; argc, argv
    mov  A1, r12
    mov  A2, r13
    call start_player
    call wl_connect
    test eax, eax
    jnz  .up
.fail:
    mov  A1, 2
    lea  A2, [s_nodisp]
    mov  A3, s_nodisp_l
    call write
    mov  A1, 1
    call _exit
.up:
    mov  dword [next_id], 3
    mov  dword [win_w], START_SIZE
    mov  dword [win_h], START_SIZE
    mov  dword [fb_w], START_SIZE
    mov  dword [fb_h], START_SIZE
    mov  dword [scr_w], 1920
    mov  dword [scr_h], 1080
    mov  dword [rep_rate], 25
    mov  dword [rep_delay], 600
    mov  dword [cur_shape], -1
    lea  A1, [inbuf]                   ; no keymap yet: QWERTY
    xor  A2, A2
    call xkb_parse
    WL   1, 1, 2                       ; wl_display.get_registry
    call wl_roundtrip                  ; the globals; binds them
    cmp  dword [o_comp], 0
    je   .fail
    cmp  dword [o_shm], 0
    je   .fail
    cmp  dword [o_wm], 0
    je   .fail
    call wl_roundtrip                  ; seat capabilities, screen size
    ; the window
    call wl_id
    mov  [o_surf], eax
    WL   [o_comp], 0, [o_surf]         ; create_surface
    call wl_id
    mov  [o_xsurf], eax
    WL   [o_wm], 2, [o_xsurf], [o_surf]
    call wl_id
    mov  [o_top], eax
    WL   [o_xsurf], 1, [o_top]         ; get_toplevel
    mov  A1d, [o_top]
    mov  A2d, 2                        ; set_title
    call wl_begin
    lea  A1, [s_title]
    call wl_str
    call wl_end
    mov  A1d, [o_top]
    mov  A2d, 3                        ; set_app_id
    call wl_begin
    lea  A1, [s_appid]
    call wl_str
    call wl_end
    ; ask for a title bar and borders where the compositor offers them
    cmp  dword [o_decom], 0
    je   .nodeco
    call wl_id
    mov  [o_deco], eax
    WL   [o_decom], 1, [o_deco], [o_top]
    WL   [o_deco], 1, 2                ; set_mode(server_side)
.nodeco:
    cmp  dword [o_ddm], 0
    je   .nodd
    cmp  dword [o_seat], 0
    je   .nodd
    call wl_id
    mov  [o_dd], eax
    WL   [o_ddm], 1, [o_dd], [o_seat]  ; get_data_device
.nodd:
    WL   [o_surf], 6                   ; commit: the compositor answers with a configure
    call wl_flush
    ; Opened with files: wait (at most FIRST_WAIT ms) for the first track's
    ; cover, so the window appears at its size and shape with the cover in it.
    cmp  r12d, 2
    jb   .loop
    call plat_ms
    lea  r14, [rax + FIRST_WAIT]
.first:
    call core_take_info
    test eax, eax
    jz   .fwait
    call wl_apply_size
    jmp  .loop
.fwait:
    call plat_ms
    mov  rbx, r14
    sub  rbx, rax
    jle  .loop
    mov  eax, [wake_fd]
    mov  dword [pfds], eax
    mov  dword [pfds + 4], 1           ; POLLIN
    lea  A1, [pfds]
    mov  A2, 1
    mov  A3, rbx
    call poll
.fdrain:
    mov  A1d, [wake_fd]
    lea  A2, [wake_buf]
    mov  A3, 64
    call read
    test rax, rax
    jg   .fdrain
    jmp  .first

; ---------------------------------------------------------------- main loop
.loop:
    cmp  dword [g_quit], 0
    jne  .quit
    call core_take_info                ; new track: maybe new art / size
    test eax, eax
    jz   .noinfo
    call wl_apply_size
    mov  dword [dirty], 1
.noinfo:
    cmp  dword [dirty], 0
    je   .wait
    call wl_present                    ; waits its turn: one frame per screen refresh
.wait:
    call wl_flush
    mov  eax, [wfd]
    mov  dword [pfds], eax
    mov  dword [pfds + 4], 1           ; POLLIN
    mov  eax, [wake_fd]
    mov  dword [pfds + 8], eax
    mov  dword [pfds + 12], 1
    call core_next_wake                ; -1: sleep until something happens
    mov  ebx, eax
    cmp  dword [rep_key], 0            ; a held key: wake for its next repeat
    je   .poll
    call plat_ms
    mov  rcx, [rep_at]
    sub  rcx, rax
    jg   .rp
    xor  ecx, ecx
.rp:test ebx, ebx
    js   .ru
    cmp  ecx, ebx
    jae  .poll
.ru:mov  ebx, ecx
.poll:
    lea  A1, [pfds]
    mov  A2, 2
    movsxd A3, ebx
    call poll
    mov  ebx, eax
    call wl_cursor                     ; fullscreen: maybe it is time to hide the pointer
    test ebx, ebx
    jnz  .woke
    call core_tick_needed              ; timer tick: redraw only if it shows
    or   [dirty], eax                  ; something new
.woke:
    cmp  dword [rep_key], 0
    je   .drain
    call plat_ms
    cmp  rax, [rep_at]
    jb   .drain
    mov  rbx, rax
    mov  eax, 1000
    xor  edx, edx
    div  dword [rep_rate]
    add  rbx, rax
    mov  [rep_at], rbx
    mov  A1d, [rep_key]
    call wl_key
.drain:
    mov  A1d, [wake_fd]                ; drain the wake pipe
    lea  A2, [wake_buf]
    mov  A3, 64
    call read
    test rax, rax
    jle  .sock
    mov  dword [dirty], 1              ; the player poked us: redraw now
    jmp  .drain
.sock:
    test word [pfds + 6], 0x19         ; POLLIN | POLLERR | POLLHUP
    jz   .loop
    call wl_read
    jmp  .loop
.quit:
    xor  A1, A1
    call _exit

; ============================================================================
; the wire
; ============================================================================
; wl_connect() -> eax 1 if connected: $WAYLAND_DISPLAY (default wayland-0),
; a path or a name in $XDG_RUNTIME_DIR
FUNC wl_connect, 0
    lea  A1, [s_wd]
    call getenv
    lea  rbx, [s_wl0]
    test rax, rax
    jz   .name
    cmp  byte [rax], 0
    je   .name
    mov  rbx, rax
.name:
    mov  word [addr], 1                ; AF_UNIX
    lea  r12, [addr + 2]
    lea  r13, [addr + 2 + 107]
    cmp  byte [rbx], '/'
    je   .copy
    lea  A1, [s_xrd]
    call getenv
    test rax, rax
    jz   .no
.dir:
    mov  cl, [rax]
    test cl, cl
    jz   .slash
    cmp  r12, r13
    jae  .no
    mov  [r12], cl
    inc  r12
    inc  rax
    jmp  .dir
.slash:
    cmp  r12, r13
    jae  .no
    mov  byte [r12], '/'
    inc  r12
.copy:
    mov  cl, [rbx]
    cmp  r12, r13
    jae  .no
    mov  [r12], cl
    inc  r12
    inc  rbx
    test cl, cl
    jnz  .copy
    mov  A1d, 1                        ; AF_UNIX
    mov  A2d, 0x80001                  ; SOCK_STREAM | SOCK_CLOEXEC
    xor  A3d, A3d
    call socket
    test eax, eax
    js   .no
    mov  [wfd], eax
    mov  A1d, eax
    lea  A2, [addr]
    mov  A3d, 110
    call connect
    test eax, eax
    jnz  .no
    mov  eax, 1
    RET_
.no:xor  eax, eax
    RET_

; wl_id() -> eax a free object id: one the compositor gave back, else the next. Leaf.
wl_id:
    mov  eax, [nfree]
    test eax, eax
    jz   .n
    dec  eax
    mov  [nfree], eax
    lea  r10, [freeids]
    mov  eax, [r10 + rax*4]
    ret
.n: mov  eax, [next_id]
    inc  dword [next_id]
    ret

; wl_begin(object, opcode): start a request
FUNC wl_begin, 0
    ARGS rbx, r12
    cmp  dword [out_len], OUTMAX - 512
    jb   .ok
    call wl_flush
.ok:mov  eax, [out_len]
    mov  [msg_at], eax
    lea  rcx, [outbuf]
    mov  [rcx + rax], ebx
    mov  [rcx + rax + 4], r12d
    add  eax, 8
    mov  [out_len], eax
    RET_

; wl_u32(value): append a word. Leaf.
wl_u32:
    mov  eax, [out_len]
    lea  r10, [outbuf]
    mov  [r10 + rax], A1d
    add  eax, 4
    mov  [out_len], eax
    ret

; wl_str(ptr): append a string (0: the null string)
FUNC wl_str, 0
    ARGS rbx
    mov  eax, [out_len]
    lea  rdi, [outbuf]
    add  rdi, rax
    xor  ecx, ecx
    test rbx, rbx
    jz   .d
.c: mov  al, [rbx + rcx]
    mov  [rdi + 4 + rcx], al
    inc  ecx
    test al, al
    jnz  .c
.d: mov  [rdi], ecx                    ; length with the NUL
.p: test ecx, 3
    jz   .e
    mov  byte [rdi + 4 + rcx], 0
    inc  ecx
    jmp  .p
.e: add  ecx, 4
    add  [out_len], ecx
    RET_

; wl_end(): finish the request; one that carries an fd is sent at once. Leaf.
wl_end:
    mov  eax, [out_len]
    mov  ecx, [msg_at]
    sub  eax, ecx
    shl  eax, 16
    lea  r10, [outbuf]
    or   [r10 + rcx + 4], eax
    cmp  dword [out_fd], 0
    jne  wl_flush
    ret

; wl_flush(): send what is queued
FUNC wl_flush, 0
    xor  ebx, ebx                      ; sent so far
.l: mov  eax, [out_len]
    sub  eax, ebx
    jle  .done
    lea  rcx, [outbuf]
    add  rcx, rbx
    mov  [iov], rcx
    mov  [iov + 8], rax
    lea  rdi, [msg]
    xor  eax, eax
    mov  ecx, 7
    rep  stosq
    lea  rax, [iov]
    mov  [msg + 16], rax
    mov  qword [msg + 24], 1
    mov  eax, [out_fd]
    test eax, eax
    jz   .send
    dec  eax
    mov  qword [cmsg], 20              ; cmsg_len
    mov  dword [cmsg + 8], 1           ; SOL_SOCKET
    mov  dword [cmsg + 12], 1          ; SCM_RIGHTS
    mov  [cmsg + 16], eax
    lea  rax, [cmsg]
    mov  [msg + 32], rax
    mov  qword [msg + 40], 24
.send:
    mov  A1d, [wfd]
    lea  A2, [msg]
    mov  A3d, 0x4000                   ; MSG_NOSIGNAL
    call sendmsg
    test rax, rax
    jle  wl_die
    add  ebx, eax
    mov  dword [out_fd], 0
    jmp  .l
.done:
    mov  dword [out_len], 0
    RET_

wl_die:                                ; the compositor is gone
    mov  A1, 1
    call _exit

; wl_read(): read what the compositor sent and handle every whole event
FUNC wl_read, 0
    mov  eax, [in_len]
    lea  rcx, [inbuf]
    add  rcx, rax
    mov  [iov], rcx
    mov  ecx, INMAX
    sub  ecx, eax
    mov  [iov + 8], rcx
    lea  rdi, [msg]
    xor  eax, eax
    mov  ecx, 7
    rep  stosq
    lea  rax, [iov]
    mov  [msg + 16], rax
    mov  qword [msg + 24], 1
    lea  rax, [cmsg]
    mov  [msg + 32], rax
    mov  qword [msg + 40], 256
    mov  A1d, [wfd]
    lea  A2, [msg]
    mov  A3d, 0x40000000               ; MSG_CMSG_CLOEXEC
    call recvmsg
    test rax, rax
    jle  wl_die
    add  [in_len], eax
    ; file descriptors that came with it
    lea  rsi, [cmsg]
    mov  rdi, rsi
    add  rdi, [msg + 40]
.cm:lea  rax, [rsi + 16]
    cmp  rax, rdi
    ja   .ev
    mov  rcx, [rsi]                    ; cmsg_len
    cmp  rcx, 16
    jb   .ev
    cmp  dword [rsi + 8], 1
    jne  .cn
    cmp  dword [rsi + 12], 1
    jne  .cn
    lea  rdx, [rsi + 16]
    lea  r8, [rsi + rcx]
.fd:lea  rax, [rdx + 4]
    cmp  rax, r8
    ja   .cn
    mov  eax, [nfds]
    cmp  eax, 16
    jae  .cn
    mov  r9d, [rdx]
    lea  r10, [fdq]
    mov  [r10 + rax*4], r9d
    inc  dword [nfds]
    add  rdx, 4
    jmp  .fd
.cn:add  rcx, 7
    and  rcx, ~7
    add  rsi, rcx
    jmp  .cm
.ev:xor  r12d, r12d                    ; offset
.e: mov  eax, [in_len]
    sub  eax, r12d
    cmp  eax, 8
    jb   .rest
    lea  rbx, [inbuf]
    add  rbx, r12
    movzx ecx, word [rbx + 6]          ; size
    cmp  ecx, 8
    jb   wl_die
    cmp  eax, ecx
    jb   .rest
    add  r12d, ecx
    mov  A1, rbx
    call wl_event
    jmp  .e
.rest:
    mov  [in_len], eax
    test r12d, r12d
    jz   .r
    lea  A1, [inbuf]
    lea  A2, [inbuf]
    add  A2, r12
    mov  A3d, eax
    call memmove
.r: RET_

; wl_roundtrip(): wait until the compositor has handled everything sent so far
FUNC wl_roundtrip, 0
    call wl_id
    mov  [o_sync], eax
    WL   1, 0, [o_sync]                ; wl_display.sync
    call wl_flush
.l: cmp  dword [o_sync], 0
    je   .r
    call wl_read
    jmp  .l
.r: RET_

; fd_pop() -> eax the next fd the compositor sent, -1 if none. Leaf.
fd_pop:
    mov  eax, -1
    cmp  dword [nfds], 0
    je   .r
    lea  r10, [fdq]
    mov  eax, [r10]
    dec  dword [nfds]
    xor  ecx, ecx
.s: cmp  ecx, [nfds]
    jae  .r
    mov  edx, [r10 + rcx*4 + 4]
    mov  [r10 + rcx*4], edx
    inc  ecx
    jmp  .s
.r: ret

; ============================================================================
; events
; ============================================================================
FUNC wl_event, 0
    ARGS rbx                           ; the message: sender, size<<16 | opcode, arguments
    mov  r13d, [rbx]
    movzx r12d, word [rbx + 4]
    cmp  r13d, 1
    je   .display
    cmp  r13d, 2
    je   .registry
    cmp  r13d, [o_ptr]
    je   .ptr
    cmp  r13d, [o_kbd]
    je   .kbd
    cmp  r13d, [o_frame]
    je   .frame
    cmp  r13d, [o_xsurf]
    je   .xsurf
    cmp  r13d, [o_top]
    je   .top
    cmp  r13d, [o_wm]
    je   .wm
    cmp  r13d, [o_sync]
    je   .sync
    cmp  r13d, [o_seat]
    je   .seat
    cmp  r13d, [o_out]
    je   .output
    cmp  r13d, [o_deco]
    je   .deco
    cmp  r13d, [o_dd]
    je   .dd
    cmp  r13d, [new_offer]
    je   .offer
    test r12d, r12d                    ; wl_buffer.release: it is ours again
    jnz  .r
    lea  rsi, [bufs]
    mov  ecx, NBUF
.b: cmp  r13d, [rsi]
    jne  .bn
    mov  dword [rsi + 12], 0
    RET_
.bn:add  rsi, BUF_SZ
    dec  ecx
    jnz  .b
.r: RET_

.display:
    test r12d, r12d
    jz   .err
    mov  eax, [nfree]                  ; delete_id: the id can be used again
    cmp  eax, 64
    jae  .r
    mov  ecx, [rbx + 8]
    lea  r10, [freeids]
    mov  [r10 + rax*4], ecx
    inc  dword [nfree]
    RET_
.err:                                  ; protocol error: say what the compositor said
    mov  A1, 2
    lea  A2, [rbx + 20]
    mov  A3d, [rbx + 16]
    call write
    mov  A1, 2
    lea  A2, [s_nl]
    mov  A3, 1
    call write
    jmp  wl_die

.sync:
    mov  dword [o_sync], 0
    RET_
.frame:
    mov  dword [o_frame], 0
    RET_

.registry:                             ; global(name, interface, version)
    test r12d, r12d
    jnz  .r
    lea  r14, [ifaces]
.g: mov  rsi, [r14]
    test rsi, rsi
    jz   .r
    lea  rdi, [rbx + 16]
.gc:mov  al, [rsi]
    cmp  al, [rdi]
    jne  .gn
    inc  rsi
    inc  rdi
    test al, al
    jnz  .gc
    mov  r15, [r14 + 16]
    cmp  dword [r15], 0                ; the first of its kind is enough
    jne  .r
    mov  eax, [rbx + 12]
    add  eax, 3
    and  eax, ~3
    mov  r12d, [rbx + 16 + rax]        ; its version
    cmp  r12d, [r14 + 8]
    jbe  .gv
    mov  r12d, [r14 + 8]
.gv:call wl_id
    mov  [r15], eax
    mov  A1d, 2
    xor  A2d, A2d                      ; wl_registry.bind
    call wl_begin
    mov  A1d, [rbx + 8]
    call wl_u32
    mov  A1, [r14]
    call wl_str
    mov  A1d, r12d
    call wl_u32
    mov  A1d, [r15]
    call wl_u32
    call wl_end
    RET_
.gn:add  r14, 24
    jmp  .g

.seat:                                 ; capabilities
    test r12d, r12d
    jnz  .r
    mov  r14d, [rbx + 8]
    test r14d, 1
    jz   .sk
    cmp  dword [o_ptr], 0
    jne  .sk
    call wl_id
    mov  [o_ptr], eax
    WL   [o_seat], 0, [o_ptr]          ; get_pointer
    cmp  dword [o_csm], 0
    je   .sk
    call wl_id
    mov  [o_csdev], eax
    WL   [o_csm], 1, [o_csdev], [o_ptr]
.sk:test r14d, 2
    jz   .r
    cmp  dword [o_kbd], 0
    jne  .r
    call wl_id
    mov  [o_kbd], eax
    WL   [o_seat], 1, [o_kbd]          ; get_keyboard
    RET_

.output:                               ; mode(flags, w, h, refresh)
    cmp  r12d, 1
    jne  .r
    test dword [rbx + 8], 1            ; the current one
    jz   .r
    mov  eax, [rbx + 12]
    mov  [scr_w], eax
    mov  eax, [rbx + 16]
    mov  [scr_h], eax
    RET_

.deco:                                 ; configure(mode)
    test r12d, r12d
    jnz  .r
    xor  eax, eax
    cmp  dword [rbx + 8], 2
    sete al
    mov  [ssd], eax
    RET_

.wm:                                   ; ping
    test r12d, r12d
    jnz  .r
    WL   [o_wm], 3, [rbx + 8]          ; pong
    RET_

.top:
    cmp  r12d, 1
    je   .close
    ja   .r
    mov  eax, [rbx + 8]                ; configure(w, h, states)
    mov  [pend_w], eax
    mov  eax, [rbx + 12]
    mov  [pend_h], eax
    xor  edx, edx                      ; fullscreen
    xor  esi, esi                      ; size is the compositor's
    mov  ecx, [rbx + 16]
    shr  ecx, 2
    lea  rdi, [rbx + 20]
.st:test ecx, ecx
    jz   .std
    mov  eax, [rdi]
    cmp  eax, 2
    jne  .s1
    mov  edx, 1
    mov  esi, 1
.s1:cmp  eax, 1                        ; maximized
    je   .s2
    cmp  eax, 5                        ; tiled left, right, top, bottom
    jb   .s3
    cmp  eax, 8
    ja   .s3
.s2:mov  esi, 1
.s3:add  rdi, 4
    dec  ecx
    jmp  .st
.std:
    mov  [pend_fs], edx
    mov  [pend_exact], esi
    RET_
.close:
    mov  dword [g_quit], 1
    RET_

.xsurf:                                ; configure(serial): the size is settled
    test r12d, r12d
    jnz  .r
    WL   [o_xsurf], 4, [rbx + 8]       ; ack_configure
    call wl_configure
    RET_

.ptr:
    cmp  r12d, 3
    je   .button
    cmp  r12d, 2
    je   .motion
    cmp  r12d, 1
    je   .leave
    ja   .r
    mov  eax, [rbx + 12]               ; enter(serial, surface, x, y)
    cmp  eax, [o_surf]
    jne  .r
    mov  eax, [rbx + 8]
    mov  [ptr_serial], eax
    mov  eax, [rbx + 16]
    sar  eax, 8
    mov  [px], eax
    mov  eax, [rbx + 20]
    sar  eax, 8
    mov  [py], eax
    mov  dword [cur_shape], -1         ; the pointer's look is ours to set again
    mov  dword [moving], 0
    call wl_cursor
    cmp  dword [fullscreen], 0         ; fullscreen: always under the pointer
    jne  .r
    mov  A1, 1
    call core_hover
    or   [dirty], eax
    RET_
.leave:
    ; the compositor taking the pointer to move the window is not the
    ; pointer leaving; the matching enter arrives when the move ends
    cmp  dword [moving], 0
    jne  .r
    cmp  dword [fullscreen], 0
    jne  .r
    xor  A1, A1
    call core_hover
    or   [dirty], eax
    RET_
.motion:                               ; (time, x, y)
    mov  eax, [rbx + 12]
    sar  eax, 8
    mov  [px], eax
    mov  eax, [rbx + 16]
    sar  eax, 8
    mov  [py], eax
    cmp  dword [fullscreen], 0
    je   .mc
    call core_motion                   ; the controls come back, the pointer shows
    or   [dirty], eax
.mc:call wl_cursor
    RET_
.button:                               ; (serial, time, button, state)
    cmp  dword [rbx + 16], BTN_LEFT
    jne  .r
    cmp  dword [rbx + 20], 1
    jne  .r
    call edge_at
    test eax, eax
    jz   .click
    mov  r14d, eax
    WL   [o_top], 6, [o_seat], [rbx + 8], r14d   ; resize from that edge
    RET_
.click:
    mov  A1d, [px]
    mov  A2d, [py]
    call core_click
    or   [dirty], eax
    test eax, eax
    jnz  .r
    cmp  dword [fullscreen], 0
    jne  .r
    mov  dword [moving], 1             ; not on a control: drag the window
    WL   [o_top], 5, [o_seat], [rbx + 8]
    RET_

.kbd:
    cmp  r12d, 0
    je   .keymap
    cmp  r12d, 2
    je   .kleave
    cmp  r12d, 3
    je   .key
    cmp  r12d, 4
    je   .mods
    cmp  r12d, 5
    jne  .r
    mov  eax, [rbx + 8]                ; repeat_info(rate, delay)
    mov  [rep_rate], eax
    mov  ecx, [rbx + 12]
    mov  [rep_delay], ecx
    test eax, eax
    jnz  .r
.kleave:
    mov  dword [rep_key], 0
    RET_
.mods:                                 ; (serial, depressed, latched, locked, group)
    mov  eax, [rbx + 12]
    or   eax, [rbx + 16]
    and  eax, 1                        ; Shift
    mov  [shift], eax
    RET_
.key:                                  ; (serial, time, key, state)
    mov  r14d, [rbx + 16]
    cmp  dword [rbx + 20], 1
    je   .kdown
    cmp  r14d, [rep_key]
    jne  .r
    mov  dword [rep_key], 0
    RET_
.kdown:
    mov  dword [rep_key], 0
    mov  A1d, r14d
    call wl_key
    test eax, eax                      ; held: repeat it, as the X server would
    jz   .r
    cmp  dword [rep_rate], 0
    je   .r
    call plat_ms
    mov  ecx, [rep_delay]
    add  rax, rcx
    mov  [rep_at], rax
    mov  [rep_key], r14d
    RET_
.keymap:                               ; (format, fd, size)
    call fd_pop
    mov  r14d, eax
    test eax, eax
    js   .r
    cmp  dword [rbx + 8], 1            ; xkb text
    jne  .kmc
    mov  r15d, [rbx + 12]
    xor  A1, A1
    mov  A2, r15
    mov  A3d, 1                        ; PROT_READ
    mov  A4d, 2                        ; MAP_PRIVATE
    mov  A5d, r14d
    xor  A6, A6
    call mmap
    cmp  rax, -1
    je   .kmc
    mov  r13, rax
    mov  A1, r13
    mov  A2, r15
    call xkb_parse
    mov  A1, r13
    mov  A2, r15
    call munmap
.kmc:
    mov  A1d, r14d
    call close
    RET_

.dd:
    cmp  r12d, 0
    je   .ddoffer
    cmp  r12d, 1
    je   .ddenter
    cmp  r12d, 2
    je   .ddleave
    cmp  r12d, 4
    je   .dddrop
    cmp  r12d, 5
    jne  .r
    mov  r14d, [rbx + 8]               ; selection(offer): the clipboard, not for us
    test r14d, r14d
    jz   .r
    WL   r14d, 2
    cmp  r14d, [new_offer]
    jne  .r
    mov  dword [new_offer], 0
    RET_
.ddoffer:                              ; data_offer(id): its types follow
    mov  eax, [rbx + 8]
    mov  [new_offer], eax
    mov  dword [offer_ok], 0
    RET_
.offer:                                ; wl_data_offer.offer(mime type)
    test r12d, r12d
    jnz  .r
    lea  rsi, [s_uri]
    lea  rdi, [rbx + 12]
.oc:mov  al, [rsi]
    cmp  al, [rdi]
    jne  .r
    inc  rsi
    inc  rdi
    test al, al
    jnz  .oc
    mov  dword [offer_ok], 1
    RET_
.ddenter:                              ; (serial, surface, x, y, offer)
    mov  r14d, [rbx + 24]
    mov  [dnd_offer], r14d
    mov  dword [dnd_ok], 0
    test r14d, r14d
    jz   .r
    xor  r15d, r15d
    cmp  r14d, [new_offer]
    jne  .da
    cmp  dword [offer_ok], 0
    je   .da
    mov  dword [dnd_ok], 1
    lea  r15, [s_uri]
.da:mov  A1d, r14d
    xor  A2d, A2d                      ; accept(serial, type or null)
    call wl_begin
    mov  A1d, [rbx + 8]
    call wl_u32
    mov  A1, r15
    call wl_str
    call wl_end
    RET_
.dddrop:
    cmp  dword [dnd_offer], 0
    je   .r
    cmp  dword [dnd_ok], 0
    je   .ddleave
    call wl_drop
    mov  dword [dirty], 1
.ddleave:
    mov  r14d, [dnd_offer]
    test r14d, r14d
    jz   .r
    WL   r14d, 2                       ; destroy
    mov  dword [dnd_offer], 0
    cmp  r14d, [new_offer]
    jne  .r
    mov  dword [new_offer], 0
    RET_

; wl_drop(): read the dropped text/uri-list through a pipe -> playlist
FUNC wl_drop, 16
    lea  A1, [L(0)]
    mov  A2d, 0x80000                  ; O_CLOEXEC
    call pipe2
    test eax, eax
    jnz  .r
    mov  A1d, [dnd_offer]
    mov  A2d, 1                        ; receive(type, fd)
    call wl_begin
    lea  A1, [s_uri]
    call wl_str
    mov  eax, [L(4)]
    inc  eax
    mov  [out_fd], eax
    call wl_end
    mov  A1d, [L(4)]
    call close
    mov  A1d, DROPMAX + 1
    call malloc
    mov  r12, rax
    xor  r13d, r13d                    ; bytes read
    test rax, rax
    jz   .c
.rd:mov  eax, [L(0)]
    mov  dword [pfds], eax
    mov  dword [pfds + 4], 1
    lea  A1, [pfds]
    mov  A2, 1
    mov  A3, 3000                      ; a source that says nothing for 3 s is gone
    call poll
    test eax, eax
    jle  .eof
    mov  A1d, [L(0)]
    lea  A2, [r12 + r13]
    mov  A3d, DROPMAX
    sub  A3, r13
    call read
    test rax, rax
    jle  .eof
    add  r13, rax
    cmp  r13, DROPMAX
    jb   .rd
.eof:
    mov  byte [r12 + r13], 0
    mov  eax, [shift]                  ; Shift held while dragging: add to the playlist
    mov  [drop_append], eax
    mov  A1, r12
    call parse_uris
    mov  A1, r12
    call free
.c: mov  A1d, [L(0)]
    call close
.r: RET_

; ============================================================================
; keys
; ============================================================================
; wl_key(evdev code) -> eax 1 if it was a playback key (those repeat when held)
FUNC wl_key, 0
    ARGS rbx
    xor  ecx, ecx
    lea  r10, [kcode]
.f: movzx eax, word [r10 + rcx*2]
    cmp  eax, ebx
    je   .hit
    inc  ecx
    cmp  ecx, NKEYS
    jb   .f
    jmp  .no
.hit:
    lea  r10, [kact]
    movzx ecx, byte [r10 + rcx]
.do:cmp  ecx, KX_TAB
    jb   .core
    je   .tab
    cmp  ecx, KX_QUIT
    je   .quit
    cmp  ecx, KX_FS
    je   .fs
    cmp  dword [fullscreen], 0         ; Escape leaves fullscreen
    je   .no
.fs:cmp  dword [fullscreen], 0
    jne  .unfs
    WL   [o_top], 11, 0                ; set_fullscreen, on the screen we are on
    jmp  .no
.unfs:
    WL   [o_top], 12
    jmp  .no
.quit:
    mov  dword [g_quit], 1
    jmp  .no
.tab:
    mov  ecx, K_UI
    cmp  dword [shift], 0
    je   .core
    mov  ecx, K_BLANK                  ; Shift+Tab
.core:
    mov  A1d, ecx
    call core_key
    or   [dirty], eax
    mov  eax, 1
    RET_
.no:xor  eax, eax
    RET_

; xkb_parse(text, size): find the keys named in knames in the keymap's first
; layout and level (what XLookupKeysym gives on X11). The text is what every
; compositor sends, libxkbcommon's:
;     <AD01> = 24;                         in xkb_keycodes
;     key <AD01> { [ q, Q ] };             in xkb_symbols
;     key <AD01> { type= "..", symbols[Group1]= [ q, Q ], ... };
; Keys not found stay unbound; with none found at all, QWERTY positions.
FUNC xkb_parse, 16
    ARGS rbx, r12
    add  r12, rbx                      ; end
    lea  rdi, [kcode]
    mov  eax, 0xffff
    mov  ecx, NKEYS
    rep  stosw
    mov  r13, rbx
.scan:
    lea  rax, [r13 + 8]
    cmp  rax, r12
    jae  .done
    cmp  dword [r13], 'key '
    jne  .adv
    cmp  r13, rbx
    je   .k
    cmp  byte [r13 - 1], ' '           ; a word of its own (space, tab, newline before)
    ja   .adv
.k: lea  r14, [r13 + 4]
.sp:cmp  r14, r12
    jae  .done
    cmp  byte [r14], ' '
    ja   .lt
    inc  r14
    jmp  .sp
.lt:cmp  byte [r14], '<'
    jne  .adv
    mov  r15, r14                      ; r14..r15: <NAME>
.gt:inc  r15
    cmp  r15, r12
    jae  .done
    cmp  byte [r15], '>'
    jne  .gt
    lea  rsi, [r15 + 1]
    xor  edx, edx                      ; last character that was not blank
.br:cmp  rsi, r12                      ; the first [ that opens a list of symbols:
    jae  .done                         ; after { = or , (not the one in symbols[Group1])
    mov  al, [rsi]
    cmp  al, ';'
    je   .adv2
    cmp  al, '['
    jne  .nb
    cmp  dl, '{'
    je   .tok
    cmp  dl, '='
    je   .tok
    cmp  dl, ','
    je   .tok
.nb:cmp  al, ' '
    jbe  .ws
    mov  dl, al
.ws:inc  rsi
    jmp  .br
.tok:
    inc  rsi
    cmp  rsi, r12
    jae  .done
    cmp  byte [rsi], ' '
    jbe  .tok
    mov  rdx, rsi                      ; rsi..rdx: the first symbol
.te:cmp  rdx, r12
    jae  .done
    mov  al, [rdx]
    cmp  al, ' '
    jbe  .name
    cmp  al, ','
    je   .name
    cmp  al, ']'
    je   .name
    inc  rdx
    jmp  .te
.name:
    lea  r10, [knames]
    xor  ecx, ecx                      ; index
.nm:mov  r8, rsi
.nc:mov  al, [r10]
    test al, al
    jz   .nend
    cmp  r8, rdx
    jae  .nskip
    cmp  al, [r8]
    jne  .nskip
    inc  r10
    inc  r8
    jmp  .nc
.nend:
    cmp  r8, rdx
    je   .found
.nskip:
    cmp  byte [r10], 0                 ; to the next name
    lea  r10, [r10 + 1]
    jne  .nskip
    inc  ecx
    cmp  ecx, NKEYS
    jb   .nm
    jmp  .adv2
.found:
    lea  r10, [kcode]
    cmp  word [r10 + rcx*2], 0xffff    ; the first key that has it wins
    jne  .adv2
    mov  [L(0)], rcx
    mov  [L(8)], rsi
    mov  A1, rbx
    mov  A2, r12
    mov  A3, r14
    lea  A4, [r15 + 1]
    sub  A4, r14
    call kc_find
    mov  rcx, [L(0)]
    mov  rsi, [L(8)]
    sub  eax, 8                        ; xkb keycode -> evdev
    jbe  .adv2
    lea  r10, [kcode]
    mov  [r10 + rcx*2], ax
.adv2:
    mov  r13, rsi
    jmp  .scan
.adv:
    inc  r13
    jmp  .scan
.done:
    lea  r10, [kcode]
    xor  ecx, ecx
.any:
    cmp  word [r10 + rcx*2], 0xffff
    jne  .r
    inc  ecx
    cmp  ecx, NKEYS
    jb   .any
    lea  rsi, [kdef]
    lea  rdi, [kcode]
    mov  ecx, NKEYS
    rep  movsw
.r: RET_

; kc_find(text, end, name, len) -> eax the number in "<NAME> = number", 0 if none
FUNC kc_find, 0
    ARGS rbx, r12, r13, r14
.s: lea  rax, [rbx + r14 + 4]
    cmp  rax, r12
    jae  .no
    mov  rsi, rbx
    mov  rdi, r13
    mov  rcx, r14
    repe cmpsb
    jne  .n
.w: cmp  rsi, r12                      ; blanks, =, blanks, digits
    jae  .no
    cmp  byte [rsi], ' '
    ja   .eq
    inc  rsi
    jmp  .w
.eq:cmp  byte [rsi], '='
    jne  .n
.w2:inc  rsi
    cmp  rsi, r12
    jae  .no
    cmp  byte [rsi], ' '
    jbe  .w2
    xor  eax, eax
.d: movzx ecx, byte [rsi]
    sub  ecx, '0'
    cmp  ecx, 9
    ja   .e
    imul eax, eax, 10
    add  eax, ecx
    inc  rsi
    cmp  rsi, r12
    jb   .d
.e: test eax, eax
    jnz  .r
.n: inc  rbx
    jmp  .s
.no:xor  eax, eax
.r: RET_

; ============================================================================
; window size, pointer
; ============================================================================
; fit(w, h) -> eax w, edx h: the largest size of the cover's shape inside
; (Wayland has no aspect hint, so Peep picks the size itself). No art: as given.
FUNC fit, 0
    ARGS r12, r13
    lea  A1, [art_asp]
    lea  A2, [art_asp + 4]
    call core_art_aspect
    test eax, eax
    jz   .r
    mov  eax, r12d
    mov  ecx, [art_asp + 4]
    imul rax, rcx                      ; w * ah
    mov  edx, r13d
    mov  ecx, [art_asp]
    imul rdx, rcx                      ; h * aw
    cmp  rax, rdx
    jbe  .tall
    mov  rax, rdx                      ; too wide: w = h * aw / ah
    xor  edx, edx
    mov  ecx, [art_asp + 4]
    div  rcx
    mov  r12d, eax
    jmp  .r
.tall:
    xor  edx, edx                      ; h = w * ah / aw
    div  rcx
    mov  r13d, eax
.r: mov  eax, 1
    test r12d, r12d
    cmovz r12d, eax
    test r13d, r13d
    cmovz r13d, eax
    mov  eax, r12d
    mov  edx, r13d
    RET_

; wl_configure(): the compositor settled a size and state; the next frame answers it
FUNC wl_configure, 0
    mov  eax, [pend_fs]
    cmp  eax, [fullscreen]
    je   .nofs
    mov  [fullscreen], eax
    mov  A1d, eax
    call core_set_fullscreen
.nofs:
    mov  eax, [pend_exact]
    mov  [exact], eax
    mov  r12d, [pend_w]
    mov  r13d, [pend_h]
    test r12d, r12d
    jz   .own
    test r13d, r13d
    jz   .own
    cmp  dword [exact], 0
    jne  .set
    jmp  .fit
.own:                                  ; ours to choose: the size we had as a window
    mov  r12d, [win_w]
    mov  r13d, [win_h]
.fit:
    mov  A1d, r12d
    mov  A2d, r13d
    call fit
    mov  r12d, eax
    mov  r13d, edx
    mov  [win_w], r12d
    mov  [win_h], r13d
.set:
    cmp  r12d, [fb_w]
    jne  .new
    cmp  r13d, [fb_h]
    je   .same
.new:
    mov  [fb_w], r12d
    mov  [fb_h], r13d
    mov  A1d, r12d
    mov  A2d, r13d
    call core_note_size
.same:
    mov  dword [configured], 1
    mov  dword [o_frame], 0            ; draw it now
    mov  dword [dirty], 1
    call wl_cursor
    RET_

; wl_apply_size(): a new cover: take its size and shape
FUNC wl_apply_size, 0
    cmp  dword [exact], 0
    jne  .r
    mov  A1d, [scr_w]
    mov  A2d, [scr_h]
    mov  A3d, [fb_w]
    mov  A4d, [fb_h]
    lea  A5, [tsz]
    call core_target_size
    test eax, eax
    jz   .r
    mov  eax, [tsz]
    mov  [fb_w], eax
    mov  [win_w], eax
    mov  eax, [tsz + 4]
    mov  [fb_h], eax
    mov  [win_h], eax
.r: RET_

; edge_at() -> eax resize edges under the pointer (1 top, 2 bottom, 4 left,
; 8 right), 0 if none. Only a window the compositor gave no borders. Leaf.
edge_at:
    xor  eax, eax
    mov  ecx, [ssd]
    or   ecx, [exact]
    jnz  .r
    mov  ecx, [py]
    cmp  ecx, EDGE
    jge  .a
    or   eax, 1
.a: mov  edx, [fb_h]
    sub  edx, EDGE
    cmp  ecx, edx
    jl   .b
    or   eax, 2
.b: mov  ecx, [px]
    cmp  ecx, EDGE
    jge  .c
    or   eax, 4
.c: mov  edx, [fb_w]
    sub  edx, EDGE
    cmp  ecx, edx
    jl   .r
    or   eax, 8
.r: ret

; wl_cursor(): hide or show the pointer as core_cursor_hidden says, with a
; resize arrow over a border
FUNC wl_cursor, 0
    cmp  dword [o_ptr], 0
    je   .r
    call core_cursor_hidden
    xor  ebx, ebx
    test eax, eax
    jnz  .want
    call edge_at
    lea  r10, [edge_shape]
    movzx ebx, byte [r10 + rax]
.want:
    cmp  ebx, [cur_shape]
    je   .r
    mov  [cur_shape], ebx
    test ebx, ebx
    jnz  .show
    WL   [o_ptr], 0, [ptr_serial], 0, 0, 0     ; set_cursor(no surface)
    RET_
.show:
    cmp  dword [o_csdev], 0
    je   .own
    WL   [o_csdev], 1, [ptr_serial], ebx       ; set_shape
    RET_
.own:
    call arrow_cursor
    WL   [o_ptr], 0, [ptr_serial], [o_csurf], 0, 0
.r: RET_

; arrow_cursor(): Peep's own arrow on a surface, made on first use
FUNC arrow_cursor, 0
    cmp  dword [o_csurf], 0
    jne  .r
    mov  A1d, 16
    mov  A2d, 16
    xor  A3d, A3d                      ; ARGB8888
    call shm_new
    test eax, eax
    jz   .r
    mov  ebx, eax
    mov  rdi, [shm_ptr]
    lea  rsi, [arrow]
    mov  r8d, 16
.row:
    movzx edx, word [rsi]              ; outline
    movzx r9d, word [rsi + 2]          ; fill
    mov  ecx, 16
.px:xor  eax, eax
    shr  edx, 1
    jnc  .f
    mov  eax, 0xff000000
.f: shr  r9d, 1
    jnc  .w
    mov  eax, 0xffffffff
.w: stosd
    dec  ecx
    jnz  .px
    add  rsi, 4
    dec  r8d
    jnz  .row
    call wl_id
    mov  [o_csurf], eax
    WL   [o_comp], 0, [o_csurf]
    WL   [o_csurf], 1, ebx, 0, 0
    WL   [o_csurf], 2, 0, 0, 16, 16
    WL   [o_csurf], 6
.r: RET_

; ============================================================================
; frames
; ============================================================================
; shm_new(w, h, format) -> eax a wl_buffer of shared memory (0: failed),
; its pixels at [shm_ptr]
FUNC shm_new, 0
    ARGS r12, r13, r14
    mov  r15d, r12d
    imul r15d, r13d
    shl  r15d, 2                       ; bytes
    lea  A1, [s_appid]
    mov  A2d, 1                        ; MFD_CLOEXEC
    call memfd_create
    test eax, eax
    js   .fail
    mov  ebx, eax
    mov  A1d, ebx
    mov  A2, r15
    call ftruncate
    test eax, eax
    jnz  .cf
    xor  A1, A1
    mov  A2, r15
    mov  A3d, 3                        ; PROT_READ | PROT_WRITE
    mov  A4d, 1                        ; MAP_SHARED
    mov  A5d, ebx
    xor  A6, A6
    call mmap
    cmp  rax, -1
    je   .cf
    mov  [shm_ptr], rax
    call wl_id
    mov  [shm_pool], eax
    mov  A1d, [o_shm]
    xor  A2d, A2d                      ; create_pool(id, fd, size)
    call wl_begin
    mov  A1d, [shm_pool]
    call wl_u32
    mov  A1d, r15d
    call wl_u32
    lea  eax, [rbx + 1]
    mov  [out_fd], eax
    call wl_end
    mov  A1d, ebx
    call close
    call wl_id
    mov  [shm_buf], eax
    lea  eax, [r12*4]
    mov  [shm_stride], eax
    WL   [shm_pool], 0, [shm_buf], 0, r12d, r13d, [shm_stride], r14d
    WL   [shm_pool], 1                 ; the buffer keeps the memory alive
    mov  eax, [shm_buf]
    RET_
.cf:mov  A1d, ebx
    call close
.fail:
    xor  eax, eax
    RET_

; buf_free(slot)
FUNC buf_free, 0
    ARGS rbx
    WL   [rbx], 0                      ; wl_buffer.destroy
    mov  A1, [rbx + 16]
    mov  A2d, [rbx + 4]
    imul A2d, [rbx + 8]
    shl  A2, 2
    call munmap
    mov  dword [rbx], 0
    RET_

; wl_present(): draw a frame into a buffer the compositor is not reading and
; show it. Not before the first configure, and one frame per screen refresh:
; while the last frame's callback is out, dirty stays set and the callback
; brings us back.
FUNC wl_present, 0
    cmp  dword [configured], 0
    je   .r
    cmp  dword [o_frame], 0
    jne  .r
    lea  rbx, [bufs]
    xor  r12d, r12d                    ; a free buffer of this size
    xor  r13d, r13d                    ; an empty slot
    mov  r14d, NBUF
.s: cmp  dword [rbx], 0
    je   .empty
    cmp  dword [rbx + 12], 0           ; with the compositor
    jne  .next
    mov  eax, [rbx + 4]
    cmp  eax, [fb_w]
    jne  .old
    mov  eax, [rbx + 8]
    cmp  eax, [fb_h]
    jne  .old
    mov  r12, rbx
    jmp  .next
.old:                                  ; from before a resize
    mov  A1, rbx
    call buf_free
.empty:
    mov  r13, rbx
.next:
    add  rbx, BUF_SZ
    dec  r14d
    jnz  .s
    test r12, r12
    jnz  .have
    test r13, r13
    jz   .r                            ; all in use: a release brings us back
    mov  A1d, [fb_w]
    mov  A2d, [fb_h]
    mov  A3d, 1                        ; XRGB8888
    call shm_new
    test eax, eax
    jz   .r
    mov  r12, r13
    mov  [r12], eax
    mov  eax, [fb_w]
    mov  [r12 + 4], eax
    mov  eax, [fb_h]
    mov  [r12 + 8], eax
    mov  rax, [shm_ptr]
    mov  [r12 + 16], rax
.have:
    mov  A1, [r12 + 16]
    mov  A2d, [fb_w]
    mov  A3d, [fb_h]
    call core_render
    WL   [o_surf], 1, [r12], 0, 0      ; attach
    WL   [o_surf], 2, 0, 0, 0x7fffffff, 0x7fffffff   ; damage: all of it
    call wl_id
    mov  [o_frame], eax
    WL   [o_surf], 3, [o_frame]        ; frame callback
    WL   [o_surf], 6                   ; commit
    mov  dword [r12 + 12], 1
    mov  dword [dirty], 0
.r: RET_

section .note.GNU-stack noalloc noexec nowrite progbits
