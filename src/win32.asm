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
extern core_take_info, core_target_size, core_note_size, core_art_aspect
extern core_next_wake, core_click, core_hover, core_tick_needed
extern core_set_fullscreen, core_motion, core_cursor_hidden

extern GetModuleHandleW, LoadIconW, LoadCursorW, GetStockObject, RegisterClassExW
extern CreateWindowExW, ShowWindow, GetMessageW, TranslateMessage, DispatchMessageW
extern DefWindowProcW, PostQuitMessage, DestroyWindow, InvalidateRect, BeginPaint
extern UpdateWindow, TrackMouseEvent, ReleaseCapture, SendMessageW
extern GetCursorPos, WindowFromPoint
extern EndPaint, StretchDIBits, SetTimer, KillTimer, AdjustWindowRect, SetCursor
extern GetWindowLongW, SetWindowLongW, GetWindowPlacement, SetWindowPlacement
extern SetWindowPos, MonitorFromWindow, GetMonitorInfoW, SetProcessDPIAware
extern DragQueryFileW, DragFinish, CommandLineToArgvW, GetCommandLineW, LocalFree
extern GetFileAttributesW, FindFirstFileW, FindNextFileW, FindClose
extern CreateFileW, GetFileSizeEx, CreateFileMappingW, MapViewOfFile
extern UnmapViewOfFile, CloseHandle, CreateThread, Sleep, CreateEventW
extern WaitForSingleObject, ExitProcess
extern waveOutOpen, waveOutPrepareHeader, waveOutUnprepareHeader, waveOutWrite
extern waveOutReset, waveOutClose, waveOutGetPosition
extern PostMessageW, GetKeyState, GetTickCount64, WideCharToMultiByte
extern SystemParametersInfoW, GetEnvironmentVariableW, GetModuleFileNameW
extern malloc, free, memcpy, wcslen, _wcsicmp

global main
global plat_audio_open, plat_audio_write, plat_audio_flush, plat_audio_close
global plat_audio_queued
global plat_map, plat_unmap, plat_sleep, plat_title, plat_cmp
global plat_wake, plat_ms, plat_font_scan, plat_font_dir
global plat_thread, plat_join

WM_DESTROY      equ 0x0002
WM_SIZE         equ 0x0005
WM_PAINT        equ 0x000F
WM_ERASEBKGND   equ 0x0014
WM_SETCURSOR    equ 0x0020
WM_KEYDOWN      equ 0x0100
WM_TIMER        equ 0x0113
WM_DROPFILES    equ 0x0233
WM_LBUTTONDOWN  equ 0x0201
WM_SIZING       equ 0x0214
WM_MOUSEMOVE    equ 0x0200
WM_MOUSELEAVE   equ 0x02A3
WM_NCLBUTTONDOWN equ 0x00A1
WM_EXITSIZEMOVE equ 0x0232
HTCAPTION       equ 2
TME_LEAVE       equ 2
FIRST_WAIT      equ 300            ; ms to wait for the first cover
T_FIRST         equ 2              ; its timer id
WM_APP          equ 0x8000
START_SIZE      equ 480                ; opens as a square
WS_OVERLAPPEDWINDOW equ 0x00CF0000
GWL_STYLE       equ -16
NBUF            equ 8
WAVEHDR_SZ      equ 48
WPATH           equ 2048           ; wchar_t per path buffer

section .data
w_class     dw __utf16__("Peep"), 0
w_title     dw __utf16__("Peep"), 0
w_star      dw __utf16__("\*"), 0
w_appdata   dw __utf16__("APPDATA"), 0
w_peepfonts dw __utf16__("\Peep\fonts"), 0
w_fonts     dw __utf16__("fonts"), 0
s_fontdir   db "%APPDATA%\Peep\fonts", 0

