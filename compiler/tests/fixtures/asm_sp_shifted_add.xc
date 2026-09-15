// asm_sp_shifted_add.xc — a frame-slot address at a 4096-ALIGNED offset.
//
// emitSpAddr has three branches, and the middle one emits
//
//     add xN, sp, #<off>>12>, lsl #12
//
// when an addressed slot's offset is an exact multiple of 4096. That is valid
// AArch64 (clang encodes it 0x914007ea for `add x10, sp, #1, lsl #12`), but the
// in-house assembler decided immediate-vs-register on the LAST operand — which
// here is the shift, not the immediate — so it took the register path, tried to
// parse `#1` as a register, and failed with "bad rm #1". With clang fallback
// disabled that is a hard build failure, so any function whose frame puts an
// address-taken local on a 4096 boundary could not be built at all. private:docs/bugs/060.
//
// The padding is tuned so the offset lands EXACTLY on the boundary: a plain
// 4096-byte array does not do it, because slots start past the outgoing-arg
// area and x29/x30. Check the emitted asm actually contains `lsl #12` before
// trusting any change to this fixture — without it the test proves nothing.
u8 gsink;

void f(void)
{
    u8 pad[4072];
    u32 x;
    u32* p = &x;        // forces a frame-slot ADDRESS, not just a slot
    *p = (u32)7;
    pad[0] = (u8)*p;
    gsink = pad[0];
}

void main(void)
{
    f();
    if (gsink != (u8)7) { gsink = (u8)0; }
}
