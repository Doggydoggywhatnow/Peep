; ============================================================================
; Peep — Windows platform layer
;   Win32 window + DIB framebuffer (StretchDIBits)
;   WM_DROPFILES drag & drop, UTF-16 paths throughout
;   waveOut playback (winmm), memory-mapped files, player thread
; ============================================================================
default rel
%include "abi.inc"

extern core_list_new, core_list_add, core_list_free, core_publish
extern core_player, core_key, core_render, g_quit, g_ui

extern GetModuleHandleW, LoadIconW, LoadCursorW, GetStockObject, RegisterClassExW
extern CreateWindowExW, ShowWindow, GetMessageW, TranslateMessage, DispatchMessageW
extern DefWindowProcW, PostQuitMessage, DestroyWindow, InvalidateRect, BeginPaint
extern EndPaint, StretchDIBits, SetTimer, KillTimer, AdjustWindowRect, SetCursor
extern GetWindowLongW, SetWindowLongW, GetWindowPlacement, SetWindowPlacement
extern SetWindowPos, MonitorFromWindow, GetMonitorInfoW, SetProcessDPIAware
extern DragQueryFileW, DragFinish, CommandLineToArgvW, GetCommandLineW, LocalFree
extern GetFileAttributesW, FindFirstFileW, FindNextFileW, FindClose
extern CreateFileW, GetFileSizeEx, CreateFileMappingW, MapViewOfFile
extern UnmapViewOfFile, CloseHandle, CreateThread, Sleep, CreateEventW
extern WaitForSingleObject, ExitProcess
extern waveOutOpen, waveOutPrepareHeader, waveOutUnprepareHeader, waveOutWrite
extern waveOutReset, waveOutClose
extern malloc, free, memcpy, wcslen, _wcsicmp

global main
global plat_audio_open, plat_audio_write, plat_audio_flush, plat_audio_close
global plat_map, plat_unmap, plat_sleep, plat_title, plat_cmp

WM_DESTROY      equ 0x0002
WM_SIZE         equ 0x0005
WM_PAINT        equ 0x000F
WM_ERASEBKGND   equ 0x0014
WM_SETCURSOR    equ 0x0020
WM_KEYDOWN      equ 0x0100
WM_TIMER        equ 0x0113
WM_DROPFILES    equ 0x0233
WS_OVERLAPPEDWINDOW equ 0x00CF0000
GWL_STYLE       equ -16
NBUF            equ 8
WAVEHDR_SZ      equ 48
WPATH           equ 2048           ; wchar_t per path buffer

section .data
w_class     dw __utf16__("Peep"), 0
w_title     dw __utf16__("Peep"), 0
w_star      dw __utf16__("\*"), 0

section .bss
alignb 16
hinst       resq 1
hwnd        resq 1
fb          resq 1
fb_w        resd 1
fb_h        resd 1
bmi         resb 44
fullscreen  resd 1
alignb 8
saved_wp    resb 48           ; WINDOWPLACEMENT (44)
mon_info    resb 40           ; MONITORINFO
hwo         resq 1
wev         resq 1
next_buf    resd 1
alignb 16
hdrs        resb WAVEHDR_SZ * NBUF
wbufs       resb CHUNK * 4 * NBUF
dropbuf     resw 32768

section .text

