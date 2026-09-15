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

	.text
	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
.set @feat.00, 0
	.intel_syntax noprefix
	.file	"libm-linux.c"
	.def	sqrt;
	.scl	2;
	.type	32;
	.endef
	.globl	sqrt                            # -- Begin function sqrt
	.p2align	4, 0x90
sqrt:                                   # @sqrt
# %bb.0:
	jmp	sqrt                            # TAILCALL
                                        # -- End function
	.def	sqrtf;
	.scl	2;
	.type	32;
	.endef
	.globl	sqrtf                           # -- Begin function sqrtf
	.p2align	4, 0x90
sqrtf:                                  # @sqrtf
# %bb.0:
	jmp	sqrtf                           # TAILCALL
                                        # -- End function
	.def	sin;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function sin
.LCPI2_0:
	.quad	0x3ff921fb54442d18              # double 1.5707963267948966
.LCPI2_1:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI2_2:
	.quad	0x7fffffffffffffff              # double NaN
	.quad	0x7fffffffffffffff              # double NaN
.LCPI2_3:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI2_4:
	.quad	0xbff0000000000000              # double -1
.LCPI2_5:
	.quad	0xbff921fb54442d18              # double -1.5707963267948966
.LCPI2_6:
	.quad	0xbda8fae9be8838d4              # double -1.1359647557788195E-11
.LCPI2_7:
	.quad	0x3e21ee9ebdb4b1c4              # double 2.0875723212981748E-9
.LCPI2_8:
	.quad	0xbe927e4f809c52ad              # double -2.7557314351390663E-7
.LCPI2_9:
	.quad	0x3efa01a019cb1590              # double 2.4801587289476729E-5
.LCPI2_10:
	.quad	0xbf56c16c16c15177              # double -0.001388888888887411
.LCPI2_11:
	.quad	0x3fa555555555554c              # double 0.041666666666666602
.LCPI2_12:
	.quad	0xbfe0000000000000              # double -0.5
.LCPI2_13:
	.quad	0x3ff0000000000000              # double 1
	.zero	8
.LCPI2_14:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
.LCPI2_15:
	.quad	0x3de5d93a5acfd57c              # double 1.5896909952115501E-10
.LCPI2_16:
	.quad	0xbe5ae5e68a2b9ceb              # double -2.5050760253406863E-8
.LCPI2_17:
	.quad	0x3ec71de357b1fe7d              # double 2.7557313707070068E-6
.LCPI2_18:
	.quad	0xbf2a01a019c161d5              # double -1.9841269829857949E-4
.LCPI2_19:
	.quad	0x3f8111111110f8a6              # double 0.0083333333333224895
.LCPI2_20:
	.quad	0xbfc5555555555549              # double -0.16666666666666632
	.text
	.globl	sin
	.p2align	4, 0x90
sin:                                    # @sin
# %bb.0:
	ucomisd	xmm0, xmm0
	jp	.LBB2_9
# %bb.1:
	movapd	xmm1, xmm0
	divsd	xmm1, qword ptr [rip + .LCPI2_0]
	addsd	xmm1, qword ptr [rip + .LCPI2_1]
	movapd	xmm2, xmmword ptr [rip + .LCPI2_2] # xmm2 = [NaN,NaN]
	andpd	xmm2, xmm1
	ucomisd	xmm2, qword ptr [rip + .LCPI2_3]
	jae	.LBB2_3
# %bb.2:
	cvttsd2si	rax, xmm1
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, rax
	movsd	xmm3, qword ptr [rip + .LCPI2_4] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	cmpltsd	xmm1, xmm2
	andpd	xmm3, xmm1
	andnpd	xmm1, xmm2
	orpd	xmm1, xmm3
.LBB2_3:
	cvttsd2si	rax, xmm1
	mulsd	xmm1, qword ptr [rip + .LCPI2_5]
	addsd	xmm0, xmm1
	and	eax, 3
	movapd	xmm2, xmm0
	mulsd	xmm2, xmm0
	cmp	rax, 1
	jg	.LBB2_7
# %bb.4:
	test	rax, rax
	jne	.LBB2_5
# %bb.10:
	movsd	xmm1, qword ptr [rip + .LCPI2_15] # xmm1 = [1.5896909952115501E-10,0.0E+0]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_16]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_17]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_18]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_19]
	movapd	xmm3, xmm0
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_20]
	mulsd	xmm3, xmm2
	mulsd	xmm1, xmm3
	addsd	xmm1, xmm0
	movapd	xmm0, xmm1
	ret
.LBB2_7:
	cmp	eax, 2
	jne	.LBB2_8
# %bb.6:
	movsd	xmm1, qword ptr [rip + .LCPI2_15] # xmm1 = [1.5896909952115501E-10,0.0E+0]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_16]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_17]
	movapd	xmm3, xmm0
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_18]
	mulsd	xmm3, xmm2
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_19]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI2_20]
	mulsd	xmm1, xmm3
	addsd	xmm1, xmm0
	xorpd	xmm1, xmmword ptr [rip + .LCPI2_14]
	movapd	xmm0, xmm1
	ret
.LBB2_5:
	movsd	xmm0, qword ptr [rip + .LCPI2_6] # xmm0 = [-1.1359647557788195E-11,0.0E+0]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_7]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_8]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_9]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_10]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_11]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_12]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_13]
	ret
.LBB2_8:
	movsd	xmm0, qword ptr [rip + .LCPI2_6] # xmm0 = [-1.1359647557788195E-11,0.0E+0]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_7]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_8]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_9]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_10]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_11]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_12]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI2_13]
	xorpd	xmm0, xmmword ptr [rip + .LCPI2_14]
.LBB2_9:
	ret
                                        # -- End function
	.def	cos;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function cos
.LCPI3_0:
	.quad	0x3ff921fb54442d18              # double 1.5707963267948966
.LCPI3_1:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI3_2:
	.quad	0x7fffffffffffffff              # double NaN
	.quad	0x7fffffffffffffff              # double NaN
.LCPI3_3:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI3_4:
	.quad	0xbff0000000000000              # double -1
.LCPI3_5:
	.quad	0xbff921fb54442d18              # double -1.5707963267948966
.LCPI3_6:
	.quad	0x3de5d93a5acfd57c              # double 1.5896909952115501E-10
.LCPI3_7:
	.quad	0xbe5ae5e68a2b9ceb              # double -2.5050760253406863E-8
.LCPI3_8:
	.quad	0x3ec71de357b1fe7d              # double 2.7557313707070068E-6
.LCPI3_9:
	.quad	0xbf2a01a019c161d5              # double -1.9841269829857949E-4
.LCPI3_10:
	.quad	0x3f8111111110f8a6              # double 0.0083333333333224895
.LCPI3_11:
	.quad	0xbfc5555555555549              # double -0.16666666666666632
.LCPI3_12:
	.quad	0xbda8fae9be8838d4              # double -1.1359647557788195E-11
.LCPI3_13:
	.quad	0x3e21ee9ebdb4b1c4              # double 2.0875723212981748E-9
.LCPI3_14:
	.quad	0xbe927e4f809c52ad              # double -2.7557314351390663E-7
.LCPI3_15:
	.quad	0x3efa01a019cb1590              # double 2.4801587289476729E-5
.LCPI3_16:
	.quad	0xbf56c16c16c15177              # double -0.001388888888887411
.LCPI3_17:
	.quad	0x3fa555555555554c              # double 0.041666666666666602
.LCPI3_18:
	.quad	0xbfe0000000000000              # double -0.5
.LCPI3_19:
	.quad	0x3ff0000000000000              # double 1
	.zero	8
.LCPI3_20:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
	.text
	.globl	cos
	.p2align	4, 0x90
cos:                                    # @cos
# %bb.0:
	ucomisd	xmm0, xmm0
	jp	.LBB3_10
# %bb.1:
	movapd	xmm1, xmm0
	divsd	xmm1, qword ptr [rip + .LCPI3_0]
	addsd	xmm1, qword ptr [rip + .LCPI3_1]
	movapd	xmm2, xmmword ptr [rip + .LCPI3_2] # xmm2 = [NaN,NaN]
	andpd	xmm2, xmm1
	ucomisd	xmm2, qword ptr [rip + .LCPI3_3]
	jae	.LBB3_3
# %bb.2:
	cvttsd2si	rax, xmm1
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, rax
	movsd	xmm3, qword ptr [rip + .LCPI3_4] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	cmpltsd	xmm1, xmm2
	andpd	xmm3, xmm1
	andnpd	xmm1, xmm2
	orpd	xmm1, xmm3
.LBB3_3:
	cvttsd2si	rax, xmm1
	mulsd	xmm1, qword ptr [rip + .LCPI3_5]
	addsd	xmm0, xmm1
	and	eax, 3
	movapd	xmm2, xmm0
	mulsd	xmm2, xmm0
	cmp	rax, 1
	jg	.LBB3_7
# %bb.4:
	test	rax, rax
	jne	.LBB3_5
# %bb.11:
	movsd	xmm0, qword ptr [rip + .LCPI3_12] # xmm0 = [-1.1359647557788195E-11,0.0E+0]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_13]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_14]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_15]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_16]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_17]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_18]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_19]
	ret
.LBB3_7:
	cmp	eax, 2
	jne	.LBB3_8