section .bss
alignb 16
hinst       resq 1
hwnd        resq 1
fb          resq 1
fb_w        resd 1
fb_h        resd 1
bmi         resb 44
fullscreen  resd 1
hidden      resd 1                 ; not shown yet: waiting for the first cover
tracking    resd 1                 ; TrackMouseEvent armed: the pointer is over us
cur_hidden  resd 1                 ; the pointer is hidden right now (fullscreen idle)
mm_flag     resd 1                 ; a redraw is wanted after this mouse move
last_mouse  resd 1                 ; position of the last mouse move
tme         resb 24                ; TRACKMOUSEEVENT
cur_pt      resq 1                 ; POINT
alignb 8
saved_wp    resb 48           ; WINDOWPLACEMENT (44)
mon_info    resb 40           ; MONITORINFO
hwo         resq 1
wev         resq 1
next_buf    resd 1
w_frames    resd 1                 ; frames written since open / last reset
mmt         resb 12                ; MMTIME
alignb 16
hdrs        resb WAVEHDR_SZ * NBUF
wbufs       resb CHUNK * 4 * NBUF
dropbuf     resw 32768
fontdirw    resw WPATH
art_w       resd 1
art_h       resd 1
tsz         resd 2
wrect       resd 4

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
    mov  dword [L(4)], 3               ; CS_VREDRAW | CS_HREDRAW: repaint all on resize
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
    ; outer size for a square client area
    mov  dword [L(128)], 0
    mov  dword [L(132)], 0
    mov  dword [L(136)], START_SIZE
    mov  dword [L(140)], START_SIZE
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
    ; wait (at most FIRST_WAIT ms) for the first track's cover, so the window
    ; appears at the cover's size and shape instead of as a black square
    mov  dword [hidden], 1
    mov  A1, [hwnd]
    mov  A2, T_FIRST
    mov  A3, FIRST_WAIT
    xor  A4, A4
    call SetTimer
.freeargs:
    mov  A1, r13
    call LocalFree
.show:
    cmp  dword [hidden], 0
    jne  .msg
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
    je   .timer
    cmp  r12d, WM_SIZE
    je   .size
    cmp  r12d, WM_APP
    je   .app
    cmp  r12d, WM_LBUTTONDOWN
    je   .click
    cmp  r12d, WM_SIZING
    je   .sizing
    cmp  r12d, WM_MOUSEMOVE
    je   .mmove
    cmp  r12d, WM_MOUSELEAVE
    je   .mleave
    cmp  r12d, WM_EXITSIZEMOVE
    je   .exitmove
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
    mov  A1d, [fb_w]
    mov  A2d, [fb_h]
    call core_note_size
    ; paint now, inside the sizing loop, so every drag step shows a whole
    ; frame instead of the old pixels clipped to the new size
    mov  A1, rbx
    xor  A2, A2
    xor  A3, A3
    call InvalidateRect
    mov  A1, rbx
    call UpdateWindow
    jmp  .zero
.app:                                  ; the player has a new track
    call core_take_info
    test eax, eax
    jz   .inval                        ; a seek: redraw with the new position
    call apply_size
    call show_once
    jmp  .inval
.timer:
    cmp  r13, T_FIRST
    jne  .tick
    mov  A1, rbx
    mov  A2, T_FIRST
    call KillTimer
    call show_once                     ; the cover is late: show the window anyway
    jmp  .zero
.tick:                                 ; clock tick: paint only if it shows
    call core_tick_needed              ; something new, then re-aim the timer
    test eax, eax
    jnz  .inval
    jmp  .rearm
.click:
    movsx A1d, r14w                    ; x
    mov  eax, r14d
    shr  eax, 16
    movsx A2d, ax                      ; y
    call core_click
    test eax, eax
    jnz  .inval
    cmp  dword [fullscreen], 0
    jne  .zero
    ; not on a control: drag the window as if by its title bar
    call ReleaseCapture
    mov  A1, rbx
    mov  A2, WM_NCLBUTTONDOWN
    mov  A3, HTCAPTION
    xor  A4, A4
    call SendMessageW
    jmp  .zero
.mmove:                                ; the pointer moved over the window
    mov  dword [mm_flag], 0
    cmp  r14d, [last_mouse]            ; Windows also sends moves that aren't
    je   .mm1                          ; one: only a new position counts
    mov  [last_mouse], r14d
    call core_motion                   ; fullscreen: the controls come back
    mov  [mm_flag], eax
.mm1:
    cmp  dword [tracking], 0
    jne  .mm2
    mov  dword [tracking], 1
    mov  dword [tme], 24               ; cbSize
    mov  dword [tme + 4], TME_LEAVE
    mov  [tme + 8], rbx                ; hwndTrack
    mov  dword [tme + 16], 0
    lea  A1, [tme]
    call TrackMouseEvent
    mov  A1, 1
    call core_hover                    ; windowed: controls on
    or   [mm_flag], eax
.mm2:
    call win_update_cursor             ; fullscreen: the pointer shows again
    cmp  dword [mm_flag], 0
    jne  .inval
    jmp  .zero
