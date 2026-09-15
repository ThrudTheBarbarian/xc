// va-arg — pins the va_start / va_arg_<T> / va_end intrinsic
// lowering shape. Sema resolves each intrinsic to the
// `__intrinsic_<name>` sentinel; the front-end lowering replaces
// the call with an abstract op — `VaStart` for va_start, `VaArg`
// (result + memory) for each va_arg_<T> — carrying the pinned u8
// cursor slot (task #120). It does NOT expand the buffer access
// itself: a per-target pass does that later — XTIROptVaArgExpand
// unfolds it into __xtc_va_buf[cursor] reads (cursor += slot) for
// the buffer-path backends (arm64 / xt6502 / m68k), while the arm9
// backend lowers VaStart/VaArg straight to a native AAPCS va_list.
// The cursor stays memory-backed (not an SSA rebind) so the offset
// remains loop-carried correctly when va_arg sits inside a loop.
u16 sum(u8 first, ...)
    {
    u8 ap;
    va_start(ap);
    u16 a = va_arg_u16(ap);
    u16 b = va_arg_u16(ap);
    va_end(ap);
    return first + a + b;
    }