# %bb.6:
	movsd	xmm0, qword ptr [rip + .LCPI3_12] # xmm0 = [-1.1359647557788195E-11,0.0E+0]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_13]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_14]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_15]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_16]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_17]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_18]
	mulsd	xmm0, xmm2
	addsd	xmm0, qword ptr [rip + .LCPI3_19]
	xorpd	xmm0, xmmword ptr [rip + .LCPI3_20]
	ret
.LBB3_5:
	movsd	xmm1, qword ptr [rip + .LCPI3_6] # xmm1 = [1.5896909952115501E-10,0.0E+0]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_7]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_8]
	movapd	xmm3, xmm0
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_9]
	mulsd	xmm3, xmm2
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_10]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_11]
	mulsd	xmm1, xmm3
	addsd	xmm1, xmm0
	xorpd	xmm1, xmmword ptr [rip + .LCPI3_20]
	jmp	.LBB3_9
.LBB3_8:
	movsd	xmm1, qword ptr [rip + .LCPI3_6] # xmm1 = [1.5896909952115501E-10,0.0E+0]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_7]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_8]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_9]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_10]
	movapd	xmm3, xmm0
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI3_11]
	mulsd	xmm3, xmm2
	mulsd	xmm1, xmm3
	addsd	xmm1, xmm0
.LBB3_9:
	movapd	xmm0, xmm1
.LBB3_10:
	ret
                                        # -- End function
	.def	tan;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function tan
.LCPI4_0:
	.quad	0x7ff0000000000000              # double +Inf
	.text
	.globl	tan
	.p2align	4, 0x90
tan:                                    # @tan
# %bb.0:
	sub	rsp, 72
	movaps	xmmword ptr [rsp + 48], xmm7    # 16-byte Spill
	movaps	xmmword ptr [rsp + 32], xmm6    # 16-byte Spill
	movapd	xmm6, xmm0
	call	cos
	movapd	xmm7, xmm0
	xorpd	xmm0, xmm0
	ucomisd	xmm7, xmm0
	jne	.LBB4_2
	jp	.LBB4_2
# %bb.1:
	movsd	xmm0, qword ptr [rip + .LCPI4_0] # xmm0 = [+Inf,0.0E+0]
	jmp	.LBB4_3
.LBB4_2:
	movapd	xmm0, xmm6
	call	sin
	divsd	xmm0, xmm7
.LBB4_3:
	movaps	xmm6, xmmword ptr [rsp + 32]    # 16-byte Reload
	movaps	xmm7, xmmword ptr [rsp + 48]    # 16-byte Reload
	add	rsp, 72
	ret
                                        # -- End function
	.def	atan;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function atan
.LCPI5_0:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
.LCPI5_1:
	.quad	0x4003504f333f9de6              # double 2.4142135623730949
.LCPI5_2:
	.quad	0x3fda827999fcef32              # double 0.41421356237309503
.LCPI5_3:
	.quad	0x3fa2df2d400f49af              # double 0.036858953542508892
.LCPI5_4:
	.quad	0xbfa97b4b24760deb              # double -0.049768779946159324
.LCPI5_5:
	.quad	0x3fadde2d52defd9a              # double 0.058335701337905735
.LCPI5_6:
	.quad	0xbfb10d66a0d03d51              # double -0.066610731373875312
.LCPI5_7:
	.quad	0x3fb3b0f2af749a6d              # double 0.0769187620504483
.LCPI5_8:
	.quad	0xbfb745cdc54c206e              # double -0.090908871334365065
.LCPI5_9:
	.quad	0x3fbc71c6fe231671              # double 0.11111110405462356
.LCPI5_10:
	.quad	0xbfc24924920083ff              # double -0.14285714272503466
.LCPI5_11:
	.quad	0x3fc999999998ebc4              # double 0.19999999999876483
.LCPI5_12:
	.quad	0xbfd555555555550d              # double -0.33333333333332932
.LCPI5_13:
	.quad	0x3ff0000000000000              # double 1
.LCPI5_14:
	.quad	0xbff0000000000000              # double -1
.LCPI5_15:
	.quad	0x3fe921fb54442d18              # double 0.78539816339744828
.LCPI5_16:
	.quad	0x3ff921fb54442d18              # double 1.5707963267948966
	.text
	.globl	atan
	.p2align	4, 0x90
atan:                                   # @atan
# %bb.0:
	ucomisd	xmm0, xmm0
	jp	.LBB5_7
# %bb.1:
	movapd	xmm2, xmmword ptr [rip + .LCPI5_0] # xmm2 = [-0.0E+0,-0.0E+0]
	xorpd	xmm2, xmm0
	maxsd	xmm2, xmm0
	ucomisd	xmm2, qword ptr [rip + .LCPI5_1]
	jbe	.LBB5_3
# %bb.2:
	movsd	xmm3, qword ptr [rip + .LCPI5_13] # xmm3 = [1.0E+0,0.0E+0]
	movapd	xmm1, xmm3
	divsd	xmm1, xmm2
	movapd	xmm4, xmm1
	mulsd	xmm4, xmm1
	movsd	xmm2, qword ptr [rip + .LCPI5_3] # xmm2 = [3.6858953542508892E-2,0.0E+0]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_4]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_5]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_6]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_7]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_8]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_9]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_10]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_11]
	mulsd	xmm2, xmm4
	addsd	xmm2, qword ptr [rip + .LCPI5_12]
	mulsd	xmm2, xmm4
	addsd	xmm2, xmm3
	mulsd	xmm2, xmm1
	movsd	xmm1, qword ptr [rip + .LCPI5_16] # xmm1 = [1.5707963267948966E+0,0.0E+0]
	subsd	xmm1, xmm2
	jmp	.LBB5_6
.LBB5_3:
	ucomisd	xmm2, qword ptr [rip + .LCPI5_2]
	jbe	.LBB5_5
# %bb.4:
	movsd	xmm3, qword ptr [rip + .LCPI5_14] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	movsd	xmm4, qword ptr [rip + .LCPI5_13] # xmm4 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm4
	divsd	xmm3, xmm2
	movapd	xmm2, xmm3
	mulsd	xmm2, xmm3
	movsd	xmm1, qword ptr [rip + .LCPI5_3] # xmm1 = [3.6858953542508892E-2,0.0E+0]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_4]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_5]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_6]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_7]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_8]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_9]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_10]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_11]
	mulsd	xmm1, xmm2
	addsd	xmm1, qword ptr [rip + .LCPI5_12]
	mulsd	xmm1, xmm2
	addsd	xmm1, xmm4
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_15]
	jmp	.LBB5_6
.LBB5_5:
	movapd	xmm3, xmm2
	mulsd	xmm3, xmm2
	movsd	xmm1, qword ptr [rip + .LCPI5_3] # xmm1 = [3.6858953542508892E-2,0.0E+0]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_4]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_5]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_6]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_7]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_8]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_9]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_10]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_11]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_12]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI5_13]
	mulsd	xmm1, xmm2
.LBB5_6:
	movapd	xmm2, xmmword ptr [rip + .LCPI5_0] # xmm2 = [-0.0E+0,-0.0E+0]
	xorpd	xmm2, xmm1
	xorpd	xmm3, xmm3
	cmpnltsd	xmm0, xmm3
	andpd	xmm1, xmm0
	andnpd	xmm0, xmm2
	orpd	xmm0, xmm1
.LBB5_7:
	ret
                                        # -- End function
	.def	log;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function log
.LCPI6_0:
	.quad	0x7ff8000000000000              # double NaN
.LCPI6_1:
	.quad	0xfff0000000000000              # double -Inf
.LCPI6_2:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI6_3:
	.quad	0x3ff6a09e667f3bcd              # double 1.4142135623730951
.LCPI6_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI6_5:
	.quad	0xbff0000000000000              # double -1
.LCPI6_6:
	.quad	0x3ff0000000000000              # double 1
.LCPI6_7:
	.quad	0x3fae1e1e1e1e1e1e              # double 0.058823529411764705
.LCPI6_8:
	.quad	0x3fb1111111111111              # double 0.066666666666666666
.LCPI6_9:
	.quad	0x3fb3b13b13b13b14              # double 0.076923076923076927
.LCPI6_10:
	.quad	0x3fb745d1745d1746              # double 0.090909090909090911
.LCPI6_11:
	.quad	0x3fbc71c71c71c71c              # double 0.1111111111111111
.LCPI6_12:
	.quad	0x3fc2492492492492              # double 0.14285714285714285
.LCPI6_13:
	.quad	0x3fc999999999999a              # double 0.20000000000000001
.LCPI6_14:
	.quad	0x3fd5555555555555              # double 0.33333333333333331
.LCPI6_15:
	.quad	0x3fe62e42fefa39ef              # double 0.69314718055994529
	.text
	.globl	log
	.p2align	4, 0x90
log:                                    # @log
# %bb.0:
	ucomisd	xmm0, xmm0
	jp	.LBB6_8
# %bb.1:
	xorpd	xmm1, xmm1
	ucomisd	xmm1, xmm0
	jbe	.LBB6_3
# %bb.2:
	movsd	xmm0, qword ptr [rip + .LCPI6_0] # xmm0 = [NaN,0.0E+0]
	ret
.LBB6_3:
	ucomisd	xmm0, xmm1
	jne	.LBB6_5
	jp	.LBB6_5
# %bb.4:
	movsd	xmm0, qword ptr [rip + .LCPI6_1] # xmm0 = [-Inf,0.0E+0]
	ret