.mleave:                               ; pointer gone: controls fade out
    mov  dword [tracking], 0
    cmp  dword [fullscreen], 0
    jne  .zero                         ; fullscreen: always under the pointer
    xor  A1, A1
    call core_hover
    test eax, eax
    jnz  .inval
    jmp  .zero
.exitmove:                             ; a drag ended: is the pointer still here?
    mov  dword [tracking], 0
    lea  A1, [cur_pt]
    call GetCursorPos
    mov  A1, [cur_pt]
    call WindowFromPoint
    cmp  rax, rbx
    je   .mmove
    jmp  .mleave
.sizing:
    cmp  dword [art_w], 0
    je   .def
    mov  A1, r13
    mov  A2, r14
    call keep_aspect
    jmp  .one
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
.rearm:
    call win_update_cursor             ; fullscreen: maybe it is time to hide the pointer
    call core_next_wake                ; next redraw: clock tick, notice expiry
    test eax, eax
    js   .notimer
    mov  A1, rbx
    mov  A2, 1
    mov  A3d, eax
    xor  A4, A4
    call SetTimer
    jmp  .zero
.notimer:
    mov  A1, rbx
    mov  A2, 1
    call KillTimer
    jmp  .zero
.cursor:
    cmp  dword [fullscreen], 0
    je   .def
    cmp  r14w, 1                       ; HTCLIENT
    jne  .def
    cmp  dword [cur_hidden], 0
    je   .def                          ; fullscreen, pointer moving: the normal arrow
    xor  A1, A1
    call SetCursor                     ; pointer still: hidden, with the controls
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
    cmp  eax, 0x09                     ; Tab (Shift+Tab: blank)
    je   .ktab
    cmp  eax, 'F'
    je   .kfont
    cmp  eax, 'V'
    je   .kver
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
.ktab:
    mov  A1, 0x10                      ; VK_SHIFT
    call GetKeyState
    mov  ecx, K_UI
    test ax, ax
    jns  .kcore
    mov  ecx, K_BLANK
    jmp  .kcore
.kfont:  mov ecx, K_FONT
    jmp  .kcore
.kver:   mov ecx, K_VERSION
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

; show_once(): show the window, the first time only
FUNC show_once, 0
    cmp  dword [hidden], 0
    je   .r
    mov  dword [hidden], 0
    mov  A1, [hwnd]
    mov  A2, T_FIRST
    call KillTimer
    mov  A1, [hwnd]
    mov  A2, 10                        ; SW_SHOWDEFAULT
    call ShowWindow
.r: RET_

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
    mov  A1d, 1
    call core_set_fullscreen           ; the pointer stays usable and just moved
    call win_update_cursor
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
    xor  A1d, A1d
    call core_set_fullscreen
    mov  dword [tracking], 0
    lea  A1, [cur_pt]                  ; is the pointer still over the window?
    call GetCursorPos
    mov  A1, [cur_pt]
    call WindowFromPoint
    xor  ecx, ecx
    cmp  rax, [hwnd]
    sete cl
    mov  A1d, ecx
    call core_hover
    call win_update_cursor
    RET_

; win_update_cursor(): hide or show the pointer as core_cursor_hidden says; the
; same moment the controls finish fading out (fullscreen, pointer still).
FUNC win_update_cursor, 0
    call core_cursor_hidden
    cmp  eax, [cur_hidden]
    je   .r
    mov  [cur_hidden], eax
    test eax, eax
    jz   .show
    xor  A1, A1
    call SetCursor
    RET_
.show:
    xor  A1, A1
    mov  A2, 32512                     ; IDC_ARROW
    call LoadCursorW
    mov  A1, rax
    call SetCursor
.r: RET_

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

; plat_title(wpath, out, max): basename without extension, UTF-8
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
    mov  byte [r12], 0
    sub  r15, r14
    shr  r15, 1                        ; UTF-16 units
    jz   .r
    mov  A1d, 65001                    ; CP_UTF8
    xor  A2, A2
    mov  A3, r14
    mov  A4, r15
    mov  SARG(5), r12
    lea  rax, [r13 - 1]
    mov  SARG(6), rax
    mov  qword SARG(7), 0
    mov  qword SARG(8), 0
    call WideCharToMultiByte
    mov  byte [r12 + rax], 0
.r: RET_

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

; ---- 0.2.0: window shape, wake-ups, fonts -------------------------------

