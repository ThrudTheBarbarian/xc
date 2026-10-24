# evex_high.s — zmm16-31, the registers an AVX-512 function gets beyond the
# first 16 (2026-10-24): every zmm form the compiler emits, with each zmm
# operand renumbered into the upper half, so R', V' and X all carry bit 4.
# For vocab-diff against the vendor assembler and asx86-diff between our two.
	.intel_syntax noprefix
	.text
	.globl evexhigh
evexhigh:
	vmovdqu32	zmm31, zmmword ptr [r9]
	vmovdqu32	zmmword ptr [r8], zmm31
	vpbroadcastd	zmm31, xmm15
	vmovdqa64	zmm27, zmm28
	vpmulld	zmm21, zmm24, zmm31
	vpmuludq	zmm16, zmm21, zmm30
	vpsrlq	zmm16, zmm16, 32
	vpshufd	zmm17, zmm21, 0xB1
	vshufps	zmm21, zmm16, zmm17, 0x88
	vpshufd	zmm21, zmm21, 0xD8
	vpsrld	zmm21, zmm21, 1
	vpaddd	zmm24, zmm24, zmm21
	vextracti64x4	ymm0, zmm29, 1
	vpbroadcastb	zmm31, xmm15
	vpcmpb	k1, zmm25, zmm31, 0
	vpmovm2b	zmm25, k1
	vpandd	zmm25, zmm25, zmm30
	vpxord	zmm16, zmm16, zmm16
	vpternlogd	zmm16, zmm16, zmm16, 0xff
	vpabsb	zmm16, zmm16
	vpmaddubsw	zmm25, zmm25, zmm16
	vpsrlw	zmm16, zmm16, 15
	vpmaddwd	zmm25, zmm25, zmm16
	vpcmpub	k1, zmm25, zmm29, 6
	vbroadcastss	zmm31, xmm15
	vmovups	zmm27, zmmword ptr [rsi]
	vmulps	zmm27, zmm27, zmm26
	vaddps	zmm30, zmm30, zmm27
	vmovups	zmm27, zmmword ptr [rsi+64]
	vextractf64x4	ymm0, zmm27, 1
	vpbroadcastd	zmm20, eax
	vpbroadcastd	zmm16, r9d
	vmovdqu32	zmm16, zmmword ptr [rbp - 128]
	vpaddd	zmm17, zmm18, zmmword ptr [rsp + 64]
	vprold	zmm19, zmm23, 7
	ret