.LBB6_5:
	movq	rcx, xmm0
	mov	rdx, rcx
	shr	rdx, 52
	add	edx, -1023
	movabs	r8, 4503599627370495
	lea	r9, [r8 + 1]
	mulsd	xmm0, qword ptr [rip + .LCPI6_2]
	movq	r10, xmm0
	mov	rax, r10
	shr	rax, 52
	add	eax, -1075
	cmp	rcx, r9
	cmovb	rcx, r10
	cmovae	eax, edx
	and	rcx, r8
	movabs	rdx, 4607182418800017408
	or	rdx, rcx
	movq	xmm2, rdx
	xor	ecx, ecx
	ucomisd	xmm2, qword ptr [rip + .LCPI6_3]
	seta	cl
	jbe	.LBB6_7
# %bb.6:
	mulsd	xmm2, qword ptr [rip + .LCPI6_4]
.LBB6_7:
	movsd	xmm0, qword ptr [rip + .LCPI6_5] # xmm0 = [-1.0E+0,0.0E+0]
	addsd	xmm0, xmm2
	movsd	xmm1, qword ptr [rip + .LCPI6_6] # xmm1 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm1
	divsd	xmm0, xmm2
	movapd	xmm3, xmm0
	mulsd	xmm3, xmm0
	movsd	xmm2, qword ptr [rip + .LCPI6_7] # xmm2 = [5.8823529411764705E-2,0.0E+0]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI6_8]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI6_9]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI6_10]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI6_11]
	add	eax, ecx
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI6_12]
	addsd	xmm0, xmm0
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI6_13]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI6_14]
	mulsd	xmm2, xmm3
	addsd	xmm2, xmm1
	mulsd	xmm2, xmm0
	xorps	xmm0, xmm0
	cvtsi2sd	xmm0, eax
	mulsd	xmm0, qword ptr [rip + .LCPI6_15]
	addsd	xmm0, xmm2
.LBB6_8:
	ret
                                        # -- End function
	.def	exp;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function exp
.LCPI7_0:
	.quad	0x7ff0000000000000              # double +Inf
.LCPI7_1:
	.quad	0x40862e3d70a3d70a              # double 709.77999999999997
.LCPI7_2:
	.quad	0xc087480000000000              # double -745
.LCPI7_3:
	.quad	0x3ff71547652b82fe              # double 1.4426950408889634
.LCPI7_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI7_5:
	.quad	0xc330000000000000              # double -4503599627370496
.LCPI7_6:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI7_7:
	.quad	0xbff0000000000000              # double -1
.LCPI7_8:
	.quad	0xbfe62e42fefa39ef              # double -0.69314718055994529
.LCPI7_9:
	.quad	0x3ec71de3a556c734              # double 2.7557319223985893E-6
.LCPI7_10:
	.quad	0x3efa01a01a01a01a              # double 2.4801587301587302E-5
.LCPI7_11:
	.quad	0x3f2a01a01a01a01a              # double 1.9841269841269841E-4
.LCPI7_12:
	.quad	0x3f56c16c16c16c17              # double 0.0013888888888888889
.LCPI7_13:
	.quad	0x3f81111111111111              # double 0.0083333333333333332
.LCPI7_14:
	.quad	0x3fa5555555555555              # double 0.041666666666666664
.LCPI7_15:
	.quad	0x3fc5555555555555              # double 0.16666666666666666
.LCPI7_16:
	.quad	0x3ff0000000000000              # double 1
	.text
	.globl	exp
	.p2align	4, 0x90
exp:                                    # @exp
# %bb.0:
	ucomisd	xmm0, xmm0
	jp	.LBB7_10
# %bb.1:
	ucomisd	xmm0, qword ptr [rip + .LCPI7_1]
	jbe	.LBB7_3
# %bb.2:
	movsd	xmm0, qword ptr [rip + .LCPI7_0] # xmm0 = [+Inf,0.0E+0]
	ret
.LBB7_3:
	xorpd	xmm1, xmm1
	movsd	xmm2, qword ptr [rip + .LCPI7_2] # xmm2 = [-7.45E+2,0.0E+0]
	ucomisd	xmm2, xmm0
	ja	.LBB7_9
# %bb.4:
	movsd	xmm1, qword ptr [rip + .LCPI7_3] # xmm1 = [1.4426950408889634E+0,0.0E+0]
	mulsd	xmm1, xmm0
	addsd	xmm1, qword ptr [rip + .LCPI7_4]
	movsd	xmm2, qword ptr [rip + .LCPI7_5] # xmm2 = [-4.503599627370496E+15,0.0E+0]
	ucomisd	xmm2, xmm1
	jae	.LBB7_8
# %bb.5:
	ucomisd	xmm1, xmm1
	jp	.LBB7_8
# %bb.6:
	ucomisd	xmm1, qword ptr [rip + .LCPI7_6]
	jae	.LBB7_8
# %bb.7:
	cvttsd2si	rax, xmm1
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, rax
	movsd	xmm3, qword ptr [rip + .LCPI7_7] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	cmpltsd	xmm1, xmm2
	andpd	xmm3, xmm1
	andnpd	xmm1, xmm2
	orpd	xmm1, xmm3
.LBB7_8:
	movsd	xmm2, qword ptr [rip + .LCPI7_8] # xmm2 = [-6.9314718055994529E-1,0.0E+0]
	mulsd	xmm2, xmm1
	addsd	xmm0, xmm2
	movsd	xmm2, qword ptr [rip + .LCPI7_9] # xmm2 = [2.7557319223985893E-6,0.0E+0]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI7_10]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI7_11]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI7_12]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI7_13]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI7_14]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI7_15]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI7_4]
	mulsd	xmm2, xmm0
	movsd	xmm3, qword ptr [rip + .LCPI7_16] # xmm3 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm3
	mulsd	xmm2, xmm0
	addsd	xmm2, xmm3
	cvttsd2si	rax, xmm1
	shl	rax, 52
	movabs	rcx, 4607182418800017408
	add	rcx, rax
	movq	xmm1, rcx
	mulsd	xmm1, xmm2
.LBB7_9:
	movapd	xmm0, xmm1
.LBB7_10:
	ret
                                        # -- End function
	.def	pow;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function pow
.LCPI8_0:
	.quad	0x3ff0000000000000              # double 1
.LCPI8_1:
	.quad	0xc330000000000000              # double -4503599627370496
.LCPI8_2:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI8_3:
	.quad	0xbff0000000000000              # double -1
.LCPI8_4:
	.quad	0x7ff8000000000000              # double NaN
	.zero	8
.LCPI8_5:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
.LCPI8_6:
	.quad	0x3ff6a09e667f3bcd              # double 1.4142135623730951
.LCPI8_7:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI8_8:
	.quad	0x3fae1e1e1e1e1e1e              # double 0.058823529411764705
.LCPI8_9:
	.quad	0x3fb1111111111111              # double 0.066666666666666666
.LCPI8_10:
	.quad	0x3fb3b13b13b13b14              # double 0.076923076923076927
.LCPI8_11:
	.quad	0x3fb745d1745d1746              # double 0.090909090909090911
.LCPI8_12:
	.quad	0x3fbc71c71c71c71c              # double 0.1111111111111111
.LCPI8_13:
	.quad	0x3fc2492492492492              # double 0.14285714285714285
.LCPI8_14:
	.quad	0x3fc999999999999a              # double 0.20000000000000001
.LCPI8_15:
	.quad	0x3fd5555555555555              # double 0.33333333333333331
.LCPI8_16:
	.quad	0x3fe62e42fefa39ef              # double 0.69314718055994529
.LCPI8_17:
	.quad	0x7ff0000000000000              # double +Inf
.LCPI8_18:
	.quad	0x40862e3d70a3d70a              # double 709.77999999999997
.LCPI8_19:
	.quad	0xc087480000000000              # double -745
.LCPI8_20:
	.quad	0x3ff71547652b82fe              # double 1.4426950408889634
.LCPI8_21:
	.quad	0xbfe62e42fefa39ef              # double -0.69314718055994529
.LCPI8_22:
	.quad	0x3ec71de3a556c734              # double 2.7557319223985893E-6
.LCPI8_23:
	.quad	0x3efa01a01a01a01a              # double 2.4801587301587302E-5
.LCPI8_24:
	.quad	0x3f2a01a01a01a01a              # double 1.9841269841269841E-4
.LCPI8_25:
	.quad	0x3f56c16c16c16c17              # double 0.0013888888888888889
.LCPI8_26:
	.quad	0x3f81111111111111              # double 0.0083333333333333332
.LCPI8_27:
	.quad	0x3fa5555555555555              # double 0.041666666666666664
.LCPI8_28:
	.quad	0x3fc5555555555555              # double 0.16666666666666666
	.text
	.globl	pow
	.p2align	4, 0x90
pow:                                    # @pow
# %bb.0:
	sub	rsp, 24
	movapd	xmmword ptr [rsp], xmm6         # 16-byte Spill
	xorpd	xmm2, xmm2
	ucomisd	xmm1, xmm2
	jne	.LBB8_3
	jp	.LBB8_3
# %bb.1:
	movsd	xmm0, qword ptr [rip + .LCPI8_0] # xmm0 = [1.0E+0,0.0E+0]
.LBB8_2:
	movaps	xmm6, xmmword ptr [rsp]         # 16-byte Reload
	add	rsp, 24
	ret
