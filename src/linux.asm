; ============================================================================
; Peep — Linux platform layer
;   X11 window + software framebuffer (XPutImage)
;   XDND drag & drop (protocol v5, text/uri-list)
;   ALSA playback ("default" device, so PipeWire/Pulse work transparently)
;   folder scanning, file mapping, player thread
; ============================================================================
default rel
%include "abi.inc"

extern core_list_new, core_list_add, core_list_free, core_publish
extern core_player, core_key, core_render, g_quit, g_ui

extern XOpenDisplay, XDefaultScreen, XRootWindow, XCreateSimpleWindow
extern XStoreName, XSetClassHint, XSelectInput, XInternAtom, XSetWMProtocols
extern XChangeProperty, XMapWindow, XConnectionNumber, XPending, XNextEvent
extern XLookupKeysym, XDefaultVisual, XDefaultDepth, XDefaultGC, XCreateImage
extern XPutImage, XFlush, XSendEvent, XConvertSelection, XGetWindowProperty
extern XFree, XCreateBitmapFromData, XCreatePixmapCursor, XDefineCursor
extern XUndefineCursor
extern snd_pcm_open, snd_pcm_set_params, snd_pcm_writei, snd_pcm_recover
extern snd_pcm_drop, snd_pcm_prepare, snd_pcm_drain, snd_pcm_close
extern malloc, free, open, close, lseek, mmap, munmap, opendir, readdir
extern closedir, strlen, strcasecmp, usleep, pthread_create, poll, write, _exit

global main
global plat_audio_open, plat_audio_write, plat_audio_flush, plat_audio_close
global plat_map, plat_unmap, plat_sleep, plat_title, plat_cmp

; X11 constants
KeyPress        equ 2
Expose          equ 12
ConfigureNotify equ 22
SelectionNotify equ 31
ClientMessage   equ 33
XA_ATOM         equ 4
EV_MASK         equ (1<<15) | 1 | (1<<17)     ; Exposure | KeyPress | StructureNotify
SUBSTRUCT_MASK  equ (1<<19) | (1<<20)

PATHMAX         equ 4096

section .data
align 8
atom_names:
    dq n_proto, n_delete, n_aware, n_enter, n_pos, n_status, n_leave, n_drop
    dq n_finished, n_sel, n_copy, n_urilist, n_prop, n_wmstate, n_fs
NATOMS equ ($ - atom_names) / 8
n_proto     db "WM_PROTOCOLS", 0
n_delete    db "WM_DELETE_WINDOW", 0
n_aware     db "XdndAware", 0
n_enter     db "XdndEnter", 0
n_pos       db "XdndPosition", 0
n_status    db "XdndStatus", 0
n_leave     db "XdndLeave", 0
n_drop      db "XdndDrop", 0
n_finished  db "XdndFinished", 0
n_sel       db "XdndSelection", 0
n_copy      db "XdndActionCopy", 0
n_urilist   db "text/uri-list", 0
n_prop      db "PEEP_DROP", 0
n_wmstate   db "_NET_WM_STATE", 0
n_fs        db "_NET_WM_STATE_FULLSCREEN", 0

s_title     db "Peep", 0
s_class     db "Peep", 0
s_name      db "peep", 0
s_pcm       db "default", 0
s_nodisp    db "peep: cannot open X display", 10
s_nodisp_l  equ $ - s_nodisp
xdnd_ver    dq 5
blank_bits  dq 0

section .bss
alignb 8
atoms:
a_proto     resq 1
a_delete    resq 1
a_aware     resq 1
a_enter     resq 1
a_pos       resq 1
a_status    resq 1
a_leave     resq 1
a_drop      resq 1
a_finished  resq 1
a_sel       resq 1
a_copy      resq 1
a_urilist   resq 1
a_prop      resq 1
a_wmstate   resq 1
a_fs        resq 1
dpy         resq 1
scr         resd 1
xfd         resd 1
root        resq 1
win         resq 1
visual      resq 1
depth       resd 1
gc          resq 1
img         resq 1
fb          resq 1
fb_w        resd 1
fb_h        resd 1
dirty       resd 1
fullscreen  resd 1
xdnd_src    resq 1
blank_cur   resq 1
pcm         resq 1
tid         resq 1
classhint   resq 2
pollfd      resq 1
ev          resb 192
sev         resb 192
gp_type     resq 1
gp_fmt      resq 1
gp_n        resq 1
gp_after    resq 1
gp_data     resq 1
pathbuf     resb PATHMAX

