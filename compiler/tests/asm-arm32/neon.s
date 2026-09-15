	@ NEON "multiple single elements" load/store — what the arm9 back end emits
	@ for a block copy. Two consecutive D registers, post-incremented; the one-
	@ and four-register forms and the other element sizes are here because the
	@ list length and size are the only fields that vary, and an encoding no
	@ test covers is a liability rather than a feature.
	.text
	vld1.8	{d30, d31}, [r0]!
	vst1.8	{d30, d31}, [r0]!
	vld1.8	{d30, d31}, [r0]
	vst1.8	{d30, d31}, [r0]
	vld1.8	{d0, d1}, [r1]!
	vst1.8	{d0, d1}, [r1]!
	vld1.8	{d16, d17}, [r3]!
	vld1.8	{d5}, [r2]!
	vst1.8	{d5}, [r2]
	vld1.8	{d4, d5, d6, d7}, [r2]!
	vst1.8	{d4, d5, d6, d7}, [r2]
	vld1.16	{d30, d31}, [r0]!
	vld1.32	{d30, d31}, [r0]!
	vld1.64	{d30, d31}, [r0]!

	@ NEON integer data processing — the auto-vectoriser's output. A `q` is a
	@ PAIR of D registers, so every field is a D number split bit-4-and-low-four.
	@ Every row an encoder knows is here: an encoding no test covers is a
	@ liability rather than a feature.
	vadd.i32	q10, q11, q12
	vadd.i32	d20, d21, d22
	vadd.i16	q13, q14, q15
	vadd.i8	q0, q1, q2
	vsub.i32	q10, q11, q12
	vmul.i32	q11, q9, q10
	vmul.i16	q10, q9, q11
	vceq.i32	q8, q9, q15
	vand	q9, q8, q14
	vorr	q9, q8, q14
	vmax.s32	q11, q14, q12
	vmax.s32	d22, d23, d24
	vmin.s32	q11, q14, q12
	vpadd.i32	d20, d21, d22
	vpmax.s32	d22, d23, d24
	vpmin.s32	d22, d23, d24
	vdup.32	q10, r0
	vdup.16	q15, r0
	vdup.8	q3, r7
	vdup.32	d5, r1
	vpaddl.u16	q10, q9
	vpaddl.u8	q12, q13
	vpaddl.s16	q10, q9
	vmov.32	r0, d20[0]
	vmov.32	r5, d3[1]
