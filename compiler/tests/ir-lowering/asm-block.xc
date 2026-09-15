// asm-block — pins the inline-asm lowering shape. The asm body is
// opaque to the IR; the lowering captures it as a constant-pool
// string and threads the memory token through the Asm op. Backends
// no-op on arm64 (can't execute 6502) and pass-through on xt6502.
void poke(u8 v)
    {
    asm
    {
        LDA v
        STA $D40A
    }
    return;
    }
