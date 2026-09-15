	@ Barriers and the exclusive pair — what atomic ARC and the thread
	@ primitives compile to. Note the operand order on a store-exclusive: the
	@ STATUS register comes first, which is the opposite of every other store.
	.text
	dmb	ish
	dmb	sy
	dmb	ishst
	dsb	sy
	isb	sy
	ldrex	r1, [r3]
	ldrexb	r1, [r3]
	ldrexh	r1, [r3]
	strex	r2, r1, [r3]
	strexb	r2, r1, [r3]
	strexh	r2, r1, [r3]
