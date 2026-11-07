// Liberated Peep 0.2.0 (arm64): the core. Same API and behaviour as peep.asm (x86-64).
// Freestanding: no libc, no malloc, no syscalls, no writable globals. See peep.h.

.include "abi_a64.inc"

.equ SCR,      192                    // frames of scratch for >2-channel codecs
.equ SCRBYTES, 192 * 8 * 2            // 3072
.equ FRAMESZ,  SCRBYTES + 16

    .text

// ---------------------------------------------------------------------------
// Internal helpers: private register convention, leaf routines.
// ---------------------------------------------------------------------------

// mix_st: stereo int16 -> stereo int16 with gain, in place or not.
//   x9 = src, x10 = dst, x11 = frames, w12 = gain (0..256)
//   (x * gain) >> 8 with an arithmetic shift: identical to the x86 version.
//   clobbers x13-x14, v0-v2, v7
FUNCL mix_st
    cmp   w12, #256
    b.ne  .Lms_scale
    cmp   x9, x10
    b.eq  .Lms_ret
    lsl   x13, x11, #2
.Lms_cp32:
    cmp   x13, #32
    b.lo  .Lms_cp4
    ldp   q0, q1, [x9], #32
    stp   q0, q1, [x10], #32
    sub   x13, x13, #32
    b     .Lms_cp32
.Lms_cp4:
    cbz   x13, .Lms_ret
.Lms_cp4l:
    ldr   w14, [x9], #4
    str   w14, [x10], #4
    subs  x13, x13, #4
    b.ne  .Lms_cp4l
.Lms_ret:
    ret
.Lms_scale:
    dup   v7.8h, w12
    lsr   x13, x11, #2
    cbz   x13, .Lms_tail
.Lms_v:
    ld1   {v0.8h}, [x9], #16          // 4 frames
    smull  v1.4s, v0.4h, v7.4h
    smull2 v2.4s, v0.8h, v7.8h
    shrn   v0.4h, v1.4s, #8           // |x*g>>8| <= |x|: the narrowing never loses bits
    shrn2  v0.8h, v2.4s, #8
    st1   {v0.8h}, [x10], #16
    subs  x13, x13, #1
    b.ne  .Lms_v
.Lms_tail:
    ands  x13, x11, #3
    b.eq  .Lms_ret
.Lms_t:
    ldrsh w14, [x9], #2
    mul   w14, w14, w12
    asr   w14, w14, #8
    strh  w14, [x10], #2
    ldrsh w14, [x9], #2
    mul   w14, w14, w12
    asr   w14, w14, #8
    strh  w14, [x10], #2
    subs  x13, x13, #1
    b.ne  .Lms_t
    ret

// mix_gen: any channel count -> stereo with gain.
//   x9 = src, x10 = dst, x11 = frames, w12 = gain, x13 = source bytes per frame,
//   x14 = byte offset of the right channel (0 = mono)       clobbers x15
FUNCL mix_gen
    cbz   x11, .Lmg_d