; ============================================================================
; main
; ============================================================================
FUNC main, 160                         ; WNDCLASSEXW(80) + MSG(48) + RECT(16)
    call SetProcessDPIAware            ; crisp pixels on high-DPI screens
    xor  A1, A1
    call GetModuleHandleW
    mov  [hinst], rax
    ; WNDCLASSEXW at L(0)
    lea  rdi, [L(0)]
    xor  eax, eax
    mov  ecx, 10
    rep  stosq
    mov  dword [L(0)], 80
    lea  rax, [wndproc]
    mov  [L(8)], rax
    mov  rax, [hinst]
    mov  [L(24)], rax
    mov  A1, [hinst]
    mov  A2, 1                         ; icon resource #1
    call LoadIconW
    mov  [L(32)], rax
    mov  [L(72)], rax
    xor  A1, A1
    mov  A2, 32512                     ; IDC_ARROW
    call LoadCursorW
    mov  [L(40)], rax
    mov  A1, 4                         ; BLACK_BRUSH
    call GetStockObject
    mov  [L(48)], rax
    lea  rax, [w_class]
    mov  [L(64)], rax
    lea  A1, [L(0)]
    call RegisterClassExW
    ; outer size for a 640x400 client area
    mov  dword [L(128)], 0
    mov  dword [L(132)], 0
    mov  dword [L(136)], 640
    mov  dword [L(140)], 400
    lea  A1, [L(128)]
    mov  A2, WS_OVERLAPPEDWINDOW
    xor  A3, A3
    call AdjustWindowRect
    mov  A1, 0x10                      ; WS_EX_ACCEPTFILES
    lea  A2, [w_class]
    lea  A3, [w_title]
    mov  A4, WS_OVERLAPPEDWINDOW
    mov  eax, 0x80000000               ; CW_USEDEFAULT (int)
    mov  SARG(5), rax
    mov  SARG(6), rax
    mov  eax, [L(136)]
    sub  eax, [L(128)]
    mov  SARG(7), rax
    mov  eax, [L(140)]
    sub  eax, [L(132)]
    mov  SARG(8), rax
    mov  qword SARG(9), 0
    mov  qword SARG(10), 0
    mov  rax, [hinst]
    mov  SARG(11), rax
    mov  qword SARG(12), 0
    call CreateWindowExW
    mov  [hwnd], rax
    ; player thread
    xor  A1, A1
    xor  A2, A2
    lea  A3, [core_player]
    xor  A4, A4
    mov  qword SARG(5), 0
    mov  qword SARG(6), 0
    call CreateThread
    ; files on the command line ("Open with" / drop onto Peep.exe)
    call GetCommandLineW
    mov  A1, rax
    lea  A2, [L(144)]
    call CommandLineToArgvW
    mov  r13, rax
    test rax, rax
    jz   .show
    mov  r12d, [L(144)]
    cmp  r12d, 2
    jb   .freeargs
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
.freeargs:
    mov  A1, r13
    call LocalFree
.show:
    mov  A1, [hwnd]
    mov  A2, 10                        ; SW_SHOWDEFAULT
    call ShowWindow
.msg:
    lea  A1, [L(80)]
    xor  A2, A2
    xor  A3, A3
    xor  A4, A4
    call GetMessageW
    test eax, eax
    jle  .quit
    lea  A1, [L(80)]
    call TranslateMessage
    lea  A1, [L(80)]
    call DispatchMessageW
    jmp  .msg
.quit:
    mov  dword [g_quit], 1
    xor  A1, A1
    call ExitProcess

; ============================================================================
; window procedure
; ============================================================================
FUNC wndproc, 80                       ; PAINTSTRUCT (72)
    ARGS rbx, r12, r13, r14            ; hwnd, msg, wparam, lparam
    cmp  r12d, WM_PAINT
    je   .paint
    cmp  r12d, WM_KEYDOWN
    je   .key
    cmp  r12d, WM_TIMER
    je   .inval
    cmp  r12d, WM_SIZE
    je   .size
    cmp  r12d, WM_ERASEBKGND
    je   .one
    cmp  r12d, WM_DROPFILES
    je   .drop
    cmp  r12d, WM_SETCURSOR
    je   .cursor
    cmp  r12d, WM_DESTROY
    je   .destroy
.def:
    mov  A1, rbx
    mov  A2, r12
    mov  A3, r13
    mov  A4, r14
    call DefWindowProcW
    RET_
.one:
    mov  eax, 1
    RET_
.zero:
    xor  eax, eax
    RET_
.destroy:
    mov  dword [g_quit], 1
    xor  A1, A1
    call PostQuitMessage
    jmp  .zero
.size:
    mov  A2d, r14d
    shr  A2d, 16                       ; height = HIWORD(lParam)
    and  A2d, 0xFFFF
    mov  A1d, r14d
    and  A1d, 0xFFFF                   ; width  = LOWORD(lParam)
    call fb_resize
.inval:
    mov  A1, rbx
    xor  A2, A2
    xor  A3, A3
    call InvalidateRect
    jmp  .zero
.paint:
    mov  A1, rbx
    lea  A2, [L(0)]
    call BeginPaint
    mov  r15, rax
    cmp  qword [fb], 0
    je   .endp
    mov  A1, [fb]
    mov  A2d, [fb_w]
    mov  A3d, [fb_h]
    call core_render
    mov  A1, r15
    xor  A2, A2
    xor  A3, A3
    mov  A4d, [fb_w]
    mov  eax, [fb_h]
    mov  SARG(5), rax
    mov  qword SARG(6), 0
    mov  qword SARG(7), 0
    mov  eax, [fb_w]
    mov  SARG(8), rax
    mov  eax, [fb_h]
    mov  SARG(9), rax
    mov  rax, [fb]
    mov  SARG(10), rax
    lea  rax, [bmi]
    mov  SARG(11), rax
    mov  qword SARG(12), 0             ; DIB_RGB_COLORS
    mov  qword SARG(13), 0x00CC0020    ; SRCCOPY
    call StretchDIBits
