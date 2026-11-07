// Liberated Peep (arm64): glue shared by every .s file. GNU as syntax.
//
//   Linux : aarch64-linux-gnu-as -I arm64 arm64/peep.s -o peep.o
//   macOS : add  --defsym APPLE=1  (Mach-O names get a leading underscore). UNTESTED.
//
// AAPCS64: args x0-x7, result x0, callee-saved x19-x28 + x29/x30, sp 16-byte aligned.
// x18 is never touched (reserved on Apple and Windows). Only v0-v7 are used.

.macro FUNC name                      // exported entry point
    .text
    .balign 4
.ifdef APPLE
    .globl _\name
_\name:
.else
    .globl \name
    .type \name, %function
\name:
.endif
.L_\name:                             // local alias, so internal calls need no underscore logic
.endm

.macro FUNCL name                     // file-local routine
    .balign 4
\name:
.endm

// 32-bit constant into a w register
.macro MOV32 reg, val
    movz \reg, #((\val) & 0xffff)
    movk \reg, #(((\val) >> 16) & 0xffff), lsl #16
.endm

// Exported entry points that call routines which use the x19-x28 register convention:
// save all callee-saved registers, then carve 512 bytes of locals addressed from x28.
.macro ENTER
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    sub  sp, sp, #512
    mov  x28, sp
.endm
.macro LEAVE
    add  sp, sp, #512
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #96
    ret
.endm

.macro DATA_RO                        // read-only-after-relocation data
.ifdef APPLE
    .section __DATA,__const
.else
    .section .data.rel.ro,"aw",%progbits
.endif
    .balign 8
.endm

.macro NO_EXEC_STACK
.ifndef APPLE
    .section .note.GNU-stack,"",%progbits
.endif
.endm

// struct peep (peep.h)
.equ P_CODEC, 0
.equ P_SRC,   8
.equ P_LEN,   16
.equ P_POS,   24
.equ P_TOTAL, 32
.equ P_RATE,  40
.equ P_CH,    44
.equ P_GAIN,  48
.equ P_KIND,  52
.equ P_DATA,  56
.equ P_CTX,   64
.equ P_ZERO,  128                     // end of the part a failed codec open may dirty
.equ P_WORK,  128
.equ P_WSIZE, 136
.equ P_WNEED, 144
.equ P_SIZE,  160
// struct peep_codec
.equ C_OPEN,  0
.equ C_READ,  8
.equ C_SEEK,  16
.equ C_CLOSE, 24
.equ KIND_WAV, 1
.equ KIND_COD, 2
