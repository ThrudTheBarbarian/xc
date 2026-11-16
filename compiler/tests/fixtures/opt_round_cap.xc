// Seventy independent pointer-walk loops in one function: the pointer-IV
// pass rewrites one loop per round under a cap of 64 rounds, so it stops
// at the cap with loops left (#334). XC_OPT_CAPS=1 reports that; the
// result is the same either way.
#import "Stdio.xc"
u32 walk(u32* a, u32 n)
    {
    u32 s = (u32)0;
    for (u32 i0 = (u32)0; i0 < n; i0 = i0 + (u32)1)
        s = s + a[i0] * (u32)1;
    for (u32 i1 = (u32)0; i1 < n; i1 = i1 + (u32)1)
        s = s + a[i1] * (u32)2;
    for (u32 i2 = (u32)0; i2 < n; i2 = i2 + (u32)1)
        s = s + a[i2] * (u32)3;
    for (u32 i3 = (u32)0; i3 < n; i3 = i3 + (u32)1)
        s = s + a[i3] * (u32)4;
    for (u32 i4 = (u32)0; i4 < n; i4 = i4 + (u32)1)
        s = s + a[i4] * (u32)5;
    for (u32 i5 = (u32)0; i5 < n; i5 = i5 + (u32)1)
        s = s + a[i5] * (u32)6;
    for (u32 i6 = (u32)0; i6 < n; i6 = i6 + (u32)1)
        s = s + a[i6] * (u32)7;
    for (u32 i7 = (u32)0; i7 < n; i7 = i7 + (u32)1)
        s = s + a[i7] * (u32)8;
    for (u32 i8 = (u32)0; i8 < n; i8 = i8 + (u32)1)
        s = s + a[i8] * (u32)9;
    for (u32 i9 = (u32)0; i9 < n; i9 = i9 + (u32)1)
        s = s + a[i9] * (u32)10;
    for (u32 i10 = (u32)0; i10 < n; i10 = i10 + (u32)1)
        s = s + a[i10] * (u32)11;
    for (u32 i11 = (u32)0; i11 < n; i11 = i11 + (u32)1)
        s = s + a[i11] * (u32)12;
    for (u32 i12 = (u32)0; i12 < n; i12 = i12 + (u32)1)
        s = s + a[i12] * (u32)13;
    for (u32 i13 = (u32)0; i13 < n; i13 = i13 + (u32)1)
        s = s + a[i13] * (u32)14;
    for (u32 i14 = (u32)0; i14 < n; i14 = i14 + (u32)1)
        s = s + a[i14] * (u32)15;
    for (u32 i15 = (u32)0; i15 < n; i15 = i15 + (u32)1)
        s = s + a[i15] * (u32)16;
    for (u32 i16 = (u32)0; i16 < n; i16 = i16 + (u32)1)
        s = s + a[i16] * (u32)17;
    for (u32 i17 = (u32)0; i17 < n; i17 = i17 + (u32)1)
        s = s + a[i17] * (u32)18;
    for (u32 i18 = (u32)0; i18 < n; i18 = i18 + (u32)1)
        s = s + a[i18] * (u32)19;
    for (u32 i19 = (u32)0; i19 < n; i19 = i19 + (u32)1)
        s = s + a[i19] * (u32)20;
    for (u32 i20 = (u32)0; i20 < n; i20 = i20 + (u32)1)
        s = s + a[i20] * (u32)21;
    for (u32 i21 = (u32)0; i21 < n; i21 = i21 + (u32)1)
        s = s + a[i21] * (u32)22;
    for (u32 i22 = (u32)0; i22 < n; i22 = i22 + (u32)1)
        s = s + a[i22] * (u32)23;
    for (u32 i23 = (u32)0; i23 < n; i23 = i23 + (u32)1)
        s = s + a[i23] * (u32)24;
    for (u32 i24 = (u32)0; i24 < n; i24 = i24 + (u32)1)
        s = s + a[i24] * (u32)25;
    for (u32 i25 = (u32)0; i25 < n; i25 = i25 + (u32)1)
        s = s + a[i25] * (u32)26;
    for (u32 i26 = (u32)0; i26 < n; i26 = i26 + (u32)1)
        s = s + a[i26] * (u32)27;
    for (u32 i27 = (u32)0; i27 < n; i27 = i27 + (u32)1)
        s = s + a[i27] * (u32)28;
    for (u32 i28 = (u32)0; i28 < n; i28 = i28 + (u32)1)
        s = s + a[i28] * (u32)29;
    for (u32 i29 = (u32)0; i29 < n; i29 = i29 + (u32)1)
        s = s + a[i29] * (u32)30;
    for (u32 i30 = (u32)0; i30 < n; i30 = i30 + (u32)1)
        s = s + a[i30] * (u32)31;
    for (u32 i31 = (u32)0; i31 < n; i31 = i31 + (u32)1)
        s = s + a[i31] * (u32)32;
    for (u32 i32 = (u32)0; i32 < n; i32 = i32 + (u32)1)
        s = s + a[i32] * (u32)33;
    for (u32 i33 = (u32)0; i33 < n; i33 = i33 + (u32)1)
        s = s + a[i33] * (u32)34;
    for (u32 i34 = (u32)0; i34 < n; i34 = i34 + (u32)1)
        s = s + a[i34] * (u32)35;
    for (u32 i35 = (u32)0; i35 < n; i35 = i35 + (u32)1)
        s = s + a[i35] * (u32)36;
    for (u32 i36 = (u32)0; i36 < n; i36 = i36 + (u32)1)
        s = s + a[i36] * (u32)37;
    for (u32 i37 = (u32)0; i37 < n; i37 = i37 + (u32)1)
        s = s + a[i37] * (u32)38;
    for (u32 i38 = (u32)0; i38 < n; i38 = i38 + (u32)1)
        s = s + a[i38] * (u32)39;
    for (u32 i39 = (u32)0; i39 < n; i39 = i39 + (u32)1)
        s = s + a[i39] * (u32)40;
    for (u32 i40 = (u32)0; i40 < n; i40 = i40 + (u32)1)
        s = s + a[i40] * (u32)41;
    for (u32 i41 = (u32)0; i41 < n; i41 = i41 + (u32)1)
        s = s + a[i41] * (u32)42;
    for (u32 i42 = (u32)0; i42 < n; i42 = i42 + (u32)1)
        s = s + a[i42] * (u32)43;
    for (u32 i43 = (u32)0; i43 < n; i43 = i43 + (u32)1)
        s = s + a[i43] * (u32)44;
    for (u32 i44 = (u32)0; i44 < n; i44 = i44 + (u32)1)
        s = s + a[i44] * (u32)45;
    for (u32 i45 = (u32)0; i45 < n; i45 = i45 + (u32)1)
        s = s + a[i45] * (u32)46;
    for (u32 i46 = (u32)0; i46 < n; i46 = i46 + (u32)1)
        s = s + a[i46] * (u32)47;
    for (u32 i47 = (u32)0; i47 < n; i47 = i47 + (u32)1)
        s = s + a[i47] * (u32)48;
    for (u32 i48 = (u32)0; i48 < n; i48 = i48 + (u32)1)
        s = s + a[i48] * (u32)49;
    for (u32 i49 = (u32)0; i49 < n; i49 = i49 + (u32)1)
        s = s + a[i49] * (u32)50;
    for (u32 i50 = (u32)0; i50 < n; i50 = i50 + (u32)1)
        s = s + a[i50] * (u32)51;
    for (u32 i51 = (u32)0; i51 < n; i51 = i51 + (u32)1)
        s = s + a[i51] * (u32)52;
    for (u32 i52 = (u32)0; i52 < n; i52 = i52 + (u32)1)
        s = s + a[i52] * (u32)53;
    for (u32 i53 = (u32)0; i53 < n; i53 = i53 + (u32)1)
        s = s + a[i53] * (u32)54;
    for (u32 i54 = (u32)0; i54 < n; i54 = i54 + (u32)1)
        s = s + a[i54] * (u32)55;
    for (u32 i55 = (u32)0; i55 < n; i55 = i55 + (u32)1)
        s = s + a[i55] * (u32)56;
    for (u32 i56 = (u32)0; i56 < n; i56 = i56 + (u32)1)
        s = s + a[i56] * (u32)57;
    for (u32 i57 = (u32)0; i57 < n; i57 = i57 + (u32)1)
        s = s + a[i57] * (u32)58;
    for (u32 i58 = (u32)0; i58 < n; i58 = i58 + (u32)1)
        s = s + a[i58] * (u32)59;
    for (u32 i59 = (u32)0; i59 < n; i59 = i59 + (u32)1)
        s = s + a[i59] * (u32)60;
    for (u32 i60 = (u32)0; i60 < n; i60 = i60 + (u32)1)
        s = s + a[i60] * (u32)61;
    for (u32 i61 = (u32)0; i61 < n; i61 = i61 + (u32)1)
        s = s + a[i61] * (u32)62;
    for (u32 i62 = (u32)0; i62 < n; i62 = i62 + (u32)1)
        s = s + a[i62] * (u32)63;
    for (u32 i63 = (u32)0; i63 < n; i63 = i63 + (u32)1)
        s = s + a[i63] * (u32)64;
    for (u32 i64 = (u32)0; i64 < n; i64 = i64 + (u32)1)
        s = s + a[i64] * (u32)65;
    for (u32 i65 = (u32)0; i65 < n; i65 = i65 + (u32)1)
        s = s + a[i65] * (u32)66;
    for (u32 i66 = (u32)0; i66 < n; i66 = i66 + (u32)1)
        s = s + a[i66] * (u32)67;
    for (u32 i67 = (u32)0; i67 < n; i67 = i67 + (u32)1)
        s = s + a[i67] * (u32)68;
    for (u32 i68 = (u32)0; i68 < n; i68 = i68 + (u32)1)
        s = s + a[i68] * (u32)69;
    for (u32 i69 = (u32)0; i69 < n; i69 = i69 + (u32)1)
        s = s + a[i69] * (u32)70;
    return s;
    }
i32 main(i32 argc, u8** argv)
    {
    u32 a[16];
    for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
        a[i] = i + (u32)argc;
    Stdio.printf("%u\n", walk(&a[0], (u32)16));
    return 0;
    }
