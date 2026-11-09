// CheckedVtbl.xc — the vtable check of -fbounds-check=light and -fbounds-check
// on the 64-bit targets (arm64, x86-64, win64), imported by the compiler into
// such a build.
//
// An object's first word is its vtable pointer, so an overrun or a use after
// free that writes over an object can send its virtual calls anywhere. Before
// each call, or load of a method, through a vtable the compiler calls
// _xt_check_vtbl(receiver, "file:line:col"). A null receiver passes (the call
// itself then behaves as it does in an unchecked build); otherwise the vtable
// pointer must lie inside the class tables of a loaded image.
//
// Every image's tables sit in one run, which the image describes: a
// __DATA,__xt_vtbl section in a Mach-O file, a program header of its own
// (PT_XT_VTBL) in an ELF file, an .xtvt section holding the run's two RVAs in
// a PE file. The check compares against this image's run, which the slow path
// looks up once; anything outside it goes to the slow path, which finds the
// image that holds the pointer (a library, a bundle, a plugin) through the
// loader and accepts the pointer if it is inside that image's run. A pointer
// into the heap, the stack or memory no image owns, or into an image but not
// its tables, stops the program with status 134 and names the call site.
//
// Like the subscript checks, nothing here allocates or takes a lock.

i32 write(i32 fd, u8* buf, i32 len);   // as Stdio declares it
void _xt_exit(i32 code);

#if OS_darwin
struct _XtVtblDlInfo { u8* fname; pointer fbase; u8* sname; pointer saddr; }
i32 dladdr(pointer addr, _XtVtblDlInfo* info);
u8* getsectiondata(pointer mh, u8* segname, u8* sectname, u64* size);
#elif OS_windows
pointer RtlPcToFileHeader(pointer pc, pointer* base);
#elif LIBC_musl
u64 getauxval(u64 type);
#else
struct _XtVtblDlInfo { u8* fname; pointer fbase; u8* sname; pointer saddr; }
i32 dladdr(pointer addr, _XtVtblDlInfo* info);
#endif

// The ELF program header type of the class tables' run: in the PT_LOOS range.
#define XT_PT_XT_VTBL $60787476

// This image's run as [lo, lo + len). Until the slow path has looked it up,
// len is 0 and every check goes there. lo starts at 1 << 63, an address no
// pointer has, so a thread that sees the new len before the new lo accepts
// nothing it would not fault on anyway.
u64 _xt_check_vtbl_lo = (u64)0x8000000000000000;
u64 _xt_check_vtbl_len = (u64)0;

// Other images' runs, once found: one word each, the start (in 8-byte units)
// in the low 44 bits and the length (in 8-byte units) above it, so a slot is
// written and read whole. A run that does not fit is looked up every time.
u64 _xt_check_vtbl_seen[4];

void _xt_check_vtbl_put(u8* s)
{
    u64 n = (u64)0;
    while (s[n] != (u8)0)
        n = n + (u64)1;
    write((i32)2, s, (i32)n);
}

void _xt_check_vtbl_putHex(u64 v)
{
    u8 buf[20];
    buf[0] = (u8)'0';
    buf[1] = (u8)'x';
    u32 at = (u32)2;
    bool started = false;
    for (i32 sh = (i32)60; sh >= (i32)0; sh = sh - (i32)4)
        {
        u64 d = (v >> (u64)sh) & (u64)15;
        if (d != (u64)0 || started || sh == (i32)0)
            {
            buf[at] = (u8)(d < (u64)10 ? (u64)'0' + d : (u64)'a' + d - (u64)10);
            at = at + (u32)1;
            started = true;
            }
        }
    buf[at] = (u8)0;
    _xt_check_vtbl_put(&buf[0]);
}

#if !OS_darwin && !OS_windows
// The run an ELF image's program headers describe, given where they are and
// the image's load bias: its start, with its length through `len`.
u64 _xt_check_vtbl_phdrs(u8* ph, u64 phnum, u64 bias, u64 p, u64* len)
{
    u64 lo = (u64)0;
    u64 n = (u64)0;
    bool holds = false;
    for (u64 i = (u64)0; i < phnum; i = i + (u64)1)
        {
        u8* h = ph + i * (u64)56;
        u32 type = *(u32*)(pointer)h;
        u64 va = *(u64*)(pointer)(h + 16) + bias;
        u64 sz = *(u64*)(pointer)(h + 40);
        if (type == (u32)1 && p - va < sz)
            holds = true;
        if (type == (u32)XT_PT_XT_VTBL)
            {
            lo = va;
            n = sz;
            }
        }
    if (holds)
        *len = n;
    return lo;
}
#endif