.LBB8_3:
	ucomisd	xmm0, xmm2
	jne	.LBB8_6
	jp	.LBB8_6
# %bb.4:
	xorpd	xmm0, xmm0
	ucomisd	xmm1, xmm0
	ja	.LBB8_2
	jmp	.LBB8_5
.LBB8_6:
	ucomisd	xmm0, xmm2
	jbe	.LBB8_12
# %bb.7:
	movq	rdx, xmm0
	mov	rax, rdx
	shr	rax, 52
	add	eax, -1023
	movabs	r8, 4503599627370495
	lea	r9, [r8 + 1]
	mulsd	xmm0, qword ptr [rip + .LCPI8_2]
	movq	r10, xmm0
	mov	rcx, r10
	shr	rcx, 52
	add	ecx, -1075
	cmp	rdx, r9
	cmovb	rdx, r10
	cmovae	ecx, eax
	movabs	rax, 4607182418800017408
	and	rdx, r8
	or	rdx, rax
	movq	xmm3, rdx
	xor	edx, edx
	ucomisd	xmm3, qword ptr [rip + .LCPI8_6]
	seta	dl
	jbe	.LBB8_9
# %bb.8:
	mulsd	xmm3, qword ptr [rip + .LCPI8_7]
.LBB8_9:
	movsd	xmm0, qword ptr [rip + .LCPI8_3] # xmm0 = [-1.0E+0,0.0E+0]
	addsd	xmm0, xmm3
	movsd	xmm2, qword ptr [rip + .LCPI8_0] # xmm2 = [1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	divsd	xmm0, xmm3
	movapd	xmm3, xmm0
	mulsd	xmm3, xmm0
	movsd	xmm4, qword ptr [rip + .LCPI8_8] # xmm4 = [5.8823529411764705E-2,0.0E+0]
	mulsd	xmm4, xmm3
	addsd	xmm4, qword ptr [rip + .LCPI8_9]
	mulsd	xmm4, xmm3
	addsd	xmm4, qword ptr [rip + .LCPI8_10]
	mulsd	xmm4, xmm3
	addsd	xmm4, qword ptr [rip + .LCPI8_11]
	mulsd	xmm4, xmm3
	addsd	xmm4, qword ptr [rip + .LCPI8_12]
	mulsd	xmm4, xmm3
	addsd	xmm4, qword ptr [rip + .LCPI8_13]
	mulsd	xmm4, xmm3
	addsd	xmm4, qword ptr [rip + .LCPI8_14]
	add	ecx, edx
	mulsd	xmm4, xmm3
	addsd	xmm4, qword ptr [rip + .LCPI8_15]
	addsd	xmm0, xmm0
	mulsd	xmm4, xmm3
	addsd	xmm4, xmm2
	mulsd	xmm4, xmm0
	xorps	xmm3, xmm3
	cvtsi2sd	xmm3, ecx
	mulsd	xmm3, qword ptr [rip + .LCPI8_16]
	addsd	xmm3, xmm4
	mulsd	xmm3, xmm1
	ucomisd	xmm3, xmm3
	jp	.LBB8_39
# %bb.10:
	ucomisd	xmm3, qword ptr [rip + .LCPI8_18]
	jbe	.LBB8_18
.LBB8_5:
	movsd	xmm0, qword ptr [rip + .LCPI8_17] # xmm0 = [+Inf,0.0E+0]
	jmp	.LBB8_2
.LBB8_12:
	movsd	xmm3, qword ptr [rip + .LCPI8_1] # xmm3 = [-4.503599627370496E+15,0.0E+0]
	ucomisd	xmm3, xmm1
	movapd	xmm2, xmm1
	jae	.LBB8_16
# %bb.13:
	ucomisd	xmm1, xmm1
	movapd	xmm2, xmm1
	jp	.LBB8_16
# %bb.14:
	ucomisd	xmm1, qword ptr [rip + .LCPI8_2]
	movapd	xmm2, xmm1
	jae	.LBB8_16
# %bb.15:
	cvttsd2si	rax, xmm1
	cvtsi2sd	xmm4, rax
	movsd	xmm5, qword ptr [rip + .LCPI8_3] # xmm5 = [-1.0E+0,0.0E+0]
	addsd	xmm5, xmm4
	movapd	xmm2, xmm1
	cmpltsd	xmm2, xmm4
	andpd	xmm5, xmm2
	andnpd	xmm2, xmm4
	orpd	xmm2, xmm5
.LBB8_16:
	ucomisd	xmm2, xmm1
	jne	.LBB8_17
	jnp	.LBB8_24
.LBB8_17:
	movsd	xmm0, qword ptr [rip + .LCPI8_4] # xmm0 = [NaN,0.0E+0]
	jmp	.LBB8_2
.LBB8_18:
	xorpd	xmm0, xmm0
	movsd	xmm1, qword ptr [rip + .LCPI8_19] # xmm1 = [-7.45E+2,0.0E+0]
	ucomisd	xmm1, xmm3
	ja	.LBB8_2
# %bb.19:
	movsd	xmm0, qword ptr [rip + .LCPI8_20] # xmm0 = [1.4426950408889634E+0,0.0E+0]
	mulsd	xmm0, xmm3
	addsd	xmm0, qword ptr [rip + .LCPI8_7]
	movsd	xmm1, qword ptr [rip + .LCPI8_1] # xmm1 = [-4.503599627370496E+15,0.0E+0]
	ucomisd	xmm1, xmm0
	jae	.LBB8_23
# %bb.20:
	ucomisd	xmm0, xmm0
	jp	.LBB8_23
# %bb.21:
	ucomisd	xmm0, qword ptr [rip + .LCPI8_2]
	jae	.LBB8_23
# %bb.22:
	cvttsd2si	rcx, xmm0
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, rcx
	movsd	xmm4, qword ptr [rip + .LCPI8_3] # xmm4 = [-1.0E+0,0.0E+0]
	addsd	xmm4, xmm1
	cmpltsd	xmm0, xmm1
	andpd	xmm4, xmm0
	andnpd	xmm0, xmm1
	orpd	xmm0, xmm4
.LBB8_23:
	movsd	xmm1, qword ptr [rip + .LCPI8_21] # xmm1 = [-6.9314718055994529E-1,0.0E+0]
	mulsd	xmm1, xmm0
	addsd	xmm3, xmm1
	movsd	xmm1, qword ptr [rip + .LCPI8_22] # xmm1 = [2.7557319223985893E-6,0.0E+0]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI8_23]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI8_24]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI8_25]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI8_26]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI8_27]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI8_28]
	mulsd	xmm1, xmm3
	addsd	xmm1, qword ptr [rip + .LCPI8_7]
	mulsd	xmm1, xmm3
	addsd	xmm1, xmm2
	mulsd	xmm1, xmm3
	addsd	xmm1, xmm2
	cvttsd2si	rcx, xmm0
	shl	rcx, 52
	add	rcx, rax
	movq	xmm0, rcx
	mulsd	xmm0, xmm1
	jmp	.LBB8_2
.LBB8_24:
	movabs	rax, 4607182418800017408
	movapd	xmm4, xmmword ptr [rip + .LCPI8_5] # xmm4 = [-0.0E+0,-0.0E+0]
	xorpd	xmm4, xmm0
	ucomisd	xmm0, xmm0
	jp	.LBB8_28
# %bb.25:
	movq	rdx, xmm4
	mov	r8, rdx
	shr	r8, 52
	add	r8d, -1023
	movabs	r9, 4503599627370495
	lea	r10, [r9 + 1]
	mulsd	xmm0, qword ptr [rip + .LCPI8_1]
	movq	r11, xmm0
	mov	rcx, r11
	shr	rcx, 52
	add	ecx, -1075
	cmp	rdx, r10
	cmovb	rdx, r11
	cmovae	ecx, r8d
	and	rdx, r9
	or	rdx, rax
	movq	xmm5, rdx
	xor	edx, edx
	ucomisd	xmm5, qword ptr [rip + .LCPI8_6]
	seta	dl
	jbe	.LBB8_27
# %bb.26:
	mulsd	xmm5, qword ptr [rip + .LCPI8_7]
.LBB8_27:
	movsd	xmm0, qword ptr [rip + .LCPI8_3] # xmm0 = [-1.0E+0,0.0E+0]
	addsd	xmm0, xmm5
	movsd	xmm4, qword ptr [rip + .LCPI8_0] # xmm4 = [1.0E+0,0.0E+0]
	addsd	xmm5, xmm4
	divsd	xmm0, xmm5
	movapd	xmm6, xmm0
	mulsd	xmm6, xmm0
	movsd	xmm5, qword ptr [rip + .LCPI8_8] # xmm5 = [5.8823529411764705E-2,0.0E+0]
	mulsd	xmm5, xmm6
	addsd	xmm5, qword ptr [rip + .LCPI8_9]
	mulsd	xmm5, xmm6
	addsd	xmm5, qword ptr [rip + .LCPI8_10]
	mulsd	xmm5, xmm6
	addsd	xmm5, qword ptr [rip + .LCPI8_11]
	mulsd	xmm5, xmm6
	addsd	xmm5, qword ptr [rip + .LCPI8_12]
	mulsd	xmm5, xmm6
	addsd	xmm5, qword ptr [rip + .LCPI8_13]
	add	ecx, edx
	mulsd	xmm5, xmm6
	addsd	xmm5, qword ptr [rip + .LCPI8_14]
	addsd	xmm0, xmm0
	mulsd	xmm5, xmm6
	addsd	xmm5, qword ptr [rip + .LCPI8_15]
	mulsd	xmm5, xmm6
	addsd	xmm5, xmm4
	xorps	xmm4, xmm4
	cvtsi2sd	xmm4, ecx
	mulsd	xmm5, xmm0
	mulsd	xmm4, qword ptr [rip + .LCPI8_16]
	addsd	xmm4, xmm5
