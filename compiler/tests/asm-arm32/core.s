	.text
	mov	r0, r4
	add	r0, r0, #4
	cmp	r0, #0
	ldr	r1, [sp, #8]
	str	r0, [r1]
	ldrb	r2, [r0, #3]
	strh	r3, [r1, #6]
	ldrsh	r4, [r1, #2]
	push	{r4-r11, lr}
	pop	{r4-r11, pc}
	movw	r0, #1234
	movt	r0, #4321
	uxth	r0, r0
	sxtb	r1, r2
	mul	r1, r1, r2
	mla	r0, r1, r2, r0
	subs	r1, r1, #1
	moveq	r0, r1
	mvn	r0, r0
	rsb	r0, r0, #0
	orr	r5, r5, r6
	eor	r5, r5, r6
	and	r5, r5, #255
	lsl	r0, r0, #3
	lsr	r0, r0, r1
	add	r0, r0, r1, lsl #2
	bx	lr
