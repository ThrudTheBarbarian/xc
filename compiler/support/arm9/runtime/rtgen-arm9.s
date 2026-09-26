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

@ rtgen-arm9.s — GENERATED, do not edit.
@
@ Compiled ONCE from support/arm9/runtime/rt-arm9.c so a build needs no C
@ compiler: the arrangement rtgen-linux.s already has on x86-64. Our own
@ assembler reads it back byte-identically to arm-none-eabi-as.
@
@ Regenerate with:
@   arm-none-eabi-gcc -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=vfpv3 -O2 \
@       -mword-relocations -S -I support/arm9/runtime \
@       -o support/arm9/runtime/rtgen-arm9.s support/arm9/runtime/rt-arm9.c
@
@ TWO flags are load-bearing and neither is an optimisation:
@   -mword-relocations  keeps gcc off movw/movt symbol pairs, which need
@                       R_ARM_MOVW_ABS_NC — a relocation the XTOS loader
@                       cannot express. It uses a literal pool instead,
@                       which relocates as R_ARM_RELATIVE like everything
@                       else.
@   NOT -fPIC           the GOT idioms that produces are gcc's own; our
@                       linker makes an ET_DYN out of absolute words by
@                       emitting R_ARM_RELATIVE itself, which is exactly
@                       what the xtc back end's --pic mode does.
	.cpu cortex-a9
	.arch armv7-a
	.fpu vfpv3
	.arch_extension mp
	.arch_extension sec
	.eabi_attribute 20, 1
	.eabi_attribute 21, 1
	.eabi_attribute 23, 3
	.eabi_attribute 24, 1
	.eabi_attribute 25, 1
	.eabi_attribute 26, 1
	.eabi_attribute 30, 2
	.eabi_attribute 34, 1
	.eabi_attribute 18, 4
	.file	"rt-arm9.c"
	.text
	.section	.text.startup,"ax",%progbits
	.align	2
	.global	main
	.syntax unified
	.arm
	.type	main, %function
main:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, lr}
	bl	_xt_capture_args
	pop	{r4, lr}
	b	xt_main
	.size	main, .-main
	.text
	.align	2
	.global	_xtc_count
	.syntax unified
	.arm
	.type	_xtc_count, %function