section .text

; ============================================================================
; main
; ============================================================================
FUNC main, 16
    ARGS r12, r13                      ; argc, argv
    xor  A1, A1
    call XOpenDisplay
    test rax, rax
    jnz  .haved
    mov  A1, 2
    lea  A2, [s_nodisp]
    mov  A3, s_nodisp_l
    call write
    mov  A1, 1
    call _exit
.haved:
    mov  [dpy], rax
    mov  A1, rax
    call XDefaultScreen
    mov  [scr], eax
    mov  A1, [dpy]
    mov  A2d, [scr]
    call XRootWindow
    mov  [root], rax
    ; window: black, 640x400
    mov  A1, [dpy]
    mov  A2, [root]
    xor  A3, A3
    xor  A4, A4
    mov  A5, 640
    mov  A6, 400
    mov  qword SARG(7), 0
    mov  qword SARG(8), 0
    mov  qword SARG(9), 0
    call XCreateSimpleWindow
    mov  [win], rax
    mov  A1, [dpy]
    mov  A2, [win]
    lea  A3, [s_title]
    call XStoreName
    lea  rax, [s_name]
    mov  [classhint], rax
    lea  rax, [s_class]
    mov  [classhint + 8], rax
    mov  A1, [dpy]
    mov  A2, [win]
    lea  A3, [classhint]
    call XSetClassHint
    mov  A1, [dpy]
    mov  A2, [win]
    mov  A3, EV_MASK
    call XSelectInput
    ; atoms
    xor  ebx, ebx
.atom:
    mov  A1, [dpy]
    lea  rax, [atom_names]
    mov  A2, [rax + rbx*8]
    xor  A3, A3
    call XInternAtom
    lea  rcx, [atoms]
    mov  [rcx + rbx*8], rax
    inc  ebx
    cmp  ebx, NATOMS
    jb   .atom
    mov  A1, [dpy]
    mov  A2, [win]
    lea  A3, [a_delete]
    mov  A4, 1
    call XSetWMProtocols
    ; XdndAware = 5
    mov  A1, [dpy]
    mov  A2, [win]
    mov  A3, [a_aware]
    mov  A4, XA_ATOM
    mov  A5, 32
    xor  A6, A6
    lea  rax, [xdnd_ver]
    mov  SARG(7), rax
    mov  qword SARG(8), 1
    call XChangeProperty
    ; an invisible cursor for fullscreen
    mov  A1, [dpy]
    mov  A2, [win]
    lea  A3, [blank_bits]
    mov  A4, 8
    mov  A5, 8
    call XCreateBitmapFromData
    mov  rbx, rax
    mov  A1, [dpy]
    mov  A2, rbx
    mov  A3, rbx
    lea  A4, [ev]                      ; zeroed XColor x2 (bss)
    lea  A5, [ev]
    xor  A6, A6
    mov  qword SARG(7), 0
    call XCreatePixmapCursor
    mov  [blank_cur], rax
    ; framebuffer
    mov  A1, [dpy]
    mov  A2d, [scr]
    call XDefaultVisual
    mov  [visual], rax
    mov  A1, [dpy]
    mov  A2d, [scr]
    call XDefaultDepth
    mov  [depth], eax
    mov  A1, [dpy]
    mov  A2d, [scr]
    call XDefaultGC
    mov  [gc], rax
    mov  A1, 640
    mov  A2, 400
    call fb_resize
    ; player thread
    lea  A1, [tid]
    xor  A2, A2
    lea  A3, [core_player]
    xor  A4, A4
    call pthread_create
    ; files given on the command line ("Open with Peep")
    cmp  r12d, 2
    jb   .noargs
    call core_list_new
    mov  r14, rax
    mov  r15d, 1
.arg:
    cmp  r15d, r12d
    jae  .argd
    mov  A1, r14
    mov  A2, [r13 + r15*8]
    xor  A3, A3
    call add_path
    inc  r15d
    jmp  .arg
.argd:
    mov  A1, r14
    call core_publish
.noargs:
    mov  A1, [dpy]
    mov  A2, [win]
    call XMapWindow
    mov  A1, [dpy]
    call XConnectionNumber
    mov  [xfd], eax
    mov  dword [dirty], 1

