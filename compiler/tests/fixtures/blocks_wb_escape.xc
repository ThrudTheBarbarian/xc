// blocks_wb_escape.xc — v2 escape rule: a block carrying a `block:`
// capture writes back into its enclosing FRAME, so it must not outlive
// it. Returning one is a compile error.
//xtc-flags: expect=sema-error
#import "Foundation.xc"

block cb u32(u32) leak(void)
{
    block:u32 t = (u32)0;
    block b u32(u32 v) = { t = t + v; return t; }
    return b;
}

i32 main(void) { return 0; }
