// SSVE kernels, ABI-correct this time.
//
// SMSTART zeroes the vector registers, and d8-d15 are CALLEE-SAVED under
// AAPCS. A streaming region that does not preserve them silently destroys
// the caller's live floating-point values — which showed up here as the
// timing harness's own doubles turning into NaN.
        .text

        .globl _ssve_add2
        .p2align 2
_ssve_add2:
        stp     d8,  d9,  [sp, #-64]!
        stp     d10, d11, [sp, #16]
        stp     d12, d13, [sp, #32]
        stp     d14, d15, [sp, #48]
        smstart sm
        mov     x4, #0
1:      whilelt p0.s, x4, x3
        b.none  2f
        ld1w    {z0.s}, p0/z, [x0, x4, lsl #2]
        ld1w    {z1.s}, p0/z, [x1, x4, lsl #2]
        fadd    z0.s, z0.s, z1.s
        st1w    {z0.s}, p0, [x2, x4, lsl #2]
        incw    x4
        b       1b
2:      smstop  sm
        ldp     d10, d11, [sp, #16]
        ldp     d12, d13, [sp, #32]
        ldp     d14, d15, [sp, #48]
        ldp     d8,  d9,  [sp], #64
        ret

        .globl _ssve_nop2
        .p2align 2
_ssve_nop2:
        stp     d8,  d9,  [sp, #-64]!
        stp     d10, d11, [sp, #16]
        stp     d12, d13, [sp, #32]
        stp     d14, d15, [sp, #48]
        smstart sm
        smstop  sm
        ldp     d10, d11, [sp, #16]
        ldp     d12, d13, [sp, #32]
        ldp     d14, d15, [sp, #48]
        ldp     d8,  d9,  [sp], #64
        ret

// Compute-bound: 8 FMAs per element, one load, one store. If SSVE is really
// 4x the width, a kernel that is NOT memory-bound should show it.
// void ssve_poly(const float *a, float *c, unsigned long n)
        .globl _ssve_poly
        .p2align 2
_ssve_poly:
        stp     d8,  d9,  [sp, #-64]!
        stp     d10, d11, [sp, #16]
        stp     d12, d13, [sp, #32]
        stp     d14, d15, [sp, #48]
        smstart sm
        mov     x3, #0
        fmov    z2.s, #1.0
1:      whilelt p0.s, x3, x2
        b.none  2f
        ld1w    {z0.s}, p0/z, [x0, x3, lsl #2]
        mov     z1.d, z2.d
        fmla    z1.s, p0/m, z0.s, z0.s
        fmla    z1.s, p0/m, z0.s, z1.s
        fmla    z1.s, p0/m, z0.s, z1.s
        fmla    z1.s, p0/m, z0.s, z1.s
        fmla    z1.s, p0/m, z0.s, z1.s
        fmla    z1.s, p0/m, z0.s, z1.s
        fmla    z1.s, p0/m, z0.s, z1.s
        fmla    z1.s, p0/m, z0.s, z1.s
        st1w    {z1.s}, p0, [x1, x3, lsl #2]
        incw    x3
        b       1b
2:      smstop  sm
        ldp     d10, d11, [sp, #16]
        ldp     d12, d13, [sp, #32]
        ldp     d14, d15, [sp, #48]
        ldp     d8,  d9,  [sp], #64
        ret