; apply_size(): new track info arrived -> follow its cover's shape and size
FUNC apply_size, 0
    lea  A1, [art_w]
    lea  A2, [art_h]
    call core_art_aspect
    test eax, eax
    jnz  .art
    mov  dword [art_w], 0              ; no cover: free aspect
    RET_
.art:
    cmp  dword [fullscreen], 0
    jne  .r
    mov  A1, 0x30                      ; SPI_GETWORKAREA
    xor  A2, A2
    lea  A3, [wrect]
    xor  A4, A4
    call SystemParametersInfoW
    mov  A1d, [wrect + 8]
    sub  A1d, [wrect]
    mov  A2d, [wrect + 12]
    sub  A2d, [wrect + 4]
    mov  A3d, [fb_w]
    mov  A4d, [fb_h]
    lea  rax, [tsz]
    mov  SARG(5), rax
    call core_target_size
    test eax, eax
    jz   .r
    mov  dword [wrect], 0              ; client size -> window size
    mov  dword [wrect + 4], 0
    mov  eax, [tsz]
    mov  [wrect + 8], eax
    mov  eax, [tsz + 4]
    mov  [wrect + 12], eax
    lea  A1, [wrect]
    mov  A2, WS_OVERLAPPEDWINDOW
    xor  A3, A3
    call AdjustWindowRect
    mov  A1, [hwnd]
    xor  A2, A2
    xor  A3, A3
    xor  A4, A4
    mov  eax, [wrect + 8]
    sub  eax, [wrect]
    mov  SARG(5), rax
    mov  eax, [wrect + 12]
    sub  eax, [wrect + 4]
    mov  SARG(6), rax
    mov  qword SARG(7), 0x16           ; NOMOVE | NOZORDER | NOACTIVATE
    call SetWindowPos
.r: RET_

; keep_aspect(edge, RECT*): WM_SIZING — hold the cover's shape while dragging
FUNC keep_aspect, 16
    ARGS r12, rbx
    cmp  dword [fullscreen], 0
    jne  .r
    mov  dword [L(0)], 0               ; frame size from an empty client
    mov  dword [L(4)], 0
    mov  dword [L(8)], 0
    mov  dword [L(12)], 0
    lea  A1, [L(0)]
    mov  A2, WS_OVERLAPPEDWINDOW
    xor  A3, A3
    call AdjustWindowRect
    mov  r14d, [L(8)]
    sub  r14d, [L(0)]                  ; frame width
    mov  r15d, [L(12)]
    sub  r15d, [L(4)]                  ; frame height
    mov  esi, [rbx + 8]
    sub  esi, [rbx]
    sub  esi, r14d                     ; client width
    mov  edi, [rbx + 12]
    sub  edi, [rbx + 4]
    sub  edi, r15d                     ; client height
    cmp  r12d, 3                       ; top / bottom edges: width follows
    je   .wfromh
    cmp  r12d, 6
    je   .wfromh
    mov  eax, esi                      ; otherwise height follows width
    imul eax, [art_h]
    cdq
    idiv dword [art_w]
    add  eax, r15d
    cmp  r12d, 4                       ; top-left / top-right: move the top
    je   .top
    cmp  r12d, 5
    je   .top
    add  eax, [rbx + 4]
    mov  [rbx + 12], eax
    RET_
.top:
    mov  ecx, [rbx + 12]
    sub  ecx, eax
    mov  [rbx + 4], ecx
    RET_
.wfromh:
    mov  eax, edi
    imul eax, [art_w]
    cdq
    idiv dword [art_h]
    add  eax, r14d
    add  eax, [rbx]
    mov  [rbx + 8], eax
.r: RET_

FUNC plat_wake, 0
    mov  A1, [hwnd]
    mov  A2, WM_APP
    xor  A3, A3
    xor  A4, A4
    call PostMessageW
    RET_

; plat_thread(fn) -> rax thread handle, 0 on failure
FUNC plat_thread, 0
    mov  A3, A1                        ; start routine
    xor  A1, A1
    xor  A2, A2
    xor  A4, A4
    mov  qword SARG(5), 0
    mov  qword SARG(6), 0
    call CreateThread
    RET_

; plat_join(handle): wait for the thread to finish, then release it
FUNC plat_join, 0
    ARGS rbx
    mov  A1, rbx
    mov  A2d, 0xFFFFFFFF               ; INFINITE
    call WaitForSingleObject
    mov  A1, rbx
    call CloseHandle
    RET_