_xtc_count:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldrh	r0, [r0, #-16]
	bx	lr
	.size	_xtc_count, .-_xtc_count
	.section	.rodata.str1.4,"aMS",%progbits,1
	.align	2
.LC0:
	.ascii	"xcc: out of memory (%lu x %lu bytes)\012\000"
	.text
	.align	2
	.global	_xtc_alloc
	.syntax unified
	.arm
	.type	_xtc_alloc, %function
_xtc_alloc:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, r5, r6, lr}
	mov	r4, r0
	mul	r0, r1, r4
	mov	r5, r1
	mov	r6, r2
	cmp	r0, #256
	movcc	r0, #256
	add	r1, r0, #24
	mov	r0, #1
	bl	calloc
	cmp	r0, #0
	beq	.L8
	movw	r3, #20290
	mov	r2, #0
	movt	r3, 22612
	str	r5, [r0, #4]
	str	r3, [r0]
	mov	r3, #1
	str	r4, [r0, #8]
	add	r0, r0, #24
	str	r6, [r0, #-12]
	str	r2, [r0, #-8]
	strh	r3, [r0, #-2]	@ movhi
	pop	{r4, r5, r6, pc}
.L8:
	ldr	r0, .L9
	mov	r3, r5
	ldr	r1, .L9+4
	mov	r2, r4
	ldr	r0, [r0]
	ldr	r0, [r0, #12]
	bl	fprintf
	bl	abort
.L10:
	.align	2
.L9:
	.word	_impure_ptr
	.word	.LC0
	.size	_xtc_alloc, .-_xtc_alloc
	.align	2
	.global	_xtc_weak_unregister
	.syntax unified
	.arm
	.type	_xtc_weak_unregister, %function
_xtc_weak_unregister:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, [r0, #-8]
	cmp	r3, #0
	bxeq	lr
	ldr	r2, [r3]
	cmp	r2, r0
	beq	.L13
.L14:
	mov	r3, #0
	str	r3, [r0, #-8]
	str	r3, [r0, #-4]
	bx	lr
.L13:
	ldr	r2, [r0, #-4]
	cmp	r2, #0
	str	r2, [r3]
	strne	r3, [r2, #-8]
	b	.L14
	.size	_xtc_weak_unregister, .-_xtc_weak_unregister
	.align	2
	.global	_xtc_weak_register
	.syntax unified
	.arm
	.type	_xtc_weak_register, %function
_xtc_weak_register:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, [r0, #-8]
	cmp	r3, #0
	beq	.L22
	ldr	r2, [r3]
	cmp	r0, r2
	beq	.L23
.L24:
	mov	r3, #0
	str	r3, [r0, #-8]
	str	r3, [r0, #-4]
.L22:
	cmp	r1, #0
	bxeq	lr
	ldr	r2, [r1, #-24]
	movw	r3, #20290
	movt	r3, 22612
	cmp	r2, r3
	bxne	lr
	mov	r3, r1
	ldr	r2, [r3, #-8]!
	cmp	r2, #0
	str	r3, [r0, #-8]
	subne	r3, r0, #4
	str	r2, [r0, #-4]
	strne	r3, [r2, #-8]
	str	r0, [r1, #-8]
	bx	lr
.L23:
	ldr	r2, [r0, #-4]
	cmp	r2, #0
	str	r2, [r3]
	strne	r3, [r2, #-8]
	b	.L24
	.size	_xtc_weak_register, .-_xtc_weak_register
	.align	2
	.global	_xtc_weak_load
	.syntax unified
	.arm
	.type	_xtc_weak_load, %function
_xtc_weak_load:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r0, [r0]
	bx	lr
	.size	_xtc_weak_load, .-_xtc_weak_load
	.align	2
	.global	_xtc_weak_zero_for
	.syntax unified
	.arm
	.type	_xtc_weak_zero_for, %function
_xtc_weak_zero_for:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	ldr	r3, [r0, #-8]
	cmp	r3, #0
	beq	.L42
	mov	r1, #0
.L43:
	mov	r2, r3
	ldr	r3, [r3, #-4]
	str	r1, [r2]
	str	r1, [r2, #-8]
	cmp	r3, #0
	str	r1, [r2, #-4]
	bne	.L43
.L42:
	mov	r3, #0
	str	r3, [r0, #-8]
	bx	lr
	.size	_xtc_weak_zero_for, .-_xtc_weak_zero_for
	.align	2
	.global	_xtc_dealloc
	.syntax unified
	.arm
	.type	_xtc_dealloc, %function
_xtc_dealloc:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, r5, r6, r7, r8, r9, r10, lr}
	subs	r4, r0, #0
	beq	.L52
	ldr	r3, [r4, #-8]
	cmp	r3, #0
	beq	.L53
	mov	r1, #0
.L54:
	mov	r2, r3
	ldr	r3, [r3, #-4]
	str	r1, [r2]
	str	r1, [r2, #-8]
	cmp	r3, #0
	str	r1, [r2, #-4]
	bne	.L54
.L53:
	mov	r3, #0
	str	r3, [r4, #-8]
.L52:
	ldr	r6, [r4, #-12]
	sub	r9, r4, #24
	cmp	r6, #0
	beq	.L55
	ldr	r7, [r4, #-16]
	mov	r3, #32768
	ldr	r8, [r4, #-20]
	strh	r3, [r4, #-2]	@ movhi
	cmp	r7, #0
	beq	.L55
	mov	r5, #0
.L56:
	mov	r0, r4
	add	r5, r5, #1
	blx	r6
	cmp	r7, r5
	add	r4, r4, r8
	bne	.L56
.L55:
	mov	r0, r9
	pop	{r4, r5, r6, r7, r8, r9, r10, lr}
	b	free
	.size	_xtc_dealloc, .-_xtc_dealloc
	.align	2
	.global	_xtc_bank
	.syntax unified
	.arm
	.type	_xtc_bank, %function
_xtc_bank:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	cmp	r0, #1
	bhi	.L75
	push	{r4, r5, r6, lr}
	add	r4, r1, r0, lsl #8
	ldr	r5, .L80
	ldr	r0, [r5, r4, lsl #2]
	cmp	r0, #0
	popne	{r4, r5, r6, pc}
	mov	r1, #12288
	mov	r0, #1
	bl	calloc
	str	r0, [r5, r4, lsl #2]
	pop	{r4, r5, r6, pc}
.L75:
	mov	r0, #0
	bx	lr
.L81:
	.align	2
.L80:
	.word	.LANCHOR0
	.size	_xtc_bank, .-_xtc_bank
	.bss
	.align	2
	.set	.LANCHOR0,. + 0
	.type	_xtc_bank_regions, %object
	.size	_xtc_bank_regions, 3072
_xtc_bank_regions:
	.space	3072
	.ident	"GCC: (GNU Arm Embedded Toolchain 10.3-2021.10) 10.3.1 20210824 (release)"