.Lmg_l:
    ldrsh w15, [x9]
    mul   w15, w15, w12
    asr   w15, w15, #8
    strh  w15, [x10]
    ldrsh w15, [x9, x14]
    mul   w15, w15, w12
    asr   w15, w15, #8
    strh  w15, [x10, #2]
    add   x9, x9, x13
    add   x10, x10, #4
    subs  x11, x11, #1
    b.ne  .Lmg_l
.Lmg_d:
    ret

// ---------------------------------------------------------------------------
// int peep_open(peep *p, const peep_codec *const *codecs, const void *data, size_t len,
//               void *work, size_t work_size)
// ---------------------------------------------------------------------------
FUNC peep_open
    stp   x29, x30, [sp, #-80]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    stp   x21, x22, [sp, #32]
    stp   x23, x24, [sp, #48]
    mov   x19, x0                     // p
    mov   x20, x1                     // codecs
    mov   x21, x2                     // data
    mov   x22, x3                     // len
    stp   xzr, xzr, [x19]             // zero the whole struct
    stp   xzr, xzr, [x19, #16]
    stp   xzr, xzr, [x19, #32]
    stp   xzr, xzr, [x19, #48]
    stp   xzr, xzr, [x19, #64]
    stp   xzr, xzr, [x19, #80]
    stp   xzr, xzr, [x19, #96]
    stp   xzr, xzr, [x19, #112]
    stp   xzr, xzr, [x19, #128]
    stp   xzr, xzr, [x19, #144]
    mov   w6, #256
    str   w6, [x19, #P_GAIN]
    str   x21, [x19, #P_SRC]
    str   x22, [x19, #P_LEN]
    str   x4, [x19, #P_WORK]          // workspace for codecs that need one
    str   x5, [x19, #P_WSIZE]

    // ---- built-in 16-bit PCM WAV --------------------------------------------
    cmp   x22, #44
    b.lo  .Lpo_codecs
    ldr   w0, [x21]
    MOV32 w1, 0x46464952              // 'RIFF'
    cmp   w0, w1
    b.ne  .Lpo_codecs
    ldr   w0, [x21, #8]
    MOV32 w1, 0x45564157              // 'WAVE'
    cmp   w0, w1
    b.ne  .Lpo_codecs
    mov   x23, #12                    // chunk cursor
.Lpo_chunk:
    add   x0, x23, #8
    cmp   x0, x22
    b.hi  .Lpo_nowav
    add   x3, x21, x23
    ldr   w1, [x3]                    // chunk id
    ldr   w2, [x3, #4]                // chunk size
    add   x4, x23, #8                 // body offset
    MOV32 w5, 0x20746d66              // 'fmt '
    cmp   w1, w5
    b.ne  .Lpo_notfmt
    cmp   w2, #16
    b.lo  .Lpo_nowav
    add   x6, x4, #16
    cmp   x6, x22
    b.hi  .Lpo_nowav
    add   x7, x21, x4                 // body
    ldrh  w8, [x7]                    // format tag
    cmp   w8, #1
    b.eq  .Lpo_tagok
    mov   w9, #0xFFFE                 // extensible: accept only the PCM subformat
    cmp   w8, w9
    b.ne  .Lpo_nowav
    cmp   w2, #40
    b.lo  .Lpo_nowav
    add   x6, x4, #40
    cmp   x6, x22
    b.hi  .Lpo_nowav
    ldrh  w8, [x7, #24]
    cmp   w8, #1
    b.ne  .Lpo_nowav
.Lpo_tagok:
    ldrh  w8, [x7, #14]               // 16 bits per sample
    cmp   w8, #16
    b.ne  .Lpo_nowav
    ldrh  w8, [x7, #2]
    str   w8, [x19, #P_CH]
    ldr   w8, [x7, #4]
    str   w8, [x19, #P_RATE]
    b     .Lpo_next
.Lpo_notfmt:
    MOV32 w5, 0x61746164              // 'data'
    cmp   w1, w5
    b.ne  .Lpo_next
    ldr   w8, [x19, #P_RATE]          // data before fmt: leave it to a codec
    cbz   w8, .Lpo_nowav
    ldr   w8, [x19, #P_CH]
    sub   w9, w8, #1
    cmp   w9, #7                      // 1..8 channels
    b.hi  .Lpo_nowav
    sub   x6, x22, x4                 // bytes actually present
    cmp   x2, x6
    csel  x2, x2, x6, lo              // clamp truncated / unknown-length files
    add   x7, x21, x4
    str   x7, [x19, #P_DATA]
    lsl   w8, w8, #1                  // bytes per frame
    udiv  x2, x2, x8
    str   x2, [x19, #P_TOTAL]
    mov   w0, #KIND_WAV
    str   w0, [x19, #P_KIND]
    b     .Lpo_validate
.Lpo_next:
    and   x6, x2, #1                  // odd-sized chunks carry a pad byte
    add   x4, x4, x2
    add   x4, x4, x6
    mov   x23, x4
    b     .Lpo_chunk
.Lpo_nowav:
    str   xzr, [x19, #P_RATE]         // rate + channels
    str   xzr, [x19, #P_TOTAL]
    str   xzr, [x19, #P_DATA]

    // ---- plugged-in codecs ----------------------------------------------------
.Lpo_codecs:
    cbz   x20, .Lpo_fail
.Lpo_cl:
    ldr   x24, [x20]
    cbz   x24, .Lpo_fail
    str   x24, [x19, #P_CODEC]
    mov   x0, x19
    mov   x1, x21
    mov   x2, x22
    ldr   x3, [x24, #C_OPEN]
    blr   x3
    cbnz  w0, .Lpo_gotc
    add   x1, x19, #P_RATE            // wipe whatever a failed open left behind
    stp   xzr, xzr, [x1]
    stp   xzr, xzr, [x1, #16]
    stp   xzr, xzr, [x1, #32]
    stp   xzr, xzr, [x1, #48]
    stp   xzr, xzr, [x1, #64]
    str   xzr, [x1, #80]
    mov   w1, #256
    str   w1, [x19, #P_GAIN]
    add   x20, x20, #8
    b     .Lpo_cl
.Lpo_gotc:
    mov   w0, #KIND_COD
    str   w0, [x19, #P_KIND]

    // ---- sanity: 1..8 channels, 1 kHz..768 kHz ------------------------------
.Lpo_validate:
    ldr   w0, [x19, #P_CH]
    sub   w0, w0, #1
    cmp   w0, #7
    b.hi  .Lpo_bad
    ldr   w0, [x19, #P_RATE]
    sub   w0, w0, #1000
    MOV32 w1, 767000
    cmp   w0, w1
    b.hi  .Lpo_bad
    mov   w0, #1
    b     .Lpo_out
.Lpo_bad:
    mov   x0, x19
    bl    .L_peep_close
.Lpo_fail:
    mov   w0, #0
.Lpo_out:
    ldp   x19, x20, [sp, #16]
    ldp   x21, x22, [sp, #32]
    ldp   x23, x24, [sp, #48]
    ldp   x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------------
// size_t peep_fill(peep *p, int16_t *out, size_t frames)
// ---------------------------------------------------------------------------
FUNC peep_fill
    stp   x29, x30, [sp, #-80]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    stp   x21, x22, [sp, #32]
    stp   x23, x24, [sp, #48]
    sub   sp, sp, #FRAMESZ
    mov   x19, x0                     // p
    mov   x20, x1                     // out
    mov   x21, x2                     // frames
    ldr   w0, [x19, #P_GAIN]
    mov   w1, #256
    cmp   w0, w1
    csel  w22, w0, w1, lo             // gain, clamped to 256
    ldr   w0, [x19, #P_KIND]
    cmp   w0, #KIND_WAV
    b.eq  .Lpf_wav
    cmp   w0, #KIND_COD
    b.eq  .Lpf_cod
.Lpf_zero:
    mov   x0, #0
    b     .Lpf_ret

    // ---- built-in WAV: read, scale and write in one pass ---------------------
.Lpf_wav:
    ldr   x0, [x19, #P_TOTAL]
    ldr   x1, [x19, #P_POS]
    subs  x0, x0, x1
    b.lo  .Lpf_zero                   // pos past the end (never by the API)
    cmp   x21, x0
    csel  x21, x21, x0, lo            // frames = min(frames, left)
    cbz   x21, .Lpf_zero
    ldr   w2, [x19, #P_CH]
    lsl   x13, x2, #1                 // source bytes per frame
    mul   x9, x1, x13
    ldr   x3, [x19, #P_DATA]
    add   x9, x9, x3
    mov   x10, x20
    mov   x11, x21
    mov   w12, w22
    cmp   w2, #2
    b.ne  .Lpf_wgen
    bl    mix_st
    b     .Lpf_wdone
.Lpf_wgen:
    mov   x14, #0                     // mono: right = left
    cmp   w2, #1
    b.eq  .Lpf_w1
    mov   x14, #2                     // 3+ channels: the first two
.Lpf_w1:
    bl    mix_gen
.Lpf_wdone:
    ldr   x0, [x19, #P_POS]
    add   x0, x0, x21
    str   x0, [x19, #P_POS]
    mov   x0, x21
    b     .Lpf_ret

    // ---- codec -------------------------------------------------------------------
.Lpf_cod:
    ldr   w2, [x19, #P_CH]
    cmp   w2, #2
    b.ne  .Lpf_multi
    ldr   x3, [x19, #P_CODEC]         // stereo: the codec writes straight into out
    ldr   x3, [x3, #C_READ]
    mov   x0, x19
    mov   x1, x20
    mov   x2, x21
    blr   x3
    cmp   x0, x21
    csel  x23, x0, x21, lo
    mov   x9, x20
    mov   x10, x20
    mov   x11, x23
    mov   w12, w22
    bl    mix_st                      // no-op at unity gain
    ldr   x0, [x19, #P_POS]
    add   x0, x0, x23
    str   x0, [x19, #P_POS]
    mov   x0, x23
    b     .Lpf_ret
.Lpf_multi:                           // mono / 3+ channels: via stack scratch
    mov   x23, #0                     // frames produced
.Lpf_ml:
    cbz   x21, .Lpf_mdone
    mov   x0, #SCR
    cmp   x21, x0
    csel  x24, x21, x0, lo            // chunk
    ldr   x3, [x19, #P_CODEC]
    ldr   x3, [x3, #C_READ]
    mov   x0, x19
    mov   x1, sp
    mov   x2, x24
    blr   x3
    cbz   x0, .Lpf_mdone
    cmp   x0, x24
    csel  x24, x0, x24, lo
    mov   x9, sp
    mov   x10, x20
    mov   x11, x24
    mov   w12, w22
    ldr   w2, [x19, #P_CH]
    lsl   x13, x2, #1
    mov   x14, #0
    cmp   w2, #1
    b.eq  .Lpf_m1
    mov   x14, #2
.Lpf_m1:
    bl    mix_gen
    add   x20, x20, x24, lsl #2
    add   x23, x23, x24
    sub   x21, x21, x24
    b     .Lpf_ml
.Lpf_mdone:
    ldr   x0, [x19, #P_POS]
    add   x0, x0, x23
    str   x0, [x19, #P_POS]
    mov   x0, x23
.Lpf_ret:
    add   sp, sp, #FRAMESZ
    ldp   x19, x20, [sp, #16]
    ldp   x21, x22, [sp, #32]
    ldp   x23, x24, [sp, #48]
    ldp   x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------------
// void peep_seek(peep *p, uint64_t frame)
// ---------------------------------------------------------------------------
FUNC peep_seek
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    mov   x19, x0
    mov   x20, x1
    ldr   w2, [x19, #P_KIND]
    cbz   w2, .Lps_r
    ldr   x3, [x19, #P_TOTAL]
    cmp   w2, #KIND_WAV
    b.eq  .Lps_clamp                  // built-in WAV: always clamp, even at 0
    cbz   x3, .Lps_nc                 // codec with unknown length: no clamp
.Lps_clamp:
    cmp   x20, x3
    csel  x20, x20, x3, lo
.Lps_nc:
    str   x20, [x19, #P_POS]
    cmp   w2, #KIND_COD
    b.ne  .Lps_r
    ldr   x3, [x19, #P_CODEC]
    ldr   x3, [x3, #C_SEEK]
    cbz   x3, .Lps_r
    mov   x0, x19
    mov   x1, x20
    blr   x3
.Lps_r:
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------------
// void peep_close(peep *p)
// ---------------------------------------------------------------------------
FUNC peep_close
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    str   x19, [sp, #16]
    mov   x19, x0
    ldr   w1, [x19, #P_KIND]
    cmp   w1, #KIND_COD
    b.ne  .Lpc_z
    ldr   x2, [x19, #P_CODEC]
    ldr   x2, [x2, #C_CLOSE]
    cbz   x2, .Lpc_z
    mov   x0, x19
    blr   x2
.Lpc_z:
    str   wzr, [x19, #P_KIND]
    str   xzr, [x19, #P_POS]
    str   xzr, [x19, #P_TOTAL]
    ldr   x19, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret

NO_EXEC_STACK
