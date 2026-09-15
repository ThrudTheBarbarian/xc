//xtc-flags: target=arm64
//xtc-na: wasm32 win64 — bodyless+`...` means the C ABI, and the wasm module has no C world to call (host interop is the `env` import package instead); win64 because dprintf is POSIX-only — msvcrt/UCRT has no such symbol, so the link rightly refuses
// The bounded C-variadic rule (blewit item 2, Task #1082): a BODY-LESS
// declaration ending in `...` names a C callee, so the call is C-ABI — the
// tail is default-promoted and passed natively, no pack buffer and no
// va_list ever built. An xtc-BODIED variadic keeps the pack-buffer
// convention untouched. Per-target the tail differs: Darwin arm64 puts the
// ENTIRE tail on the stack in 8-byte slots (Apple's AAPCS deviation — a
// register-passed tail is what printf reads as garbage); SysV x86-64 uses
// the normal reg sequence plus AL = vector-register count (already emitted
// for the C-import path). dprintf because BOTH targets' libc has it and
// NEITHER target's Stdio.xc declares it (x86_64's Stdio declares snprintf
// fixed-sig, which the 1079 rule would rightly refuse to overload).
#use Stdio

i32 dprintf(i32 fd, u8* fmt, ...);

i32 main(void)
{
    dprintf((i32)1, (u8*)"n=%d s=%s x=%x\n", (i32)42, (u8*)"hi", (i32)$BEEF);
    dprintf((i32)1, (u8*)"f=%.2f d=%d\n", (double)3.25, (i32)7);
    dprintf((i32)1, (u8*)"many=%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
            (i32)1, (i32)2, (i32)3, (i32)4, (i32)5, (i32)6, (i32)7, (i32)8, (i32)9);
    return 0;
}
