//xtc-flags: target=arm64
// goto_class_local.xc — bug 632. A function with a goto pins every local; a
// class local initialised with `new` holds a REFERENCE, so its slot is a
// pointer. The reference compiler gave it an instance-sized slot, stored the
// pointer into it and called each method on the slot's own address (printed 3).
i32 printf(u8* f, ...);
class Pool {
    u32 outstanding;
    void submit(void) { outstanding++; }
    u32 count(void)   { return outstanding; }
}
i32 main(void) {
    Pool p = new Pool;
    p.submit(); p.submit();
    printf("%u\n", p.count());
    goto done;
done:
    return 0;
}
