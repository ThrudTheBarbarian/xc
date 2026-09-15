// arc_upcast_return_local.xc — returning a NAMED strong local through an upcast
// must not release it on the way out.
//
// It did. `return (Base@)local;` hands back the CAST, whose SSA value differs
// from the local's, so the return-path ARC exemption compared value ids, missed
// the local, and released it — the caller then held freed memory. The temp form,
// `return (Base@)new T();`, was already correct (an earlier fix retargeted owned
// TEMPS through the Bitcast), which is why this survived: the natural-looking
// idiom was the broken one.
//
// Found writing Map.copy for the Copying protocol, where it presented as a copy
// with the right count but zero enumerable entries — a freed object still
// reading plausibly.
//
// Each object must deallocate exactly ONCE, and only after its last use.

#import "Stdio.xc"

class Thing
{
    u32 v;
    void init(u32 x)   { v = x; }
    void dealloc(void) { Stdio.printf("dealloc %d\n", v); }
    u32 get(void)      { return v; }
}

// named strong local, returned upcast — the case that was broken
Object* viaLocal(void) { Thing* t = new Thing((u32)7); return (Object*)t; }

// temp, returned upcast — was already correct; guards against regressing it
Object* viaTemp(void) { return (Object*)new Thing((u32)8); }

void main(void)
{
    Object* a = viaLocal();
    Stdio.printf("local v=%d\n", ((Thing*)a).get());
    Object* b = viaTemp();
    Stdio.printf("temp  v=%d\n", ((Thing*)b).get());
    Stdio.printf("end\n");
}
