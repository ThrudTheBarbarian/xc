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

@ libxtgen-arm9.s — GENERATED, do not edit.
@
@ Compiled ONCE from support/arm9/runtime/libxt-pic.c so a build needs no C
@ compiler: the arrangement rtgen-linux.s already has on x86-64. Our own
@ assembler reads it back byte-identically to arm-none-eabi-as.
@
@ Regenerate with:
@   arm-none-eabi-gcc -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=vfpv3 -O2 \
@       -mword-relocations -S -I support/arm9/runtime \
@       -o support/arm9/runtime/libxtgen-arm9.s support/arm9/runtime/libxt-pic.c
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
	.file	"libxt-pic.c"
	.text
	.align	2
	.syntax unified
	.arm
	.type	xt_lock, %function
xt_lock:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	mov	r1, #1
	mov	r3, r0
	b	.L4
.L2:
	.syntax divided
@ 83 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r1, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	beq	.L15
.L4:
	.syntax divided
@ 81 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r2, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	beq	.L2
	str	r7, [sp, #-4]!
	.syntax divided
@ 82 "support/arm9/runtime/xt-threads-xtos.c" 1
	clrex
@ 0 "" 2
	.arm
	.syntax unified
	mov	ip, #2
.L6:
	.syntax divided
@ 93 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r1, [r3]
@ 0 "" 2
@ 94 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, ip, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L6
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, #0
	mov	r7, #276
	mov	r0, r3
	mov	r1, #2
	beq	.L16
	mvn	r2, #0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	b	.L6
.L15:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	bx	lr
.L16:
	ldr	r7, [sp], #4
	bx	lr
	.size	xt_lock, .-xt_lock
	.align	2
	.syntax unified
	.arm
	.type	xt_thread_entry, %function
xt_thread_entry:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, r5, r6, lr}
	ldrd	r4, [r0]
	bl	free
	cmp	r4, #0
	popeq	{r4, r5, r6, pc}
	mov	r0, r5
	mov	r3, r4
	pop	{r4, r5, r6, lr}
	bx	r3	@ indirect register sibling call
	.size	xt_thread_entry, .-xt_thread_entry
	.align	2
	.global	_exit
	.syntax unified
	.arm
	.type	_exit, %function