.LBB8_28:
	mulsd	xmm4, xmm1
	ucomisd	xmm4, xmm4
	jp	.LBB8_40
# %bb.29:
	ucomisd	xmm4, qword ptr [rip + .LCPI8_18]
	jbe	.LBB8_31
# %bb.30:
	movsd	xmm0, qword ptr [rip + .LCPI8_17] # xmm0 = [+Inf,0.0E+0]
	jmp	.LBB8_37
.LBB8_31:
	xorpd	xmm0, xmm0
	movsd	xmm1, qword ptr [rip + .LCPI8_19] # xmm1 = [-7.45E+2,0.0E+0]
	ucomisd	xmm1, xmm4
	ja	.LBB8_37
# %bb.32:
	movsd	xmm0, qword ptr [rip + .LCPI8_20] # xmm0 = [1.4426950408889634E+0,0.0E+0]
	mulsd	xmm0, xmm4
	addsd	xmm0, qword ptr [rip + .LCPI8_7]
	ucomisd	xmm3, xmm0
	jae	.LBB8_36
# %bb.33:
	ucomisd	xmm0, xmm0
	jp	.LBB8_36
# %bb.34:
	ucomisd	xmm0, qword ptr [rip + .LCPI8_2]
	jae	.LBB8_36
# %bb.35:
	cvttsd2si	rcx, xmm0
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, rcx
	movsd	xmm3, qword ptr [rip + .LCPI8_3] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm1
	cmpltsd	xmm0, xmm1
	andpd	xmm3, xmm0
	andnpd	xmm0, xmm1
	orpd	xmm0, xmm3
.LBB8_36:
	movsd	xmm1, qword ptr [rip + .LCPI8_21] # xmm1 = [-6.9314718055994529E-1,0.0E+0]
	mulsd	xmm1, xmm0
	addsd	xmm4, xmm1
	movsd	xmm1, qword ptr [rip + .LCPI8_22] # xmm1 = [2.7557319223985893E-6,0.0E+0]
	mulsd	xmm1, xmm4
	addsd	xmm1, qword ptr [rip + .LCPI8_23]
	mulsd	xmm1, xmm4
	addsd	xmm1, qword ptr [rip + .LCPI8_24]
	mulsd	xmm1, xmm4
	addsd	xmm1, qword ptr [rip + .LCPI8_25]
	mulsd	xmm1, xmm4
	addsd	xmm1, qword ptr [rip + .LCPI8_26]
	mulsd	xmm1, xmm4
	addsd	xmm1, qword ptr [rip + .LCPI8_27]
	mulsd	xmm1, xmm4
	addsd	xmm1, qword ptr [rip + .LCPI8_28]
	mulsd	xmm1, xmm4
	addsd	xmm1, qword ptr [rip + .LCPI8_7]
	mulsd	xmm1, xmm4
	movsd	xmm3, qword ptr [rip + .LCPI8_0] # xmm3 = [1.0E+0,0.0E+0]
	addsd	xmm1, xmm3
	mulsd	xmm1, xmm4
	addsd	xmm1, xmm3
	cvttsd2si	rcx, xmm0
	shl	rcx, 52
	add	rcx, rax
	movq	xmm0, rcx
	mulsd	xmm0, xmm1
.LBB8_37:
	cvttsd2si	rax, xmm2
	test	al, 1
	je	.LBB8_2
# %bb.38:
	xorpd	xmm0, xmmword ptr [rip + .LCPI8_5]
	jmp	.LBB8_2
.LBB8_39:
	movapd	xmm0, xmm3
	jmp	.LBB8_2
.LBB8_40:
	movapd	xmm0, xmm4
	jmp	.LBB8_37
                                        # -- End function
	.def	sinf;
	.scl	2;
	.type	32;
	.endef
	.globl	sinf                            # -- Begin function sinf
	.p2align	4, 0x90
sinf:                                   # @sinf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	call	sin
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	cosf;
	.scl	2;
	.type	32;
	.endef
	.globl	cosf                            # -- Begin function cosf
	.p2align	4, 0x90
cosf:                                   # @cosf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	call	cos
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	tanf;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	2, 0x0                          # -- Begin function tanf
.LCPI11_0:
	.long	0x7f800000                      # float +Inf
	.text
	.globl	tanf
	.p2align	4, 0x90
tanf:                                   # @tanf
# %bb.0:
	sub	rsp, 72
	movaps	xmmword ptr [rsp + 48], xmm7    # 16-byte Spill
	movaps	xmmword ptr [rsp + 32], xmm6    # 16-byte Spill
	xorps	xmm6, xmm6
	cvtss2sd	xmm6, xmm0
	movaps	xmm0, xmm6
	call	cos
	movaps	xmm7, xmm0
	xorps	xmm0, xmm0
	ucomisd	xmm7, xmm0
	jne	.LBB11_2
	jp	.LBB11_2
# %bb.1:
	movss	xmm0, dword ptr [rip + .LCPI11_0] # xmm0 = [+Inf,0.0E+0,0.0E+0,0.0E+0]
	jmp	.LBB11_3
.LBB11_2:
	movaps	xmm0, xmm6
	call	sin
	divsd	xmm0, xmm7
	cvtsd2ss	xmm0, xmm0
.LBB11_3:
	movaps	xmm6, xmmword ptr [rsp + 32]    # 16-byte Reload
	movaps	xmm7, xmmword ptr [rsp + 48]    # 16-byte Reload
	add	rsp, 72
	ret
                                        # -- End function
	.def	atanf;
	.scl	2;
	.type	32;
	.endef
	.globl	atanf                           # -- Begin function atanf
	.p2align	4, 0x90
atanf:                                  # @atanf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	call	atan
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	logf;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function logf
.LCPI13_0:
	.long	0x7fc00000                      # float NaN
.LCPI13_1:
	.long	0xff800000                      # float -Inf
.LCPI13_2:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI13_3:
	.quad	0x3ff6a09e667f3bcd              # double 1.4142135623730951
.LCPI13_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI13_5:
	.quad	0xbff0000000000000              # double -1
.LCPI13_6:
	.quad	0x3ff0000000000000              # double 1
.LCPI13_7:
	.quad	0x3fae1e1e1e1e1e1e              # double 0.058823529411764705
.LCPI13_8:
	.quad	0x3fb1111111111111              # double 0.066666666666666666
.LCPI13_9:
	.quad	0x3fb3b13b13b13b14              # double 0.076923076923076927
.LCPI13_10:
	.quad	0x3fb745d1745d1746              # double 0.090909090909090911
.LCPI13_11:
	.quad	0x3fbc71c71c71c71c              # double 0.1111111111111111
.LCPI13_12:
	.quad	0x3fc2492492492492              # double 0.14285714285714285
.LCPI13_13:
	.quad	0x3fc999999999999a              # double 0.20000000000000001
.LCPI13_14:
	.quad	0x3fd5555555555555              # double 0.33333333333333331
.LCPI13_15:
	.quad	0x3fe62e42fefa39ef              # double 0.69314718055994529
	.text
	.globl	logf
	.p2align	4, 0x90
logf:                                   # @logf
# %bb.0:
	ucomiss	xmm0, xmm0
	jp	.LBB13_8
# %bb.1:
	xorps	xmm1, xmm1
	ucomiss	xmm1, xmm0
	jbe	.LBB13_3
# %bb.2:
	movss	xmm0, dword ptr [rip + .LCPI13_0] # xmm0 = [NaN,0.0E+0,0.0E+0,0.0E+0]
	ret
.LBB13_3:
	ucomiss	xmm0, xmm1
	jne	.LBB13_5
	jp	.LBB13_5
# %bb.4:
	movss	xmm0, dword ptr [rip + .LCPI13_1] # xmm0 = [-Inf,0.0E+0,0.0E+0,0.0E+0]
	ret
.LBB13_5:
	cvtss2sd	xmm0, xmm0
	movq	rcx, xmm0
	mov	rdx, rcx
	shr	rdx, 52
	add	edx, -1023
	movabs	r8, 4503599627370495
	lea	r9, [r8 + 1]
	mulsd	xmm0, qword ptr [rip + .LCPI13_2]
	movq	r10, xmm0
	mov	rax, r10
	shr	rax, 52
	add	eax, -1075
	cmp	rcx, r9
	cmovb	rcx, r10
	cmovae	eax, edx
	and	rcx, r8
	movabs	rdx, 4607182418800017408
	or	rdx, rcx
	movq	xmm2, rdx
	xor	ecx, ecx
	ucomisd	xmm2, qword ptr [rip + .LCPI13_3]
	seta	cl
	jbe	.LBB13_7
# %bb.6:
	mulsd	xmm2, qword ptr [rip + .LCPI13_4]