; ---------------------------------------------------------------- main loop
.loop:
    mov  A1, [dpy]
    call XPending
    test eax, eax
    jz   .idle
    mov  A1, [dpy]
    lea  A2, [ev]
    call XNextEvent
    call on_event
    jmp  .loop
.idle:
    cmp  dword [g_quit], 0
    jne  .quit
    cmp  dword [dirty], 0
    je   .wait
    mov  dword [dirty], 0
    call present
    ; XFlush may have pulled new events into Xlib's queue while it waited
    ; on the socket; poll() would not see those, so go round again.
    jmp  .loop
.wait:
    mov  eax, [xfd]
    mov  dword [pollfd], eax
    mov  dword [pollfd + 4], 1         ; POLLIN
    lea  A1, [pollfd]
    mov  A2, 1
    mov  A3, -1                        ; no interface: sleep until an event
    cmp  dword [g_ui], 0
    je   .p
    mov  A3, 250                       ; overlay: tick the clock 4x/s
.p: call poll
    cmp  dword [g_ui], 0
    je   .loop
    mov  dword [dirty], 1
    jmp  .loop
.quit:
    xor  A1, A1
    call _exit

; ============================================================================
; framebuffer
; ============================================================================
FUNC fb_resize, 0                      ; (w, h)
    ARGS r12, r13
    test r12d, r12d
    jz   .r
    test r13d, r13d
    jz   .r
    mov  rax, [img]
    test rax, rax
    jz   .new
    mov  A1, rax
    call [rax + 96]                    ; XDestroyImage (frees our buffer too)
    mov  qword [img], 0
.new:
    mov  rax, r12
    imul rax, r13
    lea  A1, [rax*4]
    call malloc
    test rax, rax
    jz   .r
    mov  [fb], rax
    mov  [fb_w], r12d
    mov  [fb_h], r13d
    mov  A1, [dpy]
    mov  A2, [visual]
    mov  A3d, [depth]
    mov  A4, 2                         ; ZPixmap
    xor  A5, A5
    mov  A6, [fb]
    mov  SARG(7), r12
    mov  SARG(8), r13
    mov  qword SARG(9), 32
    mov  qword SARG(10), 0
    call XCreateImage
    mov  [img], rax
.r: RET_

FUNC present, 0
    cmp  qword [img], 0
    je   .r
    mov  A1, [fb]
    mov  A2d, [fb_w]
    mov  A3d, [fb_h]
    call core_render
    mov  A1, [dpy]
    mov  A2, [win]
    mov  A3, [gc]
    mov  A4, [img]
    xor  A5, A5
    xor  A6, A6
    mov  qword SARG(7), 0
    mov  qword SARG(8), 0
    mov  eax, [fb_w]
    mov  SARG(9), rax
    mov  eax, [fb_h]
    mov  SARG(10), rax
    call XPutImage
    mov  A1, [dpy]
    call XFlush
.r: RET_

; ============================================================================
; events
; ============================================================================
FUNC on_event, 0
    mov  eax, [ev]
    cmp  eax, KeyPress
    je   .key
    cmp  eax, Expose
    je   .expose
    cmp  eax, ConfigureNotify
    je   .conf
    cmp  eax, ClientMessage
    je   .client
    cmp  eax, SelectionNotify
    je   .sel
    RET_
.expose:
    mov  dword [dirty], 1
    RET_
.conf:
    mov  eax, [ev + 56]
    mov  ecx, [ev + 60]
    cmp  eax, [fb_w]
    jne  .rs
    cmp  ecx, [fb_h]
    je   .r
.rs:mov  A1d, eax
    mov  A2d, ecx
    call fb_resize
    mov  dword [dirty], 1
.r: RET_

.key:
    lea  A1, [ev]
    xor  A2, A2
    call XLookupKeysym
    xor  ecx, ecx
    cmp  rax, ' '
    je   .kpause
    cmp  rax, 0xff51
    je   .kback
    cmp  rax, 0xff53
    je   .kfwd
    cmp  rax, 0xff52
    je   .kup
    cmp  rax, 0xff54
    je   .kdn
    cmp  rax, 'n'
    je   .knext
    cmp  rax, 0xff56                   ; Page Down
    je   .knext
    cmp  rax, 'p'
    je   .kprev
    cmp  rax, 0xff55                   ; Page Up
    je   .kprev
    cmp  rax, 0xff09                   ; Tab
    je   .kui
    cmp  rax, 'i'
    je   .kui
    cmp  rax, 'f'
    je   .kfs
    cmp  rax, 0xff1b                   ; Escape leaves fullscreen
    je   .kesc
    cmp  rax, 'q'
    je   .kquit
    RET_