// The class tables' run of the loaded image that holds address p: its start,
// with its length through `len` (0 when no image holds p, or the image has no
// tables).
u64 _xt_check_vtbl_image(u64 p, u64* len)
{
    *len = (u64)0;
#if OS_darwin
    _XtVtblDlInfo info;
    if (dladdr((pointer)p, &info) == (i32)0 || info.fbase == (pointer)0)
        return (u64)0;
    u64 sz = (u64)0;
    u8* s = getsectiondata(info.fbase, "__DATA", "__xt_vtbl", &sz);
    if (s == (u8*)0)
        return (u64)0;
    *len = sz;
    return (u64)s;
#elif OS_windows
    pointer base = (pointer)0;
    if (RtlPcToFileHeader((pointer)p, &base) == (pointer)0 || base == (pointer)0)
        return (u64)0;
    u8* b = (u8*)base;
    u8* nt = b + (u64)*(u32*)(pointer)(b + 60);
    u64 nsec = (u64)*(u16*)(pointer)(nt + 6);
    u8* sec = nt + (u64)24 + (u64)*(u16*)(pointer)(nt + 20);
    for (u64 i = (u64)0; i < nsec; i = i + (u64)1)
        {
        u8* h = sec + i * (u64)40;
        if (h[0] == (u8)'.' && h[1] == (u8)'x' && h[2] == (u8)'t' && h[3] == (u8)'v' && h[4] == (u8)'t' && h[5] == (u8)0)
            {
            u32* d = (u32*)(pointer)(b + (u64)*(u32*)(pointer)(h + 12));
            *len = (u64)(d[1] - d[0]);
            return (u64)(b + (u64)d[0]);
            }
        }
    return (u64)0;
#elif LIBC_musl
    // A static executable: the only image, its program headers where the
    // kernel says (AT_PHDR, AT_PHNUM), its bias from PT_PHDR when it has one.
    u8* ph = (u8*)(pointer)getauxval((u64)3);
    u64 phnum = getauxval((u64)5);
    if (ph == (u8*)0)
        return (u64)0;
    u64 bias = (u64)0;
    for (u64 i = (u64)0; i < phnum; i = i + (u64)1)
        {
        u8* h = ph + i * (u64)56;
        if (*(u32*)(pointer)h == (u32)6)
            bias = (u64)ph - *(u64*)(pointer)(h + 16);
        }
    return _xt_check_vtbl_phdrs(ph, phnum, bias, p, len);
#else
    // A dynamic image: the loader knows where it starts, which is its ELF
    // header; the bias is that, less the address its first segment asks for.
    _XtVtblDlInfo info;
    if (dladdr((pointer)p, &info) == (i32)0 || info.fbase == (pointer)0)
        return (u64)0;
    u8* eh = (u8*)info.fbase;
    u8* ph = eh + *(u64*)(pointer)(eh + 32);
    u64 phnum = (u64)*(u16*)(pointer)(eh + 56);
    u64 first = (u64)0;
    bool found = false;
    for (u64 i = (u64)0; i < phnum; i = i + (u64)1)
        {
        u8* h = ph + i * (u64)56;
        if (*(u32*)(pointer)h == (u32)1 && !found)
            {
            first = *(u64*)(pointer)(h + 16) - *(u64*)(pointer)(h + 8);
            found = true;
            }
        }
    return _xt_check_vtbl_phdrs(ph, phnum, (u64)eh - first, p, len);
#endif
}

// A vtable pointer outside this image's run (or any, before the run is known).
// Returns when the pointer is inside a loaded image's run; stops the program
// otherwise.
void _xt_check_vtbl_trap(u64 v, u8* site)
{
    if (_xt_check_vtbl_len == (u64)0)
        {
        u64 n = (u64)0;
        u64 lo = _xt_check_vtbl_image((u64)(pointer)&_xt_check_vtbl_lo, &n);
        if (n != (u64)0)
            {
            _xt_check_vtbl_lo = lo;
            _xt_check_vtbl_len = n;
            }
        if (v - lo < n)
            return;
        }
    for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
        {
        u64 w = _xt_check_vtbl_seen[k];
        if (w != (u64)0 && v - ((w & (u64)0xFFFFFFFFFFF) << (u64)3) < ((w >> (u64)44) << (u64)3))
            return;
        }
    u64 len = (u64)0;
    u64 lo2 = _xt_check_vtbl_image(v, &len);
    if (v - lo2 < len)
        {
        if ((lo2 & (u64)7) == (u64)0 && (len & (u64)7) == (u64)0
            && (lo2 >> (u64)47) == (u64)0 && (len >> (u64)23) == (u64)0)
            _xt_check_vtbl_seen[(lo2 >> (u64)16) & (u64)3] = (lo2 >> (u64)3) | ((len >> (u64)3) << (u64)44);
        return;
        }
    _xt_check_vtbl_put("\n=== xcc: a virtual call through a pointer that is not a vtable ===\n  at ");
    _xt_check_vtbl_put(site != (u8*)0 ? site : "?");
    _xt_check_vtbl_put("\n  the object's vtable pointer is ");
    _xt_check_vtbl_putHex(v);
    _xt_check_vtbl_put(", which is in no loaded image's class tables\n  aborting\n");
    _xt_exit((i32)134);
}

// The check itself, inlined at each dispatch in a -fbounds-check=light build:
// one load, one subtract and one compare when the vtable is this image's. One
// return and no merged values, so the inliner takes it.
void _xt_check_vtbl(pointer obj, u8* site)
{
    if (obj != (pointer)0)
        {
        u64 v = *(u64*)obj;
        if (v - _xt_check_vtbl_lo >= _xt_check_vtbl_len)
            _xt_check_vtbl_trap(v, site);
        }
}