_exit:
	@ Volatile: function does not return.
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	str	r7, [sp, #-4]!
	movw	r7, #257
	.syntax divided
@ 21 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
.L21:
	b	.L21
	.size	_exit, .-_exit
	.align	2
	.global	_xt_clk_reset
	.syntax unified
	.arm
	.type	_xt_clk_reset, %function
_xt_clk_reset:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, .L24
	mov	r2, #0
	str	r2, [r3]
	bx	lr
.L25:
	.align	2
.L24:
	.word	.LANCHOR0
	.size	_xt_clk_reset, .-_xt_clk_reset
	.align	2
	.global	_xt_clk_ticks
	.syntax unified
	.arm
	.type	_xt_clk_ticks, %function
_xt_clk_ticks:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, .L27
	ldr	r0, [r3]
	add	r0, r0, #1000
	str	r0, [r3]
	bx	lr
.L28:
	.align	2
.L27:
	.word	.LANCHOR0
	.size	_xt_clk_ticks, .-_xt_clk_ticks
	.align	2
	.global	_xt_clk_delay
	.syntax unified
	.arm
	.type	_xt_clk_delay, %function
_xt_clk_delay:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r2, .L30
	mov	r1, #1000
	ldr	r3, [r2]
	mla	r3, r1, r0, r3
	str	r3, [r2]
	bx	lr
.L31:
	.align	2
.L30:
	.word	.LANCHOR0
	.size	_xt_clk_delay, .-_xt_clk_delay
	.align	2
	.global	_xt_file_open
	.syntax unified
	.arm
	.type	_xt_file_open, %function
_xt_file_open:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r1, #0
	str	r7, [sp, #-4]!
	beq	.L33
	ldrb	r3, [r1]	@ zero_extendqisi2
	cmp	r3, #114
	moveq	r1, #0
	beq	.L33
	movw	r2, #521
	cmp	r3, #97
	movw	r1, #1537
	moveq	r1, r2
.L33:
	mov	r7, #768
	mov	r2, #0
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_file_open, .-_xt_file_open
	.align	2
	.global	_xt_file_read
	.syntax unified
	.arm
	.type	_xt_file_read, %function
_xt_file_read:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	str	r7, [sp, #-4]!
	movw	r7, #770
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_file_read, .-_xt_file_read
	.align	2
	.global	_xt_file_write
	.syntax unified
	.arm
	.type	_xt_file_write, %function
_xt_file_write:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	str	r7, [sp, #-4]!
	movw	r7, #771
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_file_write, .-_xt_file_write
	.align	2
	.global	_xt_file_close
	.syntax unified
	.arm
	.type	_xt_file_close, %function
_xt_file_close:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	mov	r1, #0
	str	r7, [sp, #-4]!
	mov	r2, r1
	movw	r7, #769
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_file_close, .-_xt_file_close
	.align	2
	.global	_xt_file_size
	.syntax unified
	.arm
	.type	_xt_file_size, %function
_xt_file_size:
	@ args = 0, pretend = 0, frame = 16
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	str	r7, [sp, #-4]!
	sub	sp, sp, #20
	movw	r7, #773
	add	r1, sp, #4
	mov	r2, #0
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r0, r2
	ldreq	r0, [sp, #8]
	mvnne	r0, #0
	add	sp, sp, #20
	@ sp needed
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_file_size, .-_xt_file_size
	.align	2
	.global	_xt_file_exists
	.syntax unified
	.arm
	.type	_xt_file_exists, %function
_xt_file_exists:
	@ args = 0, pretend = 0, frame = 16
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	str	r7, [sp, #-4]!
	sub	sp, sp, #20
	movw	r7, #773
	add	r1, sp, #4
	mov	r2, #0
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	clz	r0, r0
	lsr	r0, r0, #5
	add	sp, sp, #20
	@ sp needed
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_file_exists, .-_xt_file_exists
	.align	2
	.global	_xt_file_exists_exact
	.syntax unified
	.arm
	.type	_xt_file_exists_exact, %function
_xt_file_exists_exact:
	@ args = 0, pretend = 0, frame = 16
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	str	r7, [sp, #-4]!
	sub	sp, sp, #20
	movw	r7, #773
	add	r1, sp, #4
	mov	r2, #0
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	clz	r0, r0
	lsr	r0, r0, #5
	add	sp, sp, #20
	@ sp needed
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_file_exists_exact, .-_xt_file_exists_exact
	.align	2
	.global	_xt_capture_args
	.syntax unified
	.arm
	.type	_xt_capture_args, %function
_xt_capture_args:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, .L53
	strd	r0, [r3, #4]
	bx	lr
.L54:
	.align	2
.L53:
	.word	.LANCHOR0
	.size	_xt_capture_args, .-_xt_capture_args
	.align	2
	.global	_xt_argc
	.syntax unified
	.arm
	.type	_xt_argc, %function
_xt_argc:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, .L56
	ldr	r0, [r3, #4]
	bx	lr
.L57:
	.align	2
.L56:
	.word	.LANCHOR0
	.size	_xt_argc, .-_xt_argc
	.section	.rodata.str1.4,"aMS",%progbits,1
	.align	2
.LC0:
	.ascii	"\000"
	.text
	.align	2
	.global	_xt_argv
	.syntax unified
	.arm
	.type	_xt_argv, %function
_xt_argv:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	blt	.L62
	ldr	r3, .L63
	ldr	r2, [r3, #4]
	cmp	r2, r0
	ble	.L62
	ldr	r3, [r3, #8]
	cmp	r3, #0
	beq	.L62
	ldr	r0, [r3, r0, lsl #2]
	bx	lr
.L62:
	ldr	r0, .L63+4
	bx	lr
.L64:
	.align	2
.L63:
	.word	.LANCHOR0
	.word	.LC0
	.size	_xt_argv, .-_xt_argv
	.align	2
	.global	_xt_exit
	.syntax unified
	.arm
	.type	_xt_exit, %function
_xt_exit:
	@ Volatile: function does not return.
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	mov	r1, #0
	str	r7, [sp, #-4]!
	mov	r2, r1
	movw	r7, #257
	.syntax divided
@ 68 "support/arm9/runtime/libxt-pic.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
.L66:
	b	.L66
	.size	_xt_exit, .-_xt_exit
	.align	2
	.global	_xt_threads_multi
	.syntax unified
	.arm
	.type	_xt_threads_multi, %function
_xt_threads_multi:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, .L69
	ldr	r0, [r3, #12]
	bx	lr
.L70:
	.align	2
.L69:
	.word	.LANCHOR0
	.size	_xt_threads_multi, .-_xt_threads_multi
	.align	2
	.global	_xt_thread_create
	.syntax unified
	.arm
	.type	_xt_thread_create, %function
_xt_thread_create:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, r5, r7, lr}
	subs	r4, r0, #0
	beq	.L80
	ldr	r3, .L81
	mov	r2, #1
	mov	r0, #8
	mov	r5, r1
	str	r2, [r3, #12]
	bl	malloc
	subs	r1, r0, #0
	beq	.L80
	ldr	r0, .L81+4
	movw	r7, #270
	strd	r4, [r1]
	mov	r2, #0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r0, #0
	popgt	{r4, r5, r7, pc}
	mov	r0, r1
	bl	free
.L80:
	mov	r0, #0
	pop	{r4, r5, r7, pc}
.L82:
	.align	2
.L81:
	.word	.LANCHOR0
	.word	xt_thread_entry
	.size	_xt_thread_create, .-_xt_thread_create
	.align	2
	.global	_xt_thread_join
	.syntax unified
	.arm
	.type	_xt_thread_join, %function
_xt_thread_join:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	beq	.L85
	mov	r1, #0
	str	r7, [sp, #-4]!
	mov	r2, r1
	mov	r7, #272
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	subs	r0, r0, r1
	ldr	r7, [sp], #4
	movne	r0, #1
	rsb	r0, r0, #0
	bx	lr
.L85:
	mvn	r0, #0
	bx	lr
	.size	_xt_thread_join, .-_xt_thread_join
	.align	2
	.global	_xt_thread_detach
	.syntax unified
	.arm
	.type	_xt_thread_detach, %function
_xt_thread_detach:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	mov	r1, #0
	str	r7, [sp, #-4]!
	mov	r2, r1
	movw	r7, #273
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_thread_detach, .-_xt_thread_detach
	.align	2
	.global	_xt_thread_yield
	.syntax unified
	.arm
	.type	_xt_thread_yield, %function
_xt_thread_yield:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	mov	r0, #0
	str	r7, [sp, #-4]!
	mov	r1, r0
	movw	r7, #1026
	mov	r2, r0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_thread_yield, .-_xt_thread_yield
	.align	2
	.global	_xt_thread_sleep_ms
	.syntax unified
	.arm
	.type	_xt_thread_sleep_ms, %function
_xt_thread_sleep_ms:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	mov	r3, #1000
	mov	r1, #0
	str	r7, [sp, #-4]!
	mul	r0, r3, r0
	movw	r7, #1026
	mov	r2, r1
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_thread_sleep_ms, .-_xt_thread_sleep_ms
	.align	2
	.global	_xt_thread_self_id
	.syntax unified
	.arm
	.type	_xt_thread_self_id, %function
_xt_thread_self_id:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	mov	r0, #0
	str	r7, [sp, #-4]!
	mov	r1, r0
	movw	r7, #274
	mov	r2, r0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_thread_self_id, .-_xt_thread_self_id
	.align	2
	.global	_xt_thread_cpu_count
	.syntax unified
	.arm
	.type	_xt_thread_cpu_count, %function
_xt_thread_cpu_count:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	mov	r0, #1
	bx	lr
	.size	_xt_thread_cpu_count, .-_xt_thread_cpu_count
	.align	2
	.global	_xt_rt_lock
	.syntax unified
	.arm
	.type	_xt_rt_lock, %function
_xt_rt_lock:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r0, .L108
	ldr	r3, [r0, #12]
	cmp	r3, #0
	bxeq	lr
	add	r0, r0, #16
	b	xt_lock
.L109:
	.align	2
.L108:
	.word	.LANCHOR0
	.size	_xt_rt_lock, .-_xt_rt_lock
	.align	2
	.global	_xt_rt_unlock
	.syntax unified
	.arm
	.type	_xt_rt_unlock, %function
_xt_rt_unlock:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, .L120
	ldr	r2, [r3, #12]
	cmp	r2, #0
	bxeq	lr
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	mov	r0, #0
	add	r3, r3, #16
.L113:
	.syntax divided
@ 93 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r1, [r3]
@ 0 "" 2
@ 94 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r0, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L113
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, #2
	bxne	lr
	str	r7, [sp, #-4]!
	mov	r1, #1
	ldr	r0, .L120+4
	movw	r7, #277
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
.L121:
	.align	2
.L120:
	.word	.LANCHOR0
	.word	.LANCHOR0+16
	.size	_xt_rt_unlock, .-_xt_rt_unlock
	.align	2
	.global	_xt_mutex_new
	.syntax unified
	.arm
	.type	_xt_mutex_new, %function
_xt_mutex_new:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, lr}
	mov	r0, #4
	bl	malloc
	cmp	r0, #0
	movne	r3, #0
	strne	r3, [r0]
	pop	{r4, pc}
	.size	_xt_mutex_new, .-_xt_mutex_new
	.align	2
	.global	_xt_mutex_free
	.syntax unified
	.arm
	.type	_xt_mutex_free, %function
_xt_mutex_free:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	b	free
	.size	_xt_mutex_free, .-_xt_mutex_free
	.align	2
	.global	_xt_mutex_lock
	.syntax unified
	.arm
	.type	_xt_mutex_lock, %function
_xt_mutex_lock:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	b	xt_lock
	.size	_xt_mutex_lock, .-_xt_mutex_lock
	.align	2
	.global	_xt_mutex_unlock
	.syntax unified
	.arm
	.type	_xt_mutex_unlock, %function
_xt_mutex_unlock:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	mov	r1, #0
.L134:
	.syntax divided
@ 93 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r0]
@ 0 "" 2
@ 94 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r1, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L134
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r3, #2
	bxne	lr
	str	r7, [sp, #-4]!
	mov	r1, #1
	movw	r7, #277
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_mutex_unlock, .-_xt_mutex_unlock
	.align	2
	.global	_xt_mutex_trylock
	.syntax unified
	.arm
	.type	_xt_mutex_trylock, %function
_xt_mutex_trylock:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	mov	r2, #1
	b	.L145
.L143:
	.syntax divided
@ 83 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r3, r2, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r3, #0
	beq	.L148
.L145:
	.syntax divided
@ 81 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r3, #0
	beq	.L143
	.syntax divided
@ 82 "support/arm9/runtime/xt-threads-xtos.c" 1
	clrex
@ 0 "" 2
	.arm
	.syntax unified
	mov	r0, #0
	bx	lr
.L148:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	mov	r0, #1
	bx	lr
	.size	_xt_mutex_trylock, .-_xt_mutex_trylock
	.align	2
	.global	_xt_cond_new
	.syntax unified
	.arm
	.type	_xt_cond_new, %function
_xt_cond_new:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, lr}
	mov	r0, #4
	bl	malloc
	cmp	r0, #0
	movne	r3, #0
	strne	r3, [r0]
	pop	{r4, pc}
	.size	_xt_cond_new, .-_xt_cond_new
	.align	2
	.global	_xt_cond_free
	.syntax unified
	.arm
	.type	_xt_cond_free, %function
_xt_cond_free:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	b	free
	.size	_xt_cond_free, .-_xt_cond_free
	.align	2
	.global	_xt_cond_wait
	.syntax unified
	.arm
	.type	_xt_cond_wait, %function
_xt_cond_wait:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	cmp	r1, #0
	cmpne	r0, #0
	push	{r4, r7, lr}
	moveq	lr, #1
	movne	lr, #0
	popeq	{r4, r7, pc}
	mov	ip, r0
	mov	r3, r1
	ldr	r4, [r0]
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
.L158:
	.syntax divided
@ 93 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r1, [r3]
@ 0 "" 2
@ 94 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, lr, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L158
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, #2
	bne	.L159
	movw	r7, #277
	mov	r0, r3
	mov	r1, #1
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
.L159:
	mov	r7, #276
	mov	r0, ip
	mov	r1, r4
	mvn	r2, #0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	pop	{r4, r7, lr}
	mov	r0, r3
	b	xt_lock
	.size	_xt_cond_wait, .-_xt_cond_wait
	.align	2
	.global	_xt_cond_signal
	.syntax unified
	.arm
	.type	_xt_cond_signal, %function
_xt_cond_signal:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	str	r7, [sp, #-4]!
.L164:
	.syntax divided
@ 103 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	add	r3, r3, #1
	.syntax divided
@ 105 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L164
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	movw	r7, #277
	mov	r1, #1
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_cond_signal, .-_xt_cond_signal
	.align	2
	.global	_xt_cond_broadcast
	.syntax unified
	.arm
	.type	_xt_cond_broadcast, %function
_xt_cond_broadcast:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	str	r7, [sp, #-4]!
.L174:
	.syntax divided
@ 103 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	add	r3, r3, #1
	.syntax divided
@ 105 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L174
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	movw	r7, #277
	mvn	r1, #0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_cond_broadcast, .-_xt_cond_broadcast
	.align	2
	.global	_xt_sem_new
	.syntax unified
	.arm
	.type	_xt_sem_new, %function
_xt_sem_new:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, lr}
	mov	r4, r0
	mov	r0, #4
	bl	malloc
	cmp	r0, #0
	bicne	r3, r4, r4, asr #31
	strne	r3, [r0]
	pop	{r4, pc}
	.size	_xt_sem_new, .-_xt_sem_new
	.align	2
	.global	_xt_sem_free
	.syntax unified
	.arm
	.type	_xt_sem_free, %function
_xt_sem_free:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	b	free
	.size	_xt_sem_free, .-_xt_sem_free
	.align	2
	.global	_xt_sem_wait
	.syntax unified
	.arm
	.type	_xt_sem_wait, %function
_xt_sem_wait:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	subs	r3, r0, #0
	bxeq	lr
	ldr	r1, [r3]
	cmp	r1, #0
	ble	.L208
.L210:
	sub	r0, r1, #1
	b	.L204
.L206:
	.syntax divided
@ 83 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r0, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	beq	.L209
.L204:
	.syntax divided
@ 81 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r2, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, r2
	beq	.L206
	.syntax divided
@ 82 "support/arm9/runtime/xt-threads-xtos.c" 1
	clrex
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r1, [r3]
	cmp	r1, #0
	bgt	.L210
.L208:
	str	r7, [sp, #-4]!
.L192:
	mov	r7, #276
	mov	r0, r3
	mov	r1, #0
	mvn	r2, #0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
.L191:
	ldr	r1, [r3]
	cmp	r1, #0
	ble	.L192
	sub	r0, r1, #1
	b	.L195
.L193:
	.syntax divided
@ 83 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r0, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	beq	.L211
.L195:
	.syntax divided
@ 81 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r2, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, r2
	beq	.L193
	.syntax divided
@ 82 "support/arm9/runtime/xt-threads-xtos.c" 1
	clrex
@ 0 "" 2
	.arm
	.syntax unified
	b	.L191
.L209:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	bx	lr
.L211:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_sem_wait, .-_xt_sem_wait
	.align	2
	.global	_xt_sem_trywait
	.syntax unified
	.arm
	.type	_xt_sem_trywait, %function
_xt_sem_trywait:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	subs	r3, r0, #0
	beq	.L215
	ldr	r1, [r3]
	cmp	r1, #0
	ble	.L215
.L217:
	sub	r0, r1, #1
	b	.L218
.L216:
	.syntax divided
@ 83 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r0, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	beq	.L221
.L218:
	.syntax divided
@ 81 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r2, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, r2
	beq	.L216
	.syntax divided
@ 82 "support/arm9/runtime/xt-threads-xtos.c" 1
	clrex
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r1, [r3]
	cmp	r1, #0
	bgt	.L217
.L215:
	mov	r0, #0
	bx	lr
.L221:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	mov	r0, #1
	bx	lr
	.size	_xt_sem_trywait, .-_xt_sem_trywait
	.align	2
	.global	_xt_sem_post
	.syntax unified
	.arm
	.type	_xt_sem_post, %function
_xt_sem_post:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	str	r7, [sp, #-4]!
.L224:
	.syntax divided
@ 103 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	add	r3, r3, #1
	.syntax divided
@ 105 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L224
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	movw	r7, #277
	mov	r1, #1
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r7, [sp], #4
	bx	lr
	.size	_xt_sem_post, .-_xt_sem_post
	.align	2
	.global	_xt_tls_new
	.syntax unified
	.arm
	.type	_xt_tls_new, %function
_xt_tls_new:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	ldr	r3, .L237
.L233:
	.syntax divided
@ 103 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r0, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	add	r1, r0, #1
	.syntax divided
@ 105 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r1, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L233
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r0, #31
	mvngt	r0, #0
	bx	lr
.L238:
	.align	2
.L237:
	.word	.LANCHOR0+20
	.size	_xt_tls_new, .-_xt_tls_new
	.align	2
	.global	_xt_tls_set
	.syntax unified
	.arm
	.type	_xt_tls_set, %function
_xt_tls_set:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	cmp	r0, #31
	bxhi	lr
	push	{r4, r5, r6, r7, r8, lr}
	mov	r4, r0
	mov	r5, r1
	.syntax divided
@ 288 "support/arm9/runtime/xt-threads-xtos.c" 1
	mrc p15,0,r3,c13,c0,2
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r3, #0
	mov	r6, r3
	beq	.L250
	str	r5, [r3, r4, lsl #2]
	pop	{r4, r5, r6, r7, r8, pc}
.L250:
	mov	r1, #4
	mov	r0, #32
	bl	calloc
	subs	r3, r0, #0
	popeq	{r4, r5, r6, r7, r8, pc}
	movw	r7, #275
	mov	r1, r6
	mov	r2, r6
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	str	r5, [r3, r4, lsl #2]
	pop	{r4, r5, r6, r7, r8, pc}
	.size	_xt_tls_set, .-_xt_tls_set
	.align	2
	.global	_xt_tls_get
	.syntax unified
	.arm
	.type	_xt_tls_get, %function
_xt_tls_get:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	cmp	r0, #31
	bhi	.L259
	push	{r4, r5, r7, lr}
	mov	r4, r0
	.syntax divided
@ 288 "support/arm9/runtime/xt-threads-xtos.c" 1
	mrc p15,0,r3,c13,c0,2
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r3, #0
	mov	r5, r3
	beq	.L262
	ldr	r0, [r3, r4, lsl #2]
	pop	{r4, r5, r7, pc}
.L262:
	mov	r1, #4
	mov	r0, #32
	bl	calloc
	subs	r3, r0, #0
	beq	.L252
	movw	r7, #275
	mov	r1, r5
	mov	r2, r5
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r0, [r3, r4, lsl #2]
	pop	{r4, r5, r7, pc}
.L252:
	mov	r0, #0
	pop	{r4, r5, r7, pc}
.L259:
	mov	r0, #0
	bx	lr
	.size	_xt_tls_get, .-_xt_tls_get
	.align	2
	.global	_xt_atomic_load_i32
	.syntax unified
	.arm
	.type	_xt_atomic_load_i32, %function
_xt_atomic_load_i32:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	ldr	r0, [r0]
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	bx	lr
	.size	_xt_atomic_load_i32, .-_xt_atomic_load_i32
	.align	2
	.global	_xt_atomic_store_i32
	.syntax unified
	.arm
	.type	_xt_atomic_store_i32, %function
_xt_atomic_store_i32:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	str	r1, [r0]
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	bx	lr
	.size	_xt_atomic_store_i32, .-_xt_atomic_store_i32
	.align	2
	.global	_xt_atomic_add_i32
	.syntax unified
	.arm
	.type	_xt_atomic_add_i32, %function
_xt_atomic_add_i32:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	subs	r3, r0, #0
	beq	.L274
.L273:
	.syntax divided
@ 103 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r0, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	add	r0, r1, r0
	.syntax divided
@ 105 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r0, [r3]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L273
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	bx	lr
.L274:
	mov	r0, r3
	bx	lr
	.size	_xt_atomic_add_i32, .-_xt_atomic_add_i32
	.align	2
	.global	_xt_atomic_xchg_i32
	.syntax unified
	.arm
	.type	_xt_atomic_xchg_i32, %function
_xt_atomic_xchg_i32:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
.L278:
	.syntax divided
@ 93 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r2, [r0]
@ 0 "" 2
@ 94 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r3, r1, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r3, #0
	bne	.L278
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	mov	r0, r2
	bx	lr
	.size	_xt_atomic_xchg_i32, .-_xt_atomic_xchg_i32
	.align	2
	.global	_xt_atomic_cas_i32
	.syntax unified
	.arm
	.type	_xt_atomic_cas_i32, %function
_xt_atomic_cas_i32:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bne	.L285
	bx	lr
.L283:
	.syntax divided
@ 83 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex ip, r2, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	ip, #0
	beq	.L288
.L285:
	.syntax divided
@ 81 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, r3
	beq	.L283
	.syntax divided
@ 82 "support/arm9/runtime/xt-threads-xtos.c" 1
	clrex
@ 0 "" 2
	.arm
	.syntax unified
.L284:
	sub	r0, r1, r3
	clz	r0, r0
	lsr	r0, r0, #5
	bx	lr
.L288:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	b	.L284
	.size	_xt_atomic_cas_i32, .-_xt_atomic_cas_i32
	.align	2
	.global	_xt_atomic_load_ptr
	.syntax unified
	.arm
	.type	_xt_atomic_load_ptr, %function
_xt_atomic_load_ptr:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	ldr	r0, [r0]
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	bx	lr
	.size	_xt_atomic_load_ptr, .-_xt_atomic_load_ptr
	.align	2
	.global	_xt_atomic_store_ptr
	.syntax unified
	.arm
	.type	_xt_atomic_store_ptr, %function
_xt_atomic_store_ptr:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bxeq	lr
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	str	r1, [r0]
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	bx	lr
	.size	_xt_atomic_store_ptr, .-_xt_atomic_store_ptr
	.align	2
	.global	_xt_atomic_cas_ptr
	.syntax unified
	.arm
	.type	_xt_atomic_cas_ptr, %function
_xt_atomic_cas_ptr:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	cmp	r0, #0
	bne	.L301
	bx	lr
.L299:
	.syntax divided
@ 83 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex ip, r2, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	ip, #0
	beq	.L304
.L301:
	.syntax divided
@ 81 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r0]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r1, r3
	beq	.L299
	.syntax divided
@ 82 "support/arm9/runtime/xt-threads-xtos.c" 1
	clrex
@ 0 "" 2
	.arm
	.syntax unified
.L300:
	sub	r0, r1, r3
	clz	r0, r0
	lsr	r0, r0, #5
	bx	lr
.L304:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	b	.L300
	.size	_xt_atomic_cas_ptr, .-_xt_atomic_cas_ptr
	.align	2
	.global	_xtc_sinit_run
	.syntax unified
	.arm
	.type	_xtc_sinit_run, %function
_xtc_sinit_run:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	push	{r4, r5, r6, r7, r8, r9, r10, lr}
	subs	r4, r0, #0
	popeq	{r4, r5, r6, r7, r8, r9, r10, pc}
	mov	r8, r1
	mov	r9, r2
	ldr	r10, .L343
	ldr	r3, [r10, #12]
	add	r5, r10, #16
	add	r6, r10, #156
	cmp	r3, #0
	bne	.L340
.L308:
	ldrb	r0, [r4]	@ zero_extendqisi2
	cmp	r0, #2
	beq	.L322
.L309:
	cmp	r0, #0
	beq	.L341
	mov	r0, #0
	movw	r7, #274
	mov	r1, r0
	mov	r2, r0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	ip, [r10, #24]
	cmp	ip, r1
	ble	.L314
	ldr	r3, .L343+4
	b	.L317
.L315:
	add	r2, r2, #1
	cmp	r2, ip
	beq	.L314
.L317:
	ldr	r1, [r3], #4
	cmp	r1, r4
	bne	.L315
	ldr	r1, [r6, r2, lsl #2]
	cmp	r1, r0
	bne	.L315
	ldr	r3, [r10, #12]
	cmp	r3, #0
	popeq	{r4, r5, r6, r7, r8, r9, r10, pc}
	mov	ip, #1
.L325:
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	mov	r1, #0
.L318:
	.syntax divided
@ 93 "support/arm9/runtime/xt-threads-xtos.c" 1
	ldrex r3, [r5]
@ 0 "" 2
@ 94 "support/arm9/runtime/xt-threads-xtos.c" 1
	strex r2, r1, [r5]
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r2, #0
	bne	.L318
	.syntax divided
@ 76 "support/arm9/runtime/xt-threads-xtos.c" 1
	dmb ish
@ 0 "" 2
	.arm
	.syntax unified
	cmp	r3, #2
	bne	.L319
	movw	r7, #277
	mov	r0, r5
	mov	r1, #1
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
.L319:
	cmp	ip, #0
	popne	{r4, r5, r6, r7, r8, r9, r10, pc}
.L326:
	mov	r0, #0
	movw	r7, #1026
	mov	r1, r0
	mov	r2, r0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	ldr	r3, [r10, #12]
	cmp	r3, #0
	beq	.L308
.L340:
	mov	r0, r5
	bl	xt_lock
	ldrb	r0, [r4]	@ zero_extendqisi2
	cmp	r0, #2
	bne	.L309
.L322:
	pop	{r4, r5, r6, r7, r8, r9, r10, lr}
	b	_xt_rt_unlock
.L314:
	ldr	r3, [r10, #12]
	cmp	r3, #0
	beq	.L326
	mov	ip, #0
	b	.L325
.L341:
	ldr	r3, [r10, #24]
	mov	r2, #1
	strb	r2, [r4]
	cmp	r3, #31
	bgt	.L311
	add	r3, r10, r3, lsl #2
	movw	r7, #274
	mov	r1, r0
	str	r4, [r3, #28]
	mov	r2, r0
	.syntax divided
@ 64 "support/arm9/runtime/xt-threads-xtos.c" 1
	svc #1
@ 0 "" 2
	.arm
	.syntax unified
	str	r0, [r3, #156]
	ldr	r3, [r10, #24]
	add	r3, r3, #1
	str	r3, [r10, #24]
.L311:
	bl	_xt_rt_unlock
	cmp	r8, #0
	beq	.L313
	mov	r0, r9
	blx	r8
.L313:
	ldr	r3, [r10, #12]
	cmp	r3, #0
	bne	.L342
.L321:
	ldr	r0, [r10, #24]
	mov	r3, #2
	strb	r3, [r4]
	cmp	r0, #0
	ble	.L322
	ldr	r2, .L343+4
	mov	r3, #0
	b	.L324
.L323:
	add	r3, r3, #1
	cmp	r3, r0
	beq	.L322
.L324:
	ldr	r1, [r2], #4
	cmp	r1, r4
	bne	.L323
	sub	r0, r0, #1
	add	r3, r10, r3, lsl #2
	add	r2, r10, r0, lsl #2
	str	r0, [r10, #24]
	pop	{r4, r5, r6, r7, r8, r9, r10, lr}
	ldr	r1, [r2, #28]
	ldr	r2, [r2, #156]
	str	r1, [r3, #28]
	str	r2, [r3, #156]
	b	_xt_rt_unlock
.L342:
	ldr	r0, .L343+8
	bl	xt_lock
	b	.L321
.L344:
	.align	2
.L343:
	.word	.LANCHOR0
	.word	.LANCHOR0+28
	.word	.LANCHOR0+16
	.size	_xtc_sinit_run, .-_xtc_sinit_run
	.align	2
	.global	_xt_thread_exiting
	.syntax unified
	.arm
	.type	_xt_thread_exiting, %function
_xt_thread_exiting:
	@ args = 0, pretend = 0, frame = 0
	@ frame_needed = 0, uses_anonymous_args = 0
	@ link register save eliminated.
	bx	lr
	.size	_xt_thread_exiting, .-_xt_thread_exiting
	.global	_xt_threads_active
	.bss
	.align	2
	.set	.LANCHOR0,. + 0
	.type	xt_ticks, %object
	.size	xt_ticks, 4
xt_ticks:
	.space	4
	.type	xt_argc, %object
	.size	xt_argc, 4
xt_argc:
	.space	4
	.type	xt_argv, %object
	.size	xt_argv, 4
xt_argv:
	.space	4
	.type	_xt_threads_active, %object
	.size	_xt_threads_active, 4
_xt_threads_active:
	.space	4
	.type	xt_rt_lock_obj, %object
	.size	xt_rt_lock_obj, 4
xt_rt_lock_obj:
	.space	4
	.type	xt_tls_next, %object
	.size	xt_tls_next, 4
xt_tls_next:
	.space	4
	.type	xt_sinit_n, %object
	.size	xt_sinit_n, 4
xt_sinit_n:
	.space	4
	.type	xt_sinit_flag, %object
	.size	xt_sinit_flag, 128
xt_sinit_flag:
	.space	128
	.type	xt_sinit_owner, %object
	.size	xt_sinit_owner, 128
xt_sinit_owner:
	.space	128
	.ident	"GCC: (GNU Arm Embedded Toolchain 10.3-2021.10) 10.3.1 20210824 (release)"
