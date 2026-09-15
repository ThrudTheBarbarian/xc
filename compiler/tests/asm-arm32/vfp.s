	.text
	vldr	s0, [sp, #4]
	vstr	s0, [sp, #8]
	vldr	d2, [sp, #16]
	vstr	d2, [sp, #24]
	vadd.f32	s0, s0, s1
	vsub.f32	s0, s0, s1
	vmul.f64	d2, d2, d3
	vdiv.f32	s0, s0, s1
	vneg.f32	s0, s0
	vsqrt.f64	d2, d2
	vcmp.f32	s0, s1
	vmov	s0, r0
	vmov	r0, s0
	vcvt.f64.f32	d2, s0
	vcvt.f32.f64	s0, d2
	vcvt.s32.f32	s0, s0
	vcvt.f32.s32	s0, s0
