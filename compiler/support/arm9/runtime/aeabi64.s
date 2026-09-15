// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

@ aeabi64.s — the 64-bit helpers an ARM program cannot do inline.
@ =========================================================================
@
@ The arm9 back end does i64 add/sub with `adds`/`adc` in line, but multiply,
@ divide and variable shifts need a call. Those calls used to be satisfied by
@ `-lgcc`, which is the last reason an arm9 link needed a GNU toolchain — the
@ device libc.so exports the 32-bit helpers (`__aeabi_uidiv`) but none of these.
@
@ Written by hand rather than lifted from libgcc: this is a handful of routines
@ with a fixed ABI, and copying compiled GPL code into the tree to avoid writing
@ forty instructions is a licensing question we do not need to have.
@
@ AAPCS, little-endian: a 64-bit value is r0:r1 (r0 low) and r2:r3 for the
@ second argument, returned in r0:r1. A count argument is r2.
@
@ One ARM property is load-bearing throughout: a REGISTER-specified shift uses
@ the low byte of the register and produces 0 for a count of 32 or more, so the
@ `x >> (32 - n)` term in a shift pair needs no special case at n == 0. (x86
@ masks the count to 5 bits and would need one.)

	.text
	.syntax unified
	.arch armv7-a

@ ─────────────────────────────────────────────────────────────────────────
@ u64 __ashldi3(u64 v, int cnt)   — v << cnt
	.globl	__ashldi3
	.type	__ashldi3, %function
__ashldi3:
	subs	r3, r2, #32
	bge	1f
	rsb	r3, r2, #32		@ 32 - cnt; reg-shift by 32 gives 0
	lsl	r1, r1, r2
	orr	r1, r1, r0, lsr r3
	lsl	r0, r0, r2
	bx	lr
1:	lsl	r1, r0, r3		@ cnt >= 32: hi = lo << (cnt - 32)
	mov	r0, #0
	bx	lr

@ u64 __lshrdi3(u64 v, int cnt)   — v >> cnt, unsigned
	.globl	__lshrdi3
	.type	__lshrdi3, %function
__lshrdi3:
	subs	r3, r2, #32
	bge	1f
	rsb	r3, r2, #32
	lsr	r0, r0, r2
	orr	r0, r0, r1, lsl r3
	lsr	r1, r1, r2
	bx	lr
1:	lsr	r0, r1, r3
	mov	r1, #0
	bx	lr

@ i64 __ashrdi3(i64 v, int cnt)   — v >> cnt, arithmetic
	.globl	__ashrdi3
	.type	__ashrdi3, %function
__ashrdi3:
	subs	r3, r2, #32
	bge	1f
	rsb	r3, r2, #32
	lsr	r0, r0, r2
	orr	r0, r0, r1, lsl r3
	asr	r1, r1, r2
	bx	lr
1:	asr	r0, r1, r3		@ cnt >= 32: lo = hi >>> (cnt - 32)
	asr	r1, r1, #31		@ …and hi becomes the sign
	bx	lr

@ u64 __muldi3(u64 a, u64 b)      — the low 64 bits of a * b
@ lo = alo*blo (64 bits); hi picks up the two cross terms, and ahi*bhi is
@ entirely above bit 63 so it never appears.
	.globl	__muldi3
	.type	__muldi3, %function
__muldi3:
	push	{r4, lr}
	umull	r4, ip, r0, r2
	mla	ip, r0, r3, ip
	mla	ip, r1, r2, ip
	mov	r0, r4
	mov	r1, ip
	pop	{r4, pc}

@ ─────────────────────────────────────────────────────────────────────────
@ The division core: restoring shift-subtract, 64 iterations.
@
@   in   r0:r1 = numerator, r2:r3 = divisor
@   out  r0:r1 = quotient,  r6:r7 = remainder   (r4, r5, r8, ip clobbered)
@
@ The quotient accumulates in the LOW bits the numerator vacates as it is
@ shifted left, which is why one 64-bit register pair holds both in turn and
@ the routine needs no separate quotient.
@
@ A zero divisor returns zero rather than trapping: the language calls this
@ undefined, and a data abort inside a helper is a far worse thing to debug
@ than a wrong answer at the call site.
__udivmod64:
	mov	r6, #0
	mov	r7, #0
	orrs	ip, r2, r3
	beq	2f
	mov	r8, #64
1:	lsls	r0, r0, #1		@ {rem:num} <<= 1, num's top bit into rem
	adcs	r1, r1, r1
	adcs	r6, r6, r6
	adc	r7, r7, r7
	cmp	r7, r3			@ rem >= divisor ?
	cmpeq	r6, r2
	blo	3f
	subs	r6, r6, r2
	sbc	r7, r7, r3
	orr	r0, r0, #1		@ …so this quotient bit is 1
3:	subs	r8, r8, #1
	bne	1b
	bx	lr
2:	mov	r0, #0
	mov	r1, #0
	bx	lr

@ u64 __udivdi3(u64 n, u64 d)
	.globl	__udivdi3
	.type	__udivdi3, %function
__udivdi3:
	push	{r4-r8, lr}
	bl	__udivmod64
	pop	{r4-r8, pc}

@ u64 __umoddi3(u64 n, u64 d)
	.globl	__umoddi3
	.type	__umoddi3, %function
__umoddi3:
	push	{r4-r8, lr}
	bl	__udivmod64
	mov	r0, r6
	mov	r1, r7
	pop	{r4-r8, pc}

@ i64 __divdi3(i64 n, i64 d)      — magnitudes through the core, sign after
	.globl	__divdi3
	.type	__divdi3, %function
__divdi3:
	push	{r4-r8, lr}
	eor	r4, r1, r3		@ the result's sign lives in bit 31
	lsr	r4, r4, #31
	push	{r4}
	cmp	r1, #0
	bge	1f
	rsbs	r0, r0, #0		@ negate the numerator
	sbc	r1, r1, r1, lsl #1
1:	cmp	r3, #0
	bge	2f
	rsbs	r2, r2, #0		@ …and the divisor
	sbc	r3, r3, r3, lsl #1
2:	bl	__udivmod64
	pop	{r4}
	cmp	r4, #0
	beq	3f
	rsbs	r0, r0, #0
	sbc	r1, r1, r1, lsl #1
3:	pop	{r4-r8, pc}

@ i64 __moddi3(i64 n, i64 d)      — the remainder takes the NUMERATOR's sign
	.globl	__moddi3
	.type	__moddi3, %function
__moddi3:
	push	{r4-r8, lr}
	lsr	r4, r1, #31		@ remember the numerator's sign
	push	{r4}
	cmp	r1, #0
	bge	1f
	rsbs	r0, r0, #0
	sbc	r1, r1, r1, lsl #1
1:	cmp	r3, #0
	bge	2f
	rsbs	r2, r2, #0
	sbc	r3, r3, r3, lsl #1
2:	bl	__udivmod64
	mov	r0, r6
	mov	r1, r7
	pop	{r4}
	cmp	r4, #0
	beq	3f
	rsbs	r0, r0, #0
	sbc	r1, r1, r1, lsl #1
3:	pop	{r4-r8, pc}
