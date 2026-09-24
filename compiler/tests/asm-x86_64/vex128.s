# vex128.s — the VEX.128 three-operand forms, for vocab-diff against the vendor
# assembler and for asx86-diff between our two.
#
# Nothing EMITS these yet: this is the three-operand half of
# private:docs/bugs/231, landed and provable on its own. The file is the test —
# vocab-diff.py is data-driven from `.s` the compiler produced, and there is no
# such `.s` until codegen uses VEX, so the vocabulary is written out here.
#
# The last two lines are the reason the file exists at all. clang COMMUTES a
# commutative VEX op when that moves a high register out of r/m and into vvvv,
# turning the three-byte prefix into the two-byte one; ours did not, and came
# out a byte longer with the same meaning. Keep them.
	.intel_syntax noprefix
	.text
	.globl vexforms
vexforms:
	vaddps	xmm0, xmm1, xmm2
	vsubps	xmm3, xmm4, xmm5
	vdivps	xmm9, xmm10, xmm11
	vaddpd	xmm0, xmm1, xmm2
	vpaddd	xmm12, xmm13, xmm14
	vpsubd	xmm15, xmm0, xmm1
	vpand	xmm2, xmm3, xmm4
	vpor	xmm5, xmm6, xmm7
	vpxor	xmm8, xmm9, xmm10
	vminps	xmm0, xmm1, xmm2
	vmaxps	xmm3, xmm4, xmm5
	vandps	xmm0, xmm1, xmm2
	vorps	xmm3, xmm4, xmm5
	vaddss	xmm0, xmm1, xmm2
	vmulsd	xmm3, xmm4, xmm5
	vunpcklps xmm0, xmm1, xmm2
	vpunpckldq xmm6, xmm7, xmm8
	vmulps	xmm6, xmm7, xmm8
	vxorps	xmm6, xmm7, xmm8
	ret
