; ----------------------------------------------------------------------------
; Peep — ABI glue shared by every .asm file.
;
; The same core source is assembled for two calling conventions:
;   Linux  : System V AMD64 (args rdi, rsi, rdx, rcx, r8, r9; stack args at [rsp])
;   Windows: Microsoft x64  (args rcx, rdx, r8, r9; 32-byte shadow, stack args at [rsp+32])
;
; Rules every function in Peep follows so one body works under both ABIs:
;   * FUNC/ENDFUNC save ALL callee-saved regs of BOTH ABIs (rbx rbp rsi rdi r12-r15).
;   * Values that must survive a call live in rbx/r12-r15 or in locals, never in
;     argument registers. Argument setup only reads from those, memory or immediates,
;     so the A1..A4 moves can be written in any order.
;   * Outgoing area of OUTSZ bytes sits at the bottom of every frame; it is the
;     Windows shadow space plus room for stack arguments on either ABI.
;   * Locals live above it: [L(n)].
; ----------------------------------------------------------------------------

%ifdef WIN64
    %define A1  rcx
    %define A2  rdx
    %define A3  r8
    %define A4  r9
    %define A1d ecx
    %define A2d edx
    %define A3d r8d
    %define A4d r9d
    ; stack argument n (n >= 5), 1-based
    %define SARG(n) [rsp + 32 + ((n)-5)*8]
    %define NARGREG 4
%else
    %define A1  rdi
    %define A2  rsi
    %define A3  rdx
    %define A4  rcx
    %define A5  r8
    %define A6  r9
    %define A1d edi
    %define A2d esi
    %define A3d edx
    %define A4d ecx
    %define A5d r8d
    %define A6d r9d
    %define SARG(n) [rsp + ((n)-7)*8]
    %define NARGREG 6
%endif

%define OUTSZ 112
%define L(n) (rsp + OUTSZ + (n))

; FUNC name, local_bytes
%macro FUNC 2
%1:
    push rbp
    mov  rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    ; after 8 pushes rsp is 16-byte aligned minus 8 -> add 8 to realign
    sub  rsp, OUTSZ + (((%2) + 15) & ~15) + 8
%endmacro

; FUNCL name, local_bytes: a function reached only through a pointer (the
; decoder's codec tables). Same as FUNC; the name documents that it is not
; called by label.
%macro FUNCL 2
    FUNC %1, %2
%endmacro

%macro RET_ 0
    lea  rsp, [rbp - 56]
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    pop  rbp
    ret
%endmacro

; Load incoming args into callee-saved registers right after FUNC.
%macro ARGS 1-4
    mov %1, A1
  %if %0 > 1
    mov %2, A2
  %endif
  %if %0 > 2
    mov %3, A3
  %endif
  %if %0 > 3
    mov %4, A4
  %endif
%endmacro

; ---------------------------------------------------------------------------
; Shared constants
; ---------------------------------------------------------------------------
CHUNK        equ 1024          ; frames decoded per step
MAXCH        equ 8             ; max channels accepted from a decoder

; core key codes (platform maps its native keys onto these)
K_PAUSE      equ 1
K_SEEKBACK   equ 2
K_SEEKFWD    equ 3
K_VOLUP      equ 4
K_VOLDN      equ 5
K_NEXT       equ 6
K_PREV       equ 7
K_UI         equ 8

; the decoder kernel's player object (src/peep.h, struct peep: 160 bytes)
PEEP_POS     equ 24            ; frame cursor
PEEP_TOTAL   equ 32            ; frames, 0 = unknown
PEEP_RATE    equ 40            ; Hz
PEEP_CH      equ 44            ; channels of the source
PEEP_GAIN    equ 48            ; q8, 256 = unity (Peep applies volume in its mixer)
PEEP_WNEED   equ 144           ; scratch bytes a codec wanted, valid after a failed open
PEEP_SIZE    equ 160
PEEP_STATE   equ 72            ; 56 bytes a codec may use: the C shim keeps its dec_t here

; the C shim's decoder object (src/codecs.c dec_t). Do not reorder.
DEC_RATE     equ 16
DEC_CH       equ 20
DEC_TOTAL    equ 24

; playlist object
PL_COUNT     equ 0
PL_CAP       equ 8
PL_ITEMS     equ 16
PL_SIZE      equ 24

; ---- 0.2.0 -----------------------------------------------------------------
K_BLANK      equ 9             ; Shift+Tab: black screen, keep playing
K_FONT       equ 10            ; F: cycle fonts
K_VERSION    equ 11            ; V: show the version for 2 s

; track info published by the player thread to the UI thread
INFO_TITLE   equ 0             ; UTF-8, 256 bytes
INFO_ARTIST  equ 256           ; UTF-8, 256 bytes
INFO_ART     equ 512           ; ART object or 0
INFO_SIZE    equ 528

; decoded cover art, reference counted (player + UI may both hold it)
ART_REF      equ 0             ; dword
ART_W        equ 4
ART_H        equ 8
ART_PX       equ 16            ; BGRX pixels
ART_HASH     equ 24
ART_LEN      equ 32
ART_SIZE     equ 40

; 5th argument as seen *inside* a FUNC (after its prologue)
%ifdef WIN64
    %define IN5 qword [rbp + 48]
    %define IN6 qword [rbp + 56]
%else
    %define IN5 r8
    %define IN6 r9
%endif
