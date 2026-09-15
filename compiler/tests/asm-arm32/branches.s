	.text
loop:
	cmp	r0, #0
	beq	done
	subs	r0, r0, #1
	b	loop
done:
	bx	lr