FUNC plat_ms, 0
    call GetTickCount64
    RET_

; plat_font_dir(out, max, short): where fonts go, for the on-screen hint
FUNC plat_font_dir, 0
    mov  rax, A1
    lea  rcx, [s_fontdir]
.l: mov  dl, [rcx]
    mov  [rax], dl
    test dl, dl
    jz   .r
    inc  rax
    inc  rcx
    jmp  .l
.r: RET_

; wcat(dst, src) -> rax end. Leaf.
wcat:
    mov  rax, A1
.l: mov  r10w, [A2]
    mov  [rax], r10w
    test r10w, r10w
    jz   .r
    add  rax, 2
    add  A2, 2
    jmp  .l
.r: ret

; plat_font_scan(list): %APPDATA%\Peep\fonts and a "fonts" folder next to Peep.exe
FUNC plat_font_scan, 0
    ARGS r12
    lea  A1, [w_appdata]
    lea  A2, [fontdirw]
    mov  A3, WPATH - 32
    call GetEnvironmentVariableW
    test eax, eax
    jz   .exe
    cmp  eax, WPATH - 32
    jae  .exe
    lea  A1, [fontdirw]
    lea  A1, [A1 + rax*2]
    lea  A2, [w_peepfonts]
    call wcat
    mov  A1, r12
    lea  A2, [fontdirw]
    call scan_fonts
.exe:
    xor  A1, A1
    lea  A2, [fontdirw]
    mov  A3, WPATH - 32
    call GetModuleFileNameW
    test eax, eax
    jz   .r
    cmp  eax, WPATH - 32
    jae  .r
    lea  rsi, [fontdirw]
    lea  rdi, [rsi + rax*2]
.bs:cmp  rdi, rsi                      ; cut after the last backslash
    jbe  .r
    sub  rdi, 2
    cmp  word [rdi], '\'
    jne  .bs
    lea  A1, [rdi + 2]
    lea  A2, [w_fonts]
    call wcat
    mov  A1, r12
    lea  A2, [fontdirw]
    call scan_fonts
.r: RET_

; scan_fonts(list, wdir): add every .ttf/.otf/.ttc file
FUNC scan_fonts, WPATH*2 + 608
    ARGS r12, r13
    mov  A1, r13
    call wcslen
    mov  rbx, rax
    lea  rax, [rbx + 4]
    cmp  rax, WPATH
    jae  .r
    lea  rdi, [L(0)]
    mov  rsi, r13
    mov  rcx, rbx
    rep  movsw
    mov  dword [rdi], 0x002A005C       ; L"\*"
    mov  word [rdi + 4], 0
    lea  A1, [L(0)]
    lea  A2, [L(WPATH*2)]
    call FindFirstFileW
    cmp  rax, -1
    je   .r
    mov  r15, rax
    lea  rax, [L(2)]
    lea  rax, [rax + rbx*2]
    mov  [L(WPATH*2 + 600)], rax
.ent:
    test dword [L(WPATH*2)], 0x10      ; skip folders
    jnz  .nx
    lea  rsi, [L(WPATH*2 + 44)]
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
    mov  A1, [L(WPATH*2 + 600)]
    call ext4w
    cmp  eax, 'ttf'
    je   .add
    cmp  eax, 'otf'
    je   .add
    cmp  eax, 'ttc'
    jne  .nx
.add:
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
.r: RET_

; ext4w(wname) -> eax lower-cased packed extension (<= 4 ASCII chars) or 0
FUNC ext4w, 0
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
    jz   .r
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
.no:xor  eax, eax
.r: RET_

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
    mov  dword [w_frames], 0
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
    add  [w_frames], r13d
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
    call release_all                   ; ... and the play position restarts at 0
    mov  dword [w_frames], 0
.r: RET_

; plat_audio_queued() -> rax frames written but not yet heard (0 if unknown)
FUNC plat_audio_queued, 0
    xor  ebx, ebx
    cmp  qword [hwo], 0
    je   .r
    mov  dword [mmt], 2                ; TIME_SAMPLES
    mov  A1, [hwo]
    lea  A2, [mmt]
    mov  A3, 12
    call waveOutGetPosition
    test eax, eax
    jnz  .r
    cmp  dword [mmt], 2                ; the driver may answer in other units
    jne  .r
    mov  eax, [w_frames]
    sub  eax, [mmt + 4]
    jle  .r
    mov  ebx, eax
.r: mov  rax, rbx
    RET_

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
