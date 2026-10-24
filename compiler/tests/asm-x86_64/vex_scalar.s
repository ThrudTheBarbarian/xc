# vex_scalar.s — the VEX forms an AVX function's scalar float and xmm code is
# rewritten to (2026-10-24), for vocab-diff against the vendor assembler and
# asx86-diff between our two. A legacy SSE write merges with a live upper
# half on a Zen 3, so an AVX function uses none.
	.intel_syntax noprefix
	.text
	.globl vexscalar
vexscalar:
	vaddss	xmm0, xmm0, xmm1
	vsubss	xmm2, xmm2, dword ptr [rbp - 8]
	vmulss	xmm9, xmm9, xmm10
	vdivss	xmm1, xmm1, xmm15
	vaddsd	xmm3, xmm3, xmm4
	vmulsd	xmm8, xmm8, qword ptr [rsp + 16]
	vsqrtss	xmm0, xmm0, xmm1
	vminss	xmm2, xmm2, xmm3
	vmaxsd	xmm4, xmm4, xmm5
	vcvtss2sd	xmm0, xmm0, xmm1
	vcvtsd2ss	xmm11, xmm11, xmm2
	vcvtsi2ss	xmm0, xmm0, eax
	vcvtsi2ss	xmm1, xmm1, rcx
	vcvtsi2sd	xmm9, xmm9, r10
	vcvtsi2sd	xmm2, xmm2, r11d
	vcvttss2si	eax, xmm0
	vcvttss2si	rax, xmm9
	vcvttsd2si	r8d, xmm1
	vcvttsd2si	r9, xmm12
	vucomiss	xmm0, xmm1
	vucomiss	xmm8, dword ptr [rbp - 4]
	vucomisd	xmm2, xmm10
	vcomiss	xmm3, xmm4
	vmovss	xmm0, xmm0, xmm1
	vmovss	xmm9, xmm9, xmm2
	vmovss	xmm0, dword ptr [rbp - 8]
	vmovss	dword ptr [rbp - 8], xmm11
	vmovsd	xmm3, qword ptr [rsp + 8]
	vmovsd	qword ptr [rsp], xmm2
	vmovsd	xmm4, xmm4, xmm5
	vshufps	xmm1, xmm1, xmm0, 177
	vmovaps	xmm1, xmm0
	vmovups	xmmword ptr [rsp + 32], xmm6
	vmovups	xmm6, xmmword ptr [rsp + 32]
	vpshufd	xmm0, xmm1, 78
	ret