.LBB13_7:
	movsd	xmm0, qword ptr [rip + .LCPI13_5] # xmm0 = [-1.0E+0,0.0E+0]
	addsd	xmm0, xmm2
	movsd	xmm1, qword ptr [rip + .LCPI13_6] # xmm1 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm1
	divsd	xmm0, xmm2
	movapd	xmm3, xmm0
	mulsd	xmm3, xmm0
	movsd	xmm2, qword ptr [rip + .LCPI13_7] # xmm2 = [5.8823529411764705E-2,0.0E+0]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI13_8]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI13_9]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI13_10]
	add	eax, ecx
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI13_11]
	addsd	xmm0, xmm0
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI13_12]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI13_13]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI13_14]
	mulsd	xmm2, xmm3
	addsd	xmm2, xmm1
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, eax
	mulsd	xmm1, qword ptr [rip + .LCPI13_15]
	mulsd	xmm2, xmm0
	addsd	xmm1, xmm2
	xorps	xmm0, xmm0
	cvtsd2ss	xmm0, xmm1
.LBB13_8:
	ret
                                        # -- End function
	.def	expf;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function expf
.LCPI14_0:
	.long	0x7f800000                      # float +Inf
	.zero	4
.LCPI14_1:
	.quad	0x40862e3d70a3d70a              # double 709.77999999999997
.LCPI14_2:
	.long	0xc43a4000                      # float -745
	.zero	4
.LCPI14_3:
	.quad	0x3ff71547652b82fe              # double 1.4426950408889634
.LCPI14_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI14_5:
	.quad	0xc330000000000000              # double -4503599627370496
.LCPI14_6:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI14_7:
	.quad	0xbff0000000000000              # double -1
.LCPI14_8:
	.quad	0xbfe62e42fefa39ef              # double -0.69314718055994529
.LCPI14_9:
	.quad	0x3ec71de3a556c734              # double 2.7557319223985893E-6
.LCPI14_10:
	.quad	0x3efa01a01a01a01a              # double 2.4801587301587302E-5
.LCPI14_11:
	.quad	0x3f2a01a01a01a01a              # double 1.9841269841269841E-4
.LCPI14_12:
	.quad	0x3f56c16c16c16c17              # double 0.0013888888888888889
.LCPI14_13:
	.quad	0x3f81111111111111              # double 0.0083333333333333332
.LCPI14_14:
	.quad	0x3fa5555555555555              # double 0.041666666666666664
.LCPI14_15:
	.quad	0x3fc5555555555555              # double 0.16666666666666666
.LCPI14_16:
	.quad	0x3ff0000000000000              # double 1
	.text
	.globl	expf
	.p2align	4, 0x90
expf:                                   # @expf
# %bb.0:
	ucomiss	xmm0, xmm0
	jp	.LBB14_9
# %bb.1:
	cvtss2sd	xmm1, xmm0
	ucomisd	xmm1, qword ptr [rip + .LCPI14_1]
	jbe	.LBB14_3
# %bb.2:
	movss	xmm0, dword ptr [rip + .LCPI14_0] # xmm0 = [+Inf,0.0E+0,0.0E+0,0.0E+0]
	ret
.LBB14_3:
	movss	xmm2, dword ptr [rip + .LCPI14_2] # xmm2 = [-7.45E+2,0.0E+0,0.0E+0,0.0E+0]
	ucomiss	xmm2, xmm0
	xorps	xmm0, xmm0
	ja	.LBB14_9
# %bb.4:
	movsd	xmm0, qword ptr [rip + .LCPI14_3] # xmm0 = [1.4426950408889634E+0,0.0E+0]
	mulsd	xmm0, xmm1
	addsd	xmm0, qword ptr [rip + .LCPI14_4]
	movsd	xmm2, qword ptr [rip + .LCPI14_5] # xmm2 = [-4.503599627370496E+15,0.0E+0]
	ucomisd	xmm2, xmm0
	jae	.LBB14_8
# %bb.5:
	ucomisd	xmm0, xmm0
	jp	.LBB14_8
# %bb.6:
	ucomisd	xmm0, qword ptr [rip + .LCPI14_6]
	jae	.LBB14_8
# %bb.7:
	cvttsd2si	rax, xmm0
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, rax
	movsd	xmm3, qword ptr [rip + .LCPI14_7] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	cmpltsd	xmm0, xmm2
	andpd	xmm3, xmm0
	andnpd	xmm0, xmm2
	orpd	xmm0, xmm3
.LBB14_8:
	movsd	xmm2, qword ptr [rip + .LCPI14_8] # xmm2 = [-6.9314718055994529E-1,0.0E+0]
	mulsd	xmm2, xmm0
	addsd	xmm1, xmm2
	movsd	xmm2, qword ptr [rip + .LCPI14_9] # xmm2 = [2.7557319223985893E-6,0.0E+0]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI14_10]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI14_11]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI14_12]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI14_13]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI14_14]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI14_15]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI14_4]
	mulsd	xmm2, xmm1
	movsd	xmm3, qword ptr [rip + .LCPI14_16] # xmm3 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm3
	mulsd	xmm2, xmm1
	cvttsd2si	rax, xmm0
	addsd	xmm2, xmm3
	shl	rax, 52
	movabs	rcx, 4607182418800017408
	add	rcx, rax
	movq	xmm0, rcx
	mulsd	xmm0, xmm2
	cvtsd2ss	xmm0, xmm0
.LBB14_9:
	ret
                                        # -- End function
	.def	powf;
	.scl	2;
	.type	32;
	.endef
	.globl	powf                            # -- Begin function powf
	.p2align	4, 0x90
powf:                                   # @powf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	cvtss2sd	xmm1, xmm1
	call	pow
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xm_sqrtf;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_sqrtf                       # -- Begin function _xm_sqrtf
	.p2align	4, 0x90
_xm_sqrtf:                              # @_xm_sqrtf
# %bb.0:
	jmp	sqrtf                           # TAILCALL
                                        # -- End function
	.def	_xm_sqrt;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_sqrt                        # -- Begin function _xm_sqrt
	.p2align	4, 0x90
_xm_sqrt:                               # @_xm_sqrt
# %bb.0:
	jmp	sqrt                            # TAILCALL
                                        # -- End function
	.def	_xm_sinf;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_sinf                        # -- Begin function _xm_sinf
	.p2align	4, 0x90
_xm_sinf:                               # @_xm_sinf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	call	sin
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xm_sin;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_sin                         # -- Begin function _xm_sin
	.p2align	4, 0x90
_xm_sin:                                # @_xm_sin
# %bb.0:
	jmp	sin                             # TAILCALL
                                        # -- End function
	.def	_xm_cosf;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_cosf                        # -- Begin function _xm_cosf
	.p2align	4, 0x90
_xm_cosf:                               # @_xm_cosf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	call	cos
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xm_cos;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_cos                         # -- Begin function _xm_cos
	.p2align	4, 0x90
_xm_cos:                                # @_xm_cos
# %bb.0:
	jmp	cos                             # TAILCALL
                                        # -- End function
	.def	_xm_tanf;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	2, 0x0                          # -- Begin function _xm_tanf
.LCPI22_0:
	.long	0x7f800000                      # float +Inf
	.text
	.globl	_xm_tanf
	.p2align	4, 0x90
_xm_tanf:                               # @_xm_tanf
# %bb.0:
	sub	rsp, 72
	movaps	xmmword ptr [rsp + 48], xmm7    # 16-byte Spill
	movaps	xmmword ptr [rsp + 32], xmm6    # 16-byte Spill
	xorps	xmm6, xmm6
	cvtss2sd	xmm6, xmm0
	movaps	xmm0, xmm6
	call	cos
	movaps	xmm7, xmm0
	xorps	xmm0, xmm0
	ucomisd	xmm7, xmm0
	jne	.LBB22_2
	jp	.LBB22_2
# %bb.1:
	movss	xmm0, dword ptr [rip + .LCPI22_0] # xmm0 = [+Inf,0.0E+0,0.0E+0,0.0E+0]
	jmp	.LBB22_3
.LBB22_2:
	movaps	xmm0, xmm6
	call	sin
	divsd	xmm0, xmm7
	cvtsd2ss	xmm0, xmm0
.LBB22_3:
	movaps	xmm6, xmmword ptr [rsp + 32]    # 16-byte Reload
	movaps	xmm7, xmmword ptr [rsp + 48]    # 16-byte Reload
	add	rsp, 72
	ret
                                        # -- End function
	.def	_xm_tan;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function _xm_tan
.LCPI23_0:
	.quad	0x7ff0000000000000              # double +Inf
	.text
	.globl	_xm_tan
	.p2align	4, 0x90
_xm_tan:                                # @_xm_tan
# %bb.0:
	sub	rsp, 72
	movaps	xmmword ptr [rsp + 48], xmm7    # 16-byte Spill
	movaps	xmmword ptr [rsp + 32], xmm6    # 16-byte Spill
	movapd	xmm6, xmm0
	call	cos
	movapd	xmm7, xmm0
	xorpd	xmm0, xmm0
	ucomisd	xmm7, xmm0
	jne	.LBB23_2
	jp	.LBB23_2
# %bb.1:
	movsd	xmm0, qword ptr [rip + .LCPI23_0] # xmm0 = [+Inf,0.0E+0]
	jmp	.LBB23_3
.LBB23_2:
	movapd	xmm0, xmm6
	call	sin
	divsd	xmm0, xmm7