.kpause: mov ecx, K_PAUSE
    jmp  .kcore
.kback:  mov ecx, K_SEEKBACK
    jmp  .kcore
.kfwd:   mov ecx, K_SEEKFWD
    jmp  .kcore
.kup:    mov ecx, K_VOLUP
    jmp  .kcore
.kdn:    mov ecx, K_VOLDN
    jmp  .kcore
.knext:  mov ecx, K_NEXT
    jmp  .kcore
.kprev:  mov ecx, K_PREV
    jmp  .kcore
.kui:    mov ecx, K_UI
.kcore:
    mov  A1d, ecx
    call core_key
    or   [dirty], eax
    RET_
.kesc:
    cmp  dword [fullscreen], 0
    je   .r
.kfs:
    call toggle_fullscreen
    RET_
.kquit:
    mov  dword [g_quit], 1
    RET_

.client:
    mov  rax, [ev + 40]                ; message_type
    mov  rbx, [ev + 56]                ; data.l[0]
    cmp  rax, [a_proto]
    jne  .c1
    cmp  rbx, [a_delete]
    jne  .r
    mov  dword [g_quit], 1
    RET_
.c1:cmp  rax, [a_enter]
    jne  .c2
    mov  [xdnd_src], rbx
    RET_
.c2:cmp  rax, [a_pos]
    jne  .c3
    mov  [xdnd_src], rbx
    ; XdndStatus: accept, no rectangle, action copy
    mov  A1, rbx
    mov  A2, [a_status]
    mov  A3, [win]
    mov  A4, 1                         ; accept
    xor  A5, A5                        ; l[2] empty rectangle
    mov  A6, [a_copy]                  ; l[4] action
    call xdnd_send
    RET_
.c3:cmp  rax, [a_leave]
    jne  .c4
    mov  qword [xdnd_src], 0
    RET_
.c4:cmp  rax, [a_drop]
    jne  .r
    mov  [xdnd_src], rbx
    mov  A1, [dpy]
    mov  A2, [a_sel]
    mov  A3, [a_urilist]
    mov  A4, [a_prop]
    mov  A5, [win]
    mov  A6, [ev + 56 + 16]            ; data.l[2] = timestamp
    call XConvertSelection
    RET_

.sel:
    mov  rax, [ev + 56]                ; property
    test rax, rax
    jz   .fin0
    mov  A1, [dpy]
    mov  A2, [win]
    mov  A3, rax
    xor  A4, A4
    mov  A5, 0x1000000
    mov  A6, 1                         ; delete after reading
    mov  qword SARG(7), 0              ; AnyPropertyType
    lea  rax, [gp_type]
    mov  SARG(8), rax
    lea  rax, [gp_fmt]
    mov  SARG(9), rax
    lea  rax, [gp_n]
    mov  SARG(10), rax
    lea  rax, [gp_after]
    mov  SARG(11), rax
    lea  rax, [gp_data]
    mov  SARG(12), rax
    call XGetWindowProperty
    test eax, eax
    jnz  .fin0
    mov  rax, [gp_data]
    test rax, rax
    jz   .fin0
    mov  A1, rax
    call parse_uris
    mov  A1, [gp_data]
    call XFree
    mov  ebx, 1
    jmp  .fin
.fin0:
    xor  ebx, ebx
.fin:
    mov  A1, [xdnd_src]
    test A1, A1
    jz   .r
    mov  A2, [a_finished]
    mov  A3, [win]
    mov  A4, rbx                       ; l[1] accepted
    mov  A5, [a_copy]                  ; l[2] action performed
    test rbx, rbx
    jnz  .f2
    xor  A5, A5
.f2:xor  A6, A6
    call xdnd_send
    mov  qword [xdnd_src], 0
    mov  dword [dirty], 1
    RET_

; xdnd_send(target, type, l0, l1, l2, l4)
FUNC xdnd_send, 8
    ARGS rbx, r12, r13, r14
    mov  r15, A5
    mov  [L(0)], A6
    lea  rdi, [sev]
    xor  eax, eax
    mov  ecx, 192/8
    rep  stosq
    mov  dword [sev], ClientMessage
    mov  rax, [dpy]
    mov  [sev + 24], rax
    mov  [sev + 32], rbx
    mov  [sev + 40], r12
    mov  dword [sev + 48], 32
    mov  [sev + 56], r13
    mov  [sev + 64], r14
    mov  [sev + 72], r15
    mov  rax, [L(0)]
    mov  [sev + 88], rax
    mov  A1, [dpy]
    mov  A2, rbx
    xor  A3, A3
    xor  A4, A4
    lea  A5, [sev]
    call XSendEvent
    mov  A1, [dpy]
    call XFlush
    RET_