.endp:
    mov  A1, rbx
    lea  A2, [L(0)]
    call EndPaint
    jmp  .zero
.cursor:
    cmp  dword [fullscreen], 0
    je   .def
    cmp  r14w, 1                       ; HTCLIENT
    jne  .def
    xor  A1, A1
    call SetCursor                     ; no pointer over a fullscreen Peep
    jmp  .one
.drop:
    call core_list_new
    mov  r15, rax
    mov  A1, r13
    mov  A2d, 0xFFFFFFFF
    xor  A3, A3
    xor  A4, A4
    call DragQueryFileW
    mov  r12d, eax                     ; count
    xor  esi, esi
.dl:cmp  esi, r12d
    jae  .dd
    mov  A1, r13
    mov  A2d, esi
    lea  A3, [dropbuf]
    mov  A4, 32768
    call DragQueryFileW
    test eax, eax
    jz   .dn
    mov  A1, r15
    lea  A2, [dropbuf]
    xor  A3, A3
    call add_path
.dn:inc  esi
    jmp  .dl
.dd:mov  A1, r13
    call DragFinish
    mov  A1, r15
    call core_publish
    jmp  .inval

.key:
    mov  eax, r13d
    xor  ecx, ecx
    cmp  eax, 0x20
    je   .kpause
    cmp  eax, 0x25
    je   .kback
    cmp  eax, 0x27
    je   .kfwd
    cmp  eax, 0x26
    je   .kup
    cmp  eax, 0x28
    je   .kdn
    cmp  eax, 'N'
    je   .knext
    cmp  eax, 0x22                     ; Page Down
    je   .knext
    cmp  eax, 'P'
    je   .kprev
    cmp  eax, 0x21                     ; Page Up
    je   .kprev
    cmp  eax, 0x09                     ; Tab
    je   .kui
    cmp  eax, 'I'
    je   .kui
    cmp  eax, 'F'
    je   .kfs
    cmp  eax, 0x7A                     ; F11
    je   .kfs
    cmp  eax, 0x1B                     ; Esc leaves fullscreen
    je   .kesc
    cmp  eax, 'Q'
    je   .kquit
    jmp  .def
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
.kui:
    mov  A1d, K_UI
    call core_key
    ; overlay visible: tick 4x/s; hidden: no timer at all
    cmp  dword [g_ui], 0
    je   .kill
    mov  A1, rbx
    mov  A2, 1
    mov  A3, 250
    xor  A4, A4
    call SetTimer
    jmp  .inval
.kill:
    mov  A1, rbx
    mov  A2, 1
    call KillTimer
    jmp  .inval
.kcore:
    mov  A1d, ecx
    call core_key
    test eax, eax
    jnz  .inval
    jmp  .zero
.kesc:
    cmp  dword [fullscreen], 0
    je   .zero
.kfs:
    call toggle_fullscreen
    jmp  .zero
.kquit:
    mov  A1, rbx
    call DestroyWindow
    jmp  .zero

FUNC fb_resize, 0                      ; (w, h)
    ARGS r12, r13
    test r12d, r12d
    jz   .r
    test r13d, r13d
    jz   .r
    mov  A1, [fb]
    call free
    mov  rax, r12
    imul rax, r13
    lea  A1, [rax*4]
    call malloc
    mov  [fb], rax
    mov  [fb_w], r12d
    mov  [fb_h], r13d
    lea  rdi, [bmi]
    mov  dword [rdi], 40               ; BITMAPINFOHEADER
    mov  [rdi + 4], r12d
    mov  eax, r13d
    neg  eax                           ; top-down
    mov  [rdi + 8], eax
    mov  word [rdi + 12], 1
    mov  word [rdi + 14], 32
    mov  dword [rdi + 16], 0           ; BI_RGB
.r: RET_