.LBB23_3:
	movaps	xmm6, xmmword ptr [rsp + 32]    # 16-byte Reload
	movaps	xmm7, xmmword ptr [rsp + 48]    # 16-byte Reload
	add	rsp, 72
	ret
                                        # -- End function
	.def	_xm_atanf;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_atanf                       # -- Begin function _xm_atanf
	.p2align	4, 0x90
_xm_atanf:                              # @_xm_atanf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	call	atan
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xm_atan;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_atan                        # -- Begin function _xm_atan
	.p2align	4, 0x90
_xm_atan:                               # @_xm_atan
# %bb.0:
	jmp	atan                            # TAILCALL
                                        # -- End function
	.def	_xm_lnf;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function _xm_lnf
.LCPI26_0:
	.long	0x7fc00000                      # float NaN
.LCPI26_1:
	.long	0xff800000                      # float -Inf
.LCPI26_2:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI26_3:
	.quad	0x3ff6a09e667f3bcd              # double 1.4142135623730951
.LCPI26_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI26_5:
	.quad	0xbff0000000000000              # double -1
.LCPI26_6:
	.quad	0x3ff0000000000000              # double 1
.LCPI26_7:
	.quad	0x3fae1e1e1e1e1e1e              # double 0.058823529411764705
.LCPI26_8:
	.quad	0x3fb1111111111111              # double 0.066666666666666666
.LCPI26_9:
	.quad	0x3fb3b13b13b13b14              # double 0.076923076923076927
.LCPI26_10:
	.quad	0x3fb745d1745d1746              # double 0.090909090909090911
.LCPI26_11:
	.quad	0x3fbc71c71c71c71c              # double 0.1111111111111111
.LCPI26_12:
	.quad	0x3fc2492492492492              # double 0.14285714285714285
.LCPI26_13:
	.quad	0x3fc999999999999a              # double 0.20000000000000001
.LCPI26_14:
	.quad	0x3fd5555555555555              # double 0.33333333333333331
.LCPI26_15:
	.quad	0x3fe62e42fefa39ef              # double 0.69314718055994529
	.text
	.globl	_xm_lnf
	.p2align	4, 0x90
_xm_lnf:                                # @_xm_lnf
# %bb.0:
	ucomiss	xmm0, xmm0
	jp	.LBB26_8
# %bb.1:
	xorps	xmm1, xmm1
	ucomiss	xmm1, xmm0
	jbe	.LBB26_3
# %bb.2:
	movss	xmm0, dword ptr [rip + .LCPI26_0] # xmm0 = [NaN,0.0E+0,0.0E+0,0.0E+0]
	ret
.LBB26_3:
	ucomiss	xmm0, xmm1
	jne	.LBB26_5
	jp	.LBB26_5
# %bb.4:
	movss	xmm0, dword ptr [rip + .LCPI26_1] # xmm0 = [-Inf,0.0E+0,0.0E+0,0.0E+0]
	ret
.LBB26_5:
	cvtss2sd	xmm0, xmm0
	movq	rcx, xmm0
	mov	rdx, rcx
	shr	rdx, 52
	add	edx, -1023
	movabs	r8, 4503599627370495
	lea	r9, [r8 + 1]
	mulsd	xmm0, qword ptr [rip + .LCPI26_2]
	movq	r10, xmm0
	mov	rax, r10
	shr	rax, 52
	add	eax, -1075
	cmp	rcx, r9
	cmovb	rcx, r10
	cmovae	eax, edx
	and	rcx, r8
	movabs	rdx, 4607182418800017408
	or	rdx, rcx
	movq	xmm2, rdx
	xor	ecx, ecx
	ucomisd	xmm2, qword ptr [rip + .LCPI26_3]
	seta	cl
	jbe	.LBB26_7
# %bb.6:
	mulsd	xmm2, qword ptr [rip + .LCPI26_4]
.LBB26_7:
	movsd	xmm0, qword ptr [rip + .LCPI26_5] # xmm0 = [-1.0E+0,0.0E+0]
	addsd	xmm0, xmm2
	movsd	xmm1, qword ptr [rip + .LCPI26_6] # xmm1 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm1
	divsd	xmm0, xmm2
	movapd	xmm3, xmm0
	mulsd	xmm3, xmm0
	movsd	xmm2, qword ptr [rip + .LCPI26_7] # xmm2 = [5.8823529411764705E-2,0.0E+0]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI26_8]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI26_9]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI26_10]
	add	eax, ecx
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI26_11]
	addsd	xmm0, xmm0
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI26_12]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI26_13]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI26_14]
	mulsd	xmm2, xmm3
	addsd	xmm2, xmm1
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, eax
	mulsd	xmm1, qword ptr [rip + .LCPI26_15]
	mulsd	xmm2, xmm0
	addsd	xmm1, xmm2
	xorps	xmm0, xmm0
	cvtsd2ss	xmm0, xmm1
.LBB26_8:
	ret
                                        # -- End function
	.def	_xm_ln;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function _xm_ln
.LCPI27_0:
	.quad	0x7ff8000000000000              # double NaN
.LCPI27_1:
	.quad	0xfff0000000000000              # double -Inf
.LCPI27_2:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI27_3:
	.quad	0x3ff6a09e667f3bcd              # double 1.4142135623730951
.LCPI27_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI27_5:
	.quad	0xbff0000000000000              # double -1
.LCPI27_6:
	.quad	0x3ff0000000000000              # double 1
.LCPI27_7:
	.quad	0x3fae1e1e1e1e1e1e              # double 0.058823529411764705
.LCPI27_8:
	.quad	0x3fb1111111111111              # double 0.066666666666666666
.LCPI27_9:
	.quad	0x3fb3b13b13b13b14              # double 0.076923076923076927
.LCPI27_10:
	.quad	0x3fb745d1745d1746              # double 0.090909090909090911
.LCPI27_11:
	.quad	0x3fbc71c71c71c71c              # double 0.1111111111111111
.LCPI27_12:
	.quad	0x3fc2492492492492              # double 0.14285714285714285
.LCPI27_13:
	.quad	0x3fc999999999999a              # double 0.20000000000000001
.LCPI27_14:
	.quad	0x3fd5555555555555              # double 0.33333333333333331
.LCPI27_15:
	.quad	0x3fe62e42fefa39ef              # double 0.69314718055994529
	.text
	.globl	_xm_ln
	.p2align	4, 0x90
_xm_ln:                                 # @_xm_ln
# %bb.0:
	ucomisd	xmm0, xmm0
	jp	.LBB27_8
# %bb.1:
	xorpd	xmm1, xmm1
	ucomisd	xmm1, xmm0
	jbe	.LBB27_3
# %bb.2:
	movsd	xmm0, qword ptr [rip + .LCPI27_0] # xmm0 = [NaN,0.0E+0]
	ret
.LBB27_3:
	ucomisd	xmm0, xmm1
	jne	.LBB27_5
	jp	.LBB27_5
# %bb.4:
	movsd	xmm0, qword ptr [rip + .LCPI27_1] # xmm0 = [-Inf,0.0E+0]
	ret
.LBB27_5:
	movq	rcx, xmm0
	mov	rdx, rcx
	shr	rdx, 52
	add	edx, -1023
	movabs	r8, 4503599627370495
	lea	r9, [r8 + 1]
	mulsd	xmm0, qword ptr [rip + .LCPI27_2]
	movq	r10, xmm0
	mov	rax, r10
	shr	rax, 52
	add	eax, -1075
	cmp	rcx, r9
	cmovb	rcx, r10
	cmovae	eax, edx
	and	rcx, r8
	movabs	rdx, 4607182418800017408
	or	rdx, rcx
	movq	xmm2, rdx
	xor	ecx, ecx
	ucomisd	xmm2, qword ptr [rip + .LCPI27_3]
	seta	cl
	jbe	.LBB27_7
# %bb.6:
	mulsd	xmm2, qword ptr [rip + .LCPI27_4]
.LBB27_7:
	movsd	xmm0, qword ptr [rip + .LCPI27_5] # xmm0 = [-1.0E+0,0.0E+0]
	addsd	xmm0, xmm2
	movsd	xmm1, qword ptr [rip + .LCPI27_6] # xmm1 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm1
	divsd	xmm0, xmm2
	movapd	xmm3, xmm0
	mulsd	xmm3, xmm0
	movsd	xmm2, qword ptr [rip + .LCPI27_7] # xmm2 = [5.8823529411764705E-2,0.0E+0]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI27_8]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI27_9]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI27_10]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI27_11]
	add	eax, ecx
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI27_12]
	addsd	xmm0, xmm0
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI27_13]
	mulsd	xmm2, xmm3
	addsd	xmm2, qword ptr [rip + .LCPI27_14]
	mulsd	xmm2, xmm3
	addsd	xmm2, xmm1
	mulsd	xmm2, xmm0
	xorps	xmm0, xmm0
	cvtsi2sd	xmm0, eax
	mulsd	xmm0, qword ptr [rip + .LCPI27_15]
	addsd	xmm0, xmm2
.LBB27_8:
	ret
                                        # -- End function
	.def	_xm_expf;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function _xm_expf
.LCPI28_0:
	.long	0x7f800000                      # float +Inf
	.zero	4
.LCPI28_1:
	.quad	0x40862e3d70a3d70a              # double 709.77999999999997
.LCPI28_2:
	.long	0xc43a4000                      # float -745
	.zero	4
.LCPI28_3:
	.quad	0x3ff71547652b82fe              # double 1.4426950408889634