FUNC toggle_fullscreen, 0
    xor  dword [fullscreen], 1
    lea  rdi, [sev]
    xor  eax, eax
    mov  ecx, 192/8
    rep  stosq
    mov  dword [sev], ClientMessage
    mov  rax, [dpy]
    mov  [sev + 24], rax
    mov  rax, [win]
    mov  [sev + 32], rax
    mov  rax, [a_wmstate]
    mov  [sev + 40], rax
    mov  dword [sev + 48], 32
    mov  eax, [fullscreen]             ; 1 = add, 0 = remove
    mov  [sev + 56], rax
    mov  rax, [a_fs]
    mov  [sev + 64], rax
    mov  qword [sev + 80], 1           ; source: normal application
    mov  A1, [dpy]
    mov  A2, [root]
    xor  A3, A3
    mov  A4, SUBSTRUCT_MASK
    lea  A5, [sev]
    call XSendEvent
    ; hide the pointer while fullscreen
    mov  A1, [dpy]
    mov  A2, [win]
    cmp  dword [fullscreen], 0
    je   .show
    mov  A3, [blank_cur]
    call XDefineCursor
    jmp  .f
.show:
    call XUndefineCursor
.f: mov  A1, [dpy]
    call XFlush
    RET_

; ============================================================================
; drop payload: text/uri-list -> playlist
; ============================================================================
FUNC parse_uris, 0
    ARGS rbx                           ; NUL-terminated uri list
    call core_list_new
    test rax, rax
    jz   .r
    mov  r12, rax
.line:
    cmp  byte [rbx], 0
    je   .done
    ; expect "file://"
    cmp  dword [rbx], 'file'
    jne  .skip
    cmp  word [rbx + 4], ':/'
    jne  .skip
    cmp  byte [rbx + 6], '/'
    jne  .skip
    lea  rsi, [rbx + 7]
.host:                                 ; file://host/path -> skip host
    mov  al, [rsi]
    test al, al
    jz   .skip
    cmp  al, '/'
    je   .path
    cmp  al, 13
    je   .skip
    cmp  al, 10
    je   .skip
    inc  rsi
    jmp  .host
.path:
    lea  rdi, [pathbuf]
    lea  r13, [pathbuf + PATHMAX - 1]
.pc:
    mov  al, [rsi]
    test al, al
    jz   .emit
    cmp  al, 13
    je   .emit
    cmp  al, 10
    je   .emit
    cmp  rdi, r13
    jae  .skip
    cmp  al, '%'
    jne  .lit
    mov  al, [rsi + 1]
    call hexval
    mov  ecx, eax
    js   .lit0
    mov  al, [rsi + 2]
    call hexval
    test eax, eax
    js   .lit0
    shl  ecx, 4
    or   eax, ecx
    mov  [rdi], al
    inc  rdi
    add  rsi, 3
    jmp  .pc
.lit0:
    mov  al, '%'
.lit:
    mov  [rdi], al
    inc  rdi
    inc  rsi
    jmp  .pc
.emit:
    mov  byte [rdi], 0
    mov  rbx, rsi
    mov  A1, r12
    lea  A2, [pathbuf]
    xor  A3, A3
    call add_path
.skip:                                 ; advance to next line
    mov  al, [rbx]
    test al, al
    jz   .done
    inc  rbx
    cmp  al, 10
    jne  .skip
    jmp  .line
.done:
    mov  A1, r12
    call core_publish
.r: RET_

; hexval: al = char -> eax = 0..15, or -1 (sign flag set). Leaf, no frame.
hexval:
    movzx eax, al
    sub  eax, '0'
    cmp  eax, 9
    jbe  .ok
    or   eax, 0x20                     ; ('A'-'0') | 0x20 == ('a'-'0')
    sub  eax, 'a' - '0'
    cmp  eax, 5
    ja   .bad
    add  eax, 10
.ok:test eax, eax
    ret
.bad:
    mov  eax, -1
    test eax, eax
    ret