FUNC toggle_fullscreen, 0
    mov  A1, [hwnd]
    mov  A2, GWL_STYLE
    call GetWindowLongW
    mov  ebx, eax
    cmp  dword [fullscreen], 0
    jne  .leave
    mov  dword [saved_wp], 44
    mov  A1, [hwnd]
    lea  A2, [saved_wp]
    call GetWindowPlacement
    mov  A1, [hwnd]
    mov  A2, 1                         ; MONITOR_DEFAULTTOPRIMARY
    call MonitorFromWindow
    mov  dword [mon_info], 40
    mov  A1, rax
    lea  A2, [mon_info]
    call GetMonitorInfoW
    mov  A1, [hwnd]
    mov  A2, GWL_STYLE
    mov  A3d, ebx
    and  A3d, ~WS_OVERLAPPEDWINDOW
    call SetWindowLongW
    mov  A1, [hwnd]
    xor  A2, A2                        ; HWND_TOP
    movsxd A3, dword [mon_info + 4]
    movsxd A4, dword [mon_info + 8]
    mov  eax, [mon_info + 12]
    sub  eax, [mon_info + 4]
    mov  SARG(5), rax
    mov  eax, [mon_info + 16]
    sub  eax, [mon_info + 8]
    mov  SARG(6), rax
    mov  qword SARG(7), 0x220          ; NOOWNERZORDER | FRAMECHANGED
    call SetWindowPos
    mov  dword [fullscreen], 1
    RET_
.leave:
    mov  A1, [hwnd]
    mov  A2, GWL_STYLE
    mov  A3d, ebx
    or   A3d, WS_OVERLAPPEDWINDOW
    call SetWindowLongW
    mov  A1, [hwnd]
    lea  A2, [saved_wp]
    call SetWindowPlacement
    mov  A1, [hwnd]
    xor  A2, A2
    xor  A3, A3
    xor  A4, A4
    mov  qword SARG(5), 0
    mov  qword SARG(6), 0
    mov  qword SARG(7), 0x227          ; NOMOVE|NOSIZE|NOZORDER|NOOWNERZORDER|FRAMECHANGED
    call SetWindowPos
    mov  dword [fullscreen], 0
    RET_