.LCPI28_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI28_5:
	.quad	0xc330000000000000              # double -4503599627370496
.LCPI28_6:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI28_7:
	.quad	0xbff0000000000000              # double -1
.LCPI28_8:
	.quad	0xbfe62e42fefa39ef              # double -0.69314718055994529
.LCPI28_9:
	.quad	0x3ec71de3a556c734              # double 2.7557319223985893E-6
.LCPI28_10:
	.quad	0x3efa01a01a01a01a              # double 2.4801587301587302E-5
.LCPI28_11:
	.quad	0x3f2a01a01a01a01a              # double 1.9841269841269841E-4
.LCPI28_12:
	.quad	0x3f56c16c16c16c17              # double 0.0013888888888888889
.LCPI28_13:
	.quad	0x3f81111111111111              # double 0.0083333333333333332
.LCPI28_14:
	.quad	0x3fa5555555555555              # double 0.041666666666666664
.LCPI28_15:
	.quad	0x3fc5555555555555              # double 0.16666666666666666
.LCPI28_16:
	.quad	0x3ff0000000000000              # double 1
	.text
	.globl	_xm_expf
	.p2align	4, 0x90
_xm_expf:                               # @_xm_expf
# %bb.0:
	ucomiss	xmm0, xmm0
	jp	.LBB28_9
# %bb.1:
	cvtss2sd	xmm1, xmm0
	ucomisd	xmm1, qword ptr [rip + .LCPI28_1]
	jbe	.LBB28_3
# %bb.2:
	movss	xmm0, dword ptr [rip + .LCPI28_0] # xmm0 = [+Inf,0.0E+0,0.0E+0,0.0E+0]
	ret
.LBB28_3:
	movss	xmm2, dword ptr [rip + .LCPI28_2] # xmm2 = [-7.45E+2,0.0E+0,0.0E+0,0.0E+0]
	ucomiss	xmm2, xmm0
	xorps	xmm0, xmm0
	ja	.LBB28_9
# %bb.4:
	movsd	xmm0, qword ptr [rip + .LCPI28_3] # xmm0 = [1.4426950408889634E+0,0.0E+0]
	mulsd	xmm0, xmm1
	addsd	xmm0, qword ptr [rip + .LCPI28_4]
	movsd	xmm2, qword ptr [rip + .LCPI28_5] # xmm2 = [-4.503599627370496E+15,0.0E+0]
	ucomisd	xmm2, xmm0
	jae	.LBB28_8
# %bb.5:
	ucomisd	xmm0, xmm0
	jp	.LBB28_8
# %bb.6:
	ucomisd	xmm0, qword ptr [rip + .LCPI28_6]
	jae	.LBB28_8
# %bb.7:
	cvttsd2si	rax, xmm0
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, rax
	movsd	xmm3, qword ptr [rip + .LCPI28_7] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	cmpltsd	xmm0, xmm2
	andpd	xmm3, xmm0
	andnpd	xmm0, xmm2
	orpd	xmm0, xmm3
.LBB28_8:
	movsd	xmm2, qword ptr [rip + .LCPI28_8] # xmm2 = [-6.9314718055994529E-1,0.0E+0]
	mulsd	xmm2, xmm0
	addsd	xmm1, xmm2
	movsd	xmm2, qword ptr [rip + .LCPI28_9] # xmm2 = [2.7557319223985893E-6,0.0E+0]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI28_10]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI28_11]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI28_12]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI28_13]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI28_14]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI28_15]
	mulsd	xmm2, xmm1
	addsd	xmm2, qword ptr [rip + .LCPI28_4]
	mulsd	xmm2, xmm1
	movsd	xmm3, qword ptr [rip + .LCPI28_16] # xmm3 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm3
	mulsd	xmm2, xmm1
	cvttsd2si	rax, xmm0
	addsd	xmm2, xmm3
	shl	rax, 52
	movabs	rcx, 4607182418800017408
	add	rcx, rax
	movq	xmm0, rcx
	mulsd	xmm0, xmm2
	cvtsd2ss	xmm0, xmm0
.LBB28_9:
	ret
                                        # -- End function
	.def	_xm_exp;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function _xm_exp
.LCPI29_0:
	.quad	0x7ff0000000000000              # double +Inf
.LCPI29_1:
	.quad	0x40862e3d70a3d70a              # double 709.77999999999997
.LCPI29_2:
	.quad	0xc087480000000000              # double -745
.LCPI29_3:
	.quad	0x3ff71547652b82fe              # double 1.4426950408889634
.LCPI29_4:
	.quad	0x3fe0000000000000              # double 0.5
.LCPI29_5:
	.quad	0xc330000000000000              # double -4503599627370496
.LCPI29_6:
	.quad	0x4330000000000000              # double 4503599627370496
.LCPI29_7:
	.quad	0xbff0000000000000              # double -1
.LCPI29_8:
	.quad	0xbfe62e42fefa39ef              # double -0.69314718055994529
.LCPI29_9:
	.quad	0x3ec71de3a556c734              # double 2.7557319223985893E-6
.LCPI29_10:
	.quad	0x3efa01a01a01a01a              # double 2.4801587301587302E-5
.LCPI29_11:
	.quad	0x3f2a01a01a01a01a              # double 1.9841269841269841E-4
.LCPI29_12:
	.quad	0x3f56c16c16c16c17              # double 0.0013888888888888889
.LCPI29_13:
	.quad	0x3f81111111111111              # double 0.0083333333333333332
.LCPI29_14:
	.quad	0x3fa5555555555555              # double 0.041666666666666664
.LCPI29_15:
	.quad	0x3fc5555555555555              # double 0.16666666666666666
.LCPI29_16:
	.quad	0x3ff0000000000000              # double 1
	.text
	.globl	_xm_exp
	.p2align	4, 0x90
_xm_exp:                                # @_xm_exp
# %bb.0:
	ucomisd	xmm0, xmm0
	jp	.LBB29_10
# %bb.1:
	ucomisd	xmm0, qword ptr [rip + .LCPI29_1]
	jbe	.LBB29_3
# %bb.2:
	movsd	xmm0, qword ptr [rip + .LCPI29_0] # xmm0 = [+Inf,0.0E+0]
	ret
.LBB29_3:
	xorpd	xmm1, xmm1
	movsd	xmm2, qword ptr [rip + .LCPI29_2] # xmm2 = [-7.45E+2,0.0E+0]
	ucomisd	xmm2, xmm0
	ja	.LBB29_9
# %bb.4:
	movsd	xmm1, qword ptr [rip + .LCPI29_3] # xmm1 = [1.4426950408889634E+0,0.0E+0]
	mulsd	xmm1, xmm0
	addsd	xmm1, qword ptr [rip + .LCPI29_4]
	movsd	xmm2, qword ptr [rip + .LCPI29_5] # xmm2 = [-4.503599627370496E+15,0.0E+0]
	ucomisd	xmm2, xmm1
	jae	.LBB29_8
# %bb.5:
	ucomisd	xmm1, xmm1
	jp	.LBB29_8
# %bb.6:
	ucomisd	xmm1, qword ptr [rip + .LCPI29_6]
	jae	.LBB29_8
# %bb.7:
	cvttsd2si	rax, xmm1
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, rax
	movsd	xmm3, qword ptr [rip + .LCPI29_7] # xmm3 = [-1.0E+0,0.0E+0]
	addsd	xmm3, xmm2
	cmpltsd	xmm1, xmm2
	andpd	xmm3, xmm1
	andnpd	xmm1, xmm2
	orpd	xmm1, xmm3
.LBB29_8:
	movsd	xmm2, qword ptr [rip + .LCPI29_8] # xmm2 = [-6.9314718055994529E-1,0.0E+0]
	mulsd	xmm2, xmm1
	addsd	xmm0, xmm2
	movsd	xmm2, qword ptr [rip + .LCPI29_9] # xmm2 = [2.7557319223985893E-6,0.0E+0]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI29_10]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI29_11]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI29_12]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI29_13]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI29_14]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI29_15]
	mulsd	xmm2, xmm0
	addsd	xmm2, qword ptr [rip + .LCPI29_4]
	mulsd	xmm2, xmm0
	movsd	xmm3, qword ptr [rip + .LCPI29_16] # xmm3 = [1.0E+0,0.0E+0]
	addsd	xmm2, xmm3
	mulsd	xmm2, xmm0
	addsd	xmm2, xmm3
	cvttsd2si	rax, xmm1
	shl	rax, 52
	movabs	rcx, 4607182418800017408
	add	rcx, rax
	movq	xmm1, rcx
	mulsd	xmm1, xmm2
.LBB29_9:
	movapd	xmm0, xmm1
.LBB29_10:
	ret
                                        # -- End function
	.def	_xm_powf;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_powf                        # -- Begin function _xm_powf
	.p2align	4, 0x90
_xm_powf:                               # @_xm_powf
# %bb.0:
	sub	rsp, 40
	cvtss2sd	xmm0, xmm0
	cvtss2sd	xmm1, xmm1
	call	pow
	cvtsd2ss	xmm0, xmm0
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xm_pow;
	.scl	2;
	.type	32;
	.endef
	.globl	_xm_pow                         # -- Begin function _xm_pow
	.p2align	4, 0x90
_xm_pow:                                # @_xm_pow
# %bb.0:
	jmp	pow                             # TAILCALL
                                        # -- End function
	.addrsig