; ============================================================================
; add_path(list, path, depth): file -> add; folder -> recurse (audio only)
; ============================================================================
FUNC add_path, PATHMAX + 16
    ARGS r12, r13, r14
    cmp  r14, 24
    ja   .r
    mov  A1, r13
    call opendir
    test rax, rax
    jz   .file
    mov  r15, rax
    mov  A1, r13
    call strlen
    mov  rbx, rax                      ; parent length
    lea  rax, [rbx + 2]
    cmp  rax, PATHMAX
    jae  .close
    ; child buffer = parent + '/'
    lea  rdi, [L(0)]
    mov  rsi, r13
    mov  rcx, rbx
    rep  movsb
    mov  byte [rdi], '/'
    lea  rdi, [L(1)]
    add  rdi, rbx
    mov  [L(PATHMAX)], rdi             ; where names go
.ent:
    mov  A1, r15
    call readdir
    test rax, rax
    jz   .close
    lea  rsi, [rax + 19]               ; d_name
    cmp  byte [rsi], '.'               ; hidden, ".", ".."
    je   .ent
    movzx ecx, byte [rax + 18]         ; d_type
    mov  [L(PATHMAX + 8)], ecx
    mov  rdi, [L(PATHMAX)]
    lea  rdx, [L(PATHMAX - 1)]
.cp:mov  al, [rsi]
    cmp  rdi, rdx
    jae  .ent                          ; too long, skip
    mov  [rdi], al
    inc  rdi
    inc  rsi
    test al, al
    jnz  .cp
    cmp  dword [L(PATHMAX + 8)], 8     ; DT_REG: decide by extension
    jne  .rec
    mov  A1, [L(PATHMAX)]
    call is_audio
    test eax, eax
    jz   .ent
    lea  A1, [L(0)]
    call strlen
    lea  A3, [rax + 1]
    mov  A1, r12
    lea  A2, [L(0)]
    call core_list_add
    jmp  .ent
.rec:
    mov  A1, r12
    lea  A2, [L(0)]
    lea  A3, [r14 + 1]
    call add_path
    jmp  .ent
.close:
    mov  A1, r15
    call closedir
    RET_
.file:
    test r14, r14                      ; dropped explicitly: always try it
    jz   .add
    mov  A1, r13
    call is_audio
    test eax, eax
    jz   .r
.add:
    mov  A1, r13
    call strlen
    lea  A3, [rax + 1]
    mov  A1, r12
    mov  A2, r13
    call core_list_add
.r: RET_

; is_audio(name) -> eax 1 if extension is mp3/flac/ogg/oga/wav
FUNC is_audio, 0
    ARGS rbx
    xor  r12, r12                      ; last '.'
    mov  rsi, rbx
.f: mov  al, [rsi]
    test al, al
    jz   .e
    cmp  al, '.'
    jne  .n
    mov  r12, rsi
.n: inc  rsi
    jmp  .f
.e: test r12, r12
    jz   .no
    inc  r12
    xor  eax, eax                      ; lower-cased extension, up to 4 chars
    xor  ecx, ecx
.x: movzx edx, byte [r12 + rcx]
    test edx, edx
    jz   .cmp
    cmp  ecx, 4
    jae  .no
    cmp  edx, 'A'
    jb   .s
    cmp  edx, 'Z'
    ja   .s
    or   edx, 0x20
.s: mov  r8d, ecx
    shl  ecx, 3
    shl  edx, cl                       ; byte n of the packed extension
    mov  ecx, r8d
    or   eax, edx
    inc  ecx
    jmp  .x
.cmp:
    cmp  eax, 'mp3'
    je   .yes
    cmp  eax, 'flac'
    je   .yes
    cmp  eax, 'ogg'
    je   .yes
    cmp  eax, 'oga'
    je   .yes
    cmp  eax, 'wav'
    je   .yes
.no:xor  eax, eax
    RET_
.yes:
    mov  eax, 1
    RET_

; ============================================================================
; services used by the core
; ============================================================================

; plat_title(path, out, max): basename without extension, ASCII only
FUNC plat_title, 0
    ARGS rbx, r12, r13
    mov  rsi, rbx                      ; find basename and last dot
    mov  r14, rbx
    xor  r15, r15
.f: mov  al, [rsi]
    test al, al
    jz   .e
    cmp  al, '/'
    jne  .d
    lea  r14, [rsi + 1]
    xor  r15, r15