; ============================================================================
; add_path(list, wpath, depth): file -> add; folder -> recurse (audio only)
; ============================================================================
FUNC add_path, WPATH*2 + 608
    ARGS r12, r13, r14
    cmp  r14, 24
    ja   .r
    mov  A1, r13
    call GetFileAttributesW
    cmp  eax, -1
    je   .r
    test eax, 0x10                     ; FILE_ATTRIBUTE_DIRECTORY
    jz   .file
    mov  A1, r13
    call wcslen
    mov  rbx, rax
    lea  rax, [rbx + 4]
    cmp  rax, WPATH
    jae  .r
    ; L(0) = path + "\*"
    lea  rdi, [L(0)]
    mov  rsi, r13
    mov  rcx, rbx
    rep  movsw
    mov  dword [rdi], 0x002A005C       ; L"\*"
    mov  word [rdi + 4], 0
    lea  A1, [L(0)]
    lea  A2, [L(WPATH*2)]              ; WIN32_FIND_DATAW
    call FindFirstFileW
    cmp  rax, -1
    je   .r
    mov  r15, rax
    lea  rax, [L(2)]
    lea  rax, [rax + rbx*2]
    mov  [L(WPATH*2 + 600)], rax       ; where child names go (after '\')
.ent:
    lea  rsi, [L(WPATH*2 + 44)]        ; cFileName
    cmp  word [rsi], '.'               ; hidden, ".", ".."
    je   .nx
    mov  rdi, [L(WPATH*2 + 600)]
    lea  rdx, [L(WPATH*2 - 2)]
.cp:mov  ax, [rsi]
    cmp  rdi, rdx
    jae  .nx
    mov  [rdi], ax
    add  rdi, 2
    add  rsi, 2
    test ax, ax
    jnz  .cp
    test dword [L(WPATH*2)], 0x10
    jz   .f
    mov  A1, r12
    lea  A2, [L(0)]
    lea  A3, [r14 + 1]
    call add_path
    jmp  .nx
.f: mov  A1, [L(WPATH*2 + 600)]
    call is_audio
    test eax, eax
    jz   .nx
    lea  A1, [L(0)]
    call wcslen
    lea  A3, [rax*2 + 2]
    mov  A1, r12
    lea  A2, [L(0)]
    call core_list_add
.nx:mov  A1, r15
    lea  A2, [L(WPATH*2)]
    call FindNextFileW
    test eax, eax
    jnz  .ent
    mov  A1, r15
    call FindClose
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
    call wcslen
    lea  A3, [rax*2 + 2]
    mov  A1, r12
    mov  A2, r13
    call core_list_add
.r: RET_

; is_audio(wname) -> eax 1 for mp3/flac/ogg/oga/wav
FUNC is_audio, 0
    ARGS rbx
    xor  r12, r12
    mov  rsi, rbx
.f: mov  ax, [rsi]
    test ax, ax
    jz   .e
    cmp  ax, '.'
    jne  .n
    mov  r12, rsi
.n: add  rsi, 2
    jmp  .f
.e: test r12, r12
    jz   .no
    add  r12, 2
    xor  eax, eax
    xor  ecx, ecx
.x: movzx edx, word [r12 + rcx*2]
    test edx, edx
    jz   .cmp
    cmp  ecx, 4
    jae  .no
    cmp  edx, 0x7F
    ja   .no
    cmp  edx, 'A'
    jb   .s
    cmp  edx, 'Z'
    ja   .s
    or   edx, 0x20
.s: mov  r8d, ecx
    shl  ecx, 3
    shl  edx, cl
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

; plat_title(wpath, out, max): basename without extension, ASCII only
FUNC plat_title, 0
    ARGS rbx, r12, r13
    mov  rsi, rbx
    mov  r14, rbx
    xor  r15, r15
.f: mov  ax, [rsi]
    test ax, ax
    jz   .e
    cmp  ax, '\'
    je   .sl
    cmp  ax, '/'
    jne  .d
.sl:lea  r14, [rsi + 2]
    xor  r15, r15
.d: cmp  ax, '.'
    jne  .n
    cmp  rsi, r14
    je   .n
    mov  r15, rsi
.n: add  rsi, 2
    jmp  .f
.e: test r15, r15
    cmovz r15, rsi
    mov  rsi, r14
    mov  rdi, r12
    lea  rdx, [r12 + r13 - 1]
.c: cmp  rsi, r15
    jae  .z
    cmp  rdi, rdx
    jae  .z
    movzx eax, word [rsi]
    add  rsi, 2
    cmp  eax, 0xDC00                   ; low surrogate: second half, drop
    jb   .nl
    cmp  eax, 0xDFFF
    jbe  .c
.nl:cmp  eax, 32
    jb   .q
    cmp  eax, 0x7F
    jb   .w
.q: mov  eax, '?'
.w: mov  [rdi], al
    inc  rdi
    jmp  .c
.z: mov  byte [rdi], 0
    RET_

FUNC plat_cmp, 0
    mov  A1, [A1]
    mov  A2, [A2]
    call _wcsicmp
    RET_

; plat_map(wpath, &len) -> rax
FUNC plat_map, 16
    ARGS rbx, r12
    mov  A1, rbx
    mov  A2d, 0x80000000               ; GENERIC_READ
    mov  A3, 3                         ; FILE_SHARE_READ | FILE_SHARE_WRITE
    xor  A4, A4
    mov  qword SARG(5), 3              ; OPEN_EXISTING
    mov  qword SARG(6), 0x08000080     ; SEQUENTIAL_SCAN | NORMAL
    mov  qword SARG(7), 0
    call CreateFileW
    cmp  rax, -1
    je   .fail
    mov  r13, rax
    mov  A1, r13
    lea  A2, [L(0)]
    call GetFileSizeEx
    test eax, eax
    jz   .closef
    mov  r14, [L(0)]
    test r14, r14
    jle  .closef
    mov  A1, r13
    xor  A2, A2
    mov  A3, 2                         ; PAGE_READONLY
    xor  A4, A4
    mov  qword SARG(5), 0
    mov  qword SARG(6), 0
    call CreateFileMappingW
    mov  r15, rax
    mov  A1, r13
    call CloseHandle
    test r15, r15
    jz   .fail
    mov  A1, r15
    mov  A2, 4                         ; FILE_MAP_READ
    xor  A3, A3
    xor  A4, A4
    mov  qword SARG(5), 0
    call MapViewOfFile
    mov  rbx, rax
    mov  A1, r15
    call CloseHandle
    test rbx, rbx
    jz   .fail
    mov  [r12], r14
    mov  rax, rbx
    RET_
.closef:
    mov  A1, r13
    call CloseHandle
.fail:
    xor  eax, eax
    RET_

FUNC plat_unmap, 0
    call UnmapViewOfFile
    RET_

FUNC plat_sleep, 0
    call Sleep
    RET_

; ---- waveOut ---------------------------------------------------------------
FUNC plat_audio_open, 32               ; (rate) -> 0 ok
    ARGS rbx
    cmp  qword [wev], 0
    jne  .ev
    xor  A1, A1
    xor  A2, A2                        ; auto-reset
    xor  A3, A3
    xor  A4, A4
    call CreateEventW
    mov  [wev], rax
.ev:
    ; WAVEFORMATEX at L(0)
    mov  word [L(0)], 1                ; PCM
    mov  word [L(2)], 2
    mov  [L(4)], ebx
    lea  eax, [rbx*4]
    mov  [L(8)], eax
    mov  word [L(12)], 4
    mov  word [L(14)], 16
    mov  word [L(16)], 0
    lea  A1, [hwo]
    mov  A2d, 0xFFFFFFFF               ; WAVE_MAPPER
    lea  A3, [L(0)]
    mov  A4, [wev]
    mov  qword SARG(5), 0
    mov  qword SARG(6), 0x50000        ; CALLBACK_EVENT
    call waveOutOpen
    test eax, eax
    jnz  .fail
    lea  rdi, [hdrs]
    xor  eax, eax
    mov  ecx, WAVEHDR_SZ * NBUF / 8
    rep  stosq
    mov  dword [next_buf], 0
    xor  eax, eax
    RET_
.fail:
    mov  qword [hwo], 0
    mov  eax, 1
    RET_

; wait_hdr(hdr): block until a submitted header is done, then unprepare it
FUNC wait_hdr, 0
    ARGS rbx
    cmp  qword [rbx + 16], 0           ; dwUser = submitted
    je   .r
.w: test dword [rbx + 24], 1           ; WHDR_DONE
    jnz  .done
    mov  A1, [wev]
    mov  A2, 50
    call WaitForSingleObject
    jmp  .w
.done:
    mov  A1, [hwo]
    mov  A2, rbx
    mov  A3, WAVEHDR_SZ
    call waveOutUnprepareHeader
    mov  qword [rbx + 16], 0
.r: RET_

FUNC plat_audio_write, 0               ; (buf, frames)
    ARGS r12, r13
    cmp  qword [hwo], 0
    je   .r
    mov  eax, [next_buf]
    imul eax, WAVEHDR_SZ
    lea  rbx, [hdrs]
    add  rbx, rax                      ; header
    mov  A1, rbx
    call wait_hdr
    mov  eax, [next_buf]
    imul eax, CHUNK * 4
    lea  r14, [wbufs]
    add  r14, rax                      ; its buffer
    mov  A1, r14
    mov  A2, r12
    lea  A3, [r13*4]
    call memcpy
    mov  [rbx], r14                    ; lpData
    lea  eax, [r13d*4]
    mov  [rbx + 8], eax                ; dwBufferLength
    mov  dword [rbx + 24], 0           ; dwFlags
    mov  dword [rbx + 28], 0           ; dwLoops
    mov  A1, [hwo]
    mov  A2, rbx
    mov  A3, WAVEHDR_SZ
    call waveOutPrepareHeader
    mov  A1, [hwo]
    mov  A2, rbx
    mov  A3, WAVEHDR_SZ
    call waveOutWrite
    mov  qword [rbx + 16], 1
    mov  eax, [next_buf]
    inc  eax
    and  eax, NBUF - 1
    mov  [next_buf], eax
.r: RET_

FUNC release_all, 0
    xor  r12d, r12d
.l: cmp  r12d, NBUF
    jae  .r
    mov  eax, r12d
    imul eax, WAVEHDR_SZ
    lea  A1, [hdrs]
    add  A1, rax
    call wait_hdr
    inc  r12d
    jmp  .l
.r: mov  dword [next_buf], 0
    RET_

FUNC plat_audio_flush, 0
    cmp  qword [hwo], 0
    je   .r
    mov  A1, [hwo]
    call waveOutReset                  ; marks every queued buffer done
    call release_all
.r: RET_

FUNC plat_audio_close, 0               ; (drain)
    ARGS rbx
    cmp  qword [hwo], 0
    je   .r
    test ebx, ebx
    jz   .now
    call release_all                   ; waits for queued audio to finish
.now:
    mov  A1, [hwo]
    call waveOutReset
    call release_all
    mov  A1, [hwo]
    call waveOutClose
    mov  qword [hwo], 0
.r: RET_
