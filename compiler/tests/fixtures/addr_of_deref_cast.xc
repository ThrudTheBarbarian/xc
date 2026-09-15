//xtc-flags: target=arm64
// addr_of_deref_cast.xc — bug 184 (c2xc bug 18). `&(*(T*)p)` folds to the
// pointer itself; address-of-dereference cancels. Was "& supported only on
// identifiers or struct member-access".
i32 printf(u8* f, ...);
i32 main(void) {
    i32 v = 7;
    i32* p = &v;
    i32* q = &(*(i32*)p);
    printf("%d\n", *q);
    return 0;
}