.d: cmp  al, '.'
    jne  .n
    cmp  rsi, r14
    je   .n
    mov  r15, rsi
.n: inc  rsi
    jmp  .f
.e: test r15, r15
    cmovz r15, rsi                     ; end of copy
    mov  rsi, r14
    mov  rdi, r12
    lea  rdx, [r12 + r13 - 1]
.c: cmp  rsi, r15
    jae  .z
    cmp  rdi, rdx
    jae  .z
    mov  al, [rsi]
    inc  rsi
    cmp  al, 0x80
    jb   .a
    cmp  al, 0xC0
    jb   .c                            ; UTF-8 continuation: drop
    mov  al, '?'                       ; non-ASCII character
.a: cmp  al, 32
    jae  .w
    mov  al, '?'
.w: mov  [rdi], al
    inc  rdi
    jmp  .c
.z: mov  byte [rdi], 0
    RET_

FUNC plat_cmp, 0                       ; qsort(char**)
    mov  A1, [A1]
    mov  A2, [A2]
    call strcasecmp
    RET_

; plat_map(path, &len) -> rax
FUNC plat_map, 0
    ARGS rbx, r12
    mov  A1, rbx
    mov  A2, 0x80000                   ; O_RDONLY | O_CLOEXEC
    call open
    test eax, eax
    js   .fail
    mov  r13d, eax
    mov  A1d, r13d
    xor  A2, A2
    mov  A3, 2                         ; SEEK_END
    call lseek
    test rax, rax
    jle  .closefail
    mov  r14, rax
    xor  A1, A1
    mov  A2, r14
    mov  A3, 1                         ; PROT_READ
    mov  A4, 2                         ; MAP_PRIVATE
    mov  A5d, r13d
    xor  A6, A6
    call mmap
    mov  r15, rax
    mov  A1d, r13d
    call close
    cmp  r15, -1
    je   .fail
    mov  [r12], r14
    mov  rax, r15
    RET_
.closefail:
    mov  A1d, r13d
    call close
.fail:
    xor  eax, eax
    RET_

FUNC plat_unmap, 0
    call munmap
    RET_

FUNC plat_sleep, 0
    imul A1d, A1d, 1000
    call usleep
    RET_

; ---- ALSA ------------------------------------------------------------------
FUNC plat_audio_open, 0                ; (rate) -> 0 ok
    ARGS rbx
    lea  A1, [pcm]
    lea  A2, [s_pcm]
    xor  A3, A3                        ; playback
    xor  A4, A4
    call snd_pcm_open
    test eax, eax
    js   .fail
    mov  A1, [pcm]
    mov  A2, 2                         ; S16_LE
    mov  A3, 3                         ; RW_INTERLEAVED
    mov  A4, 2                         ; stereo
    mov  A5d, ebx
    mov  A6, 1                         ; allow resampling
    mov  qword SARG(7), 100000         ; 100 ms latency
    call snd_pcm_set_params
    test eax, eax
    js   .close
    xor  eax, eax
    RET_
.close:
    mov  A1, [pcm]
    call snd_pcm_close
    mov  qword [pcm], 0
.fail:
    mov  eax, 1
    RET_

FUNC plat_audio_write, 0               ; (buf, frames)
    ARGS rbx, r12
.l: test r12, r12
    jz   .r
    mov  A1, [pcm]
    test A1, A1
    jz   .r
    mov  A2, rbx
    mov  A3, r12
    call snd_pcm_writei
    test rax, rax
    jns  .ok
    mov  A1, [pcm]
    mov  A2d, eax
    mov  A3, 1
    call snd_pcm_recover
    test eax, eax
    js   .r
    jmp  .l
.ok:sub  r12, rax
    lea  rbx, [rbx + rax*4]
    jmp  .l
.r: RET_

FUNC plat_audio_flush, 0
    mov  A1, [pcm]
    test A1, A1
    jz   .r
    call snd_pcm_drop
    mov  A1, [pcm]
    call snd_pcm_prepare
.r: RET_

FUNC plat_audio_close, 0               ; (drain)
    ARGS rbx
    mov  A1, [pcm]
    test A1, A1
    jz   .r
    test ebx, ebx
    jz   .c
    call snd_pcm_drain
.c: mov  A1, [pcm]
    call snd_pcm_close
    mov  qword [pcm], 0
.r: RET_

section .note.GNU-stack noalloc noexec nowrite progbits
