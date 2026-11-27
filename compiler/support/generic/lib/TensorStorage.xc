// TensorStorage.xc — the buffer behind tensor values.
//
// A `tensor<T, R>` value is a view: a reference to one TensorStorage, an
// element offset, and R shapes and R strides, all counted in elements. Every
// copy of the value refers to the same storage, so a write through one is seen
// through the others, and the storage goes when the last value referring to it
// goes. The compiler imports this file into any unit that uses a tensor type,
// and generates the value classes on top of it.
//
// The buffer is page-aligned (a `simd:` array), so a GPU on unified memory can
// use it in place, and zero-filled. Its size is ceil(count * bits / 8) bytes:
// f4 elements take a nibble each, element 0 in the low nibble.
//
// `residency` is for the par runtime: which devices hold a current copy of the
// buffer. Nothing sets it yet; it stays null.

#if ARCH_6502
// A tensor value (the storage, the offset, a shape and a stride for each
// dimension) is more than the 16 bytes xt6502 returns by value, and creating
// one returns it.
#error "tensors are not available on xt6502, whose functions return at most 16 bytes by value"
#endif

u64 _xt_tensor_live;

// A view the strides cannot express, a broadcast of the wrong shape and,
// under -fbounds-check, a slice out of range stop the program with a report
// on the error output and status 134, as a failed bounds check does.
#if ARCH_m68k || ARCH_wasm32
void _putc(u8 c);
#else
i32 write(i32 fd, u8* buf, i32 len);
#endif
void _xt_exit(i32 code);

void _xt_tensor_put(u8* s)
{
#if ARCH_m68k || ARCH_wasm32
    for (u32 i = 0; s[i] != 0; i++)
        _putc(s[i]);
#else
    u64 n = 0;
    while (s[n] != 0)
        n = n + 1;
    write(2, s, (i32)n);
#endif
}

void _xt_tensor_putNum(u64 v)
{
    u8 buf[24];
    u32 at = 23;
    buf[at] = 0;
    if (v == 0)
        {
        at = at - 1;
        buf[at] = '0';
        }
    while (v != 0)
        {
        at = at - 1;
        buf[at] = (u8)('0' + v % 10);
        v = v / 10;
        }
    _xt_tensor_put(&buf[at]);
}

void _xt_tensor_stop(void)
{
    _xt_tensor_put("  aborting\n");
    _xt_exit(134);
}

// broadcast(…): dimension `dim`, of size `from`, cannot become `to`.
void _xt_tensor_fail_broadcast(u64 dim, u64 from, u64 to)
{
    _xt_tensor_put("\n=== xcc: a tensor that cannot broadcast ===\n  dimension ");
    _xt_tensor_putNum(dim);
    _xt_tensor_put(" has size ");
    _xt_tensor_putNum(from);
    _xt_tensor_put(" and cannot broadcast to ");
    _xt_tensor_putNum(to);
    _xt_tensor_put(": only a dimension of size 1 repeats\n");
    _xt_tensor_stop();
}

// view(…) or reshape(…) (`what`) of `had` elements as `asked`.
void _xt_tensor_fail_count(u8* what, u64 had, u64 asked)
{
    _xt_tensor_put("\n=== xcc: a tensor reshaped to another size ===\n  ");
    _xt_tensor_put(what);
    _xt_tensor_put("() of ");
    _xt_tensor_putNum(had);
    _xt_tensor_put(had == 1 ? " element as " : " elements as ");
    _xt_tensor_putNum(asked);
    _xt_tensor_put("\n");
    _xt_tensor_stop();
}

void _xt_tensor_fail_view(void)
{
    _xt_tensor_put("\n=== xcc: a view the strides cannot express ===\n  view() of a tensor whose elements are not "
                   "contiguous where the new shape merges dimensions: reshape() copies them, or copy() the tensor first\n");
    _xt_tensor_stop();
}

// -fbounds-check's test of one dimension of a slice `lo..hi` (`lo...hi` when
// incl is 1): lo <= hi + incl <= shape. The compiler calls it before the
// slice is taken, with the slice's site.
void _xt_check_tensor_slice(u64 lo, u64 hi, u64 incl, u64 shape, u8* site)
{
    u64 end = hi + incl;
    if (lo <= end && end <= shape && end >= hi)
        return;
    _xt_tensor_put("\n=== xcc: out-of-bounds slice ===\n  at ");
    _xt_tensor_put(site);
    _xt_tensor_put("\n  slice ");
    _xt_tensor_putNum(lo);
    _xt_tensor_put(incl != 0 ? "..." : "..");
    _xt_tensor_putNum(hi);
    _xt_tensor_put(", but the dimension holds ");
    _xt_tensor_putNum(shape);
    _xt_tensor_put(shape == 1 ? " element\n" : " elements\n");
    _xt_tensor_stop();
}

// The strides that give the `nrank` shapes `ns` over the elements of a view
// with shapes `os` and strides `ot` (`orank` of each), into `nt`; false when
// no strides can (a reshape that merges dimensions which are not laid out
// one after the other). The element counts are equal. Dimensions are taken
// in chunks, each a run the old strides lay out contiguously, as PyTorch's
// view does.
bool _xt_tensor_strides(u64* os, u64* ot, u64 orank, u64* ns, u64* nt, u64 nrank)
{
    u64 n = 1;
    for (u64 k = 0; k < orank; k++)
        n = n * os[k];
    if (n == 0)
        {
        // No elements: the contiguous strides do.
        u64 c = 1;
        u64 j = nrank;
        while (j > 0)
            {
            j = j - 1;
            nt[j] = c;
            if (ns[j] > 1)
                c = c * ns[j];
            }
        return true;
        }
    i64 vd = (i64)nrank - 1;
    u64 base = ot[orank - 1];
    u64 tn = 1;
    u64 vn = 1;
    u64 td = orank;
    while (td > 0)
        {
        td = td - 1;
        tn = tn * os[td];
        // A chunk ends where the dimension before this one does not follow
        // it in memory.
        if (td == 0 || (os[td - 1] != 1 && ot[td - 1] != tn * base))
            {
            while (vd >= 0 && (vn < tn || ns[vd] == 1))
                {
                nt[vd] = vn * base;
                vn = vn * ns[vd];
                vd = vd - 1;
                }
            if (vn != tn)
                return false;
            if (td > 0)
                {
                base = ot[td - 1];
                tn = 1;
                vn = 1;
                }
            }
        }
    return vd == -1;
}

class TensorStorage
    {
    simd: u8* data;      // the elements, page-aligned, zero-filled
    u64 count;           // how many elements
    u64 bytes;           // the buffer's size in bytes
    u64 bits;            // the size of one element in bits (4 for f4)
    pointer residency;   // the par runtime's device copies (null for now)

    // A zero-filled storage for n elements of `elemBits` bits each.
    static TensorStorage* alloc(u64 n, u64 elemBits)
        {
        TensorStorage* s = new TensorStorage();
        s.count = n;
        s.bits = elemBits;
        s.bytes = (n * elemBits + 7) >> 3;
        s.data = new u8[s.bytes];
#if ARCH_arm64 || ARCH_x86_64
        // f4 elements are indexed through an f4[], whose checks (under
        // -fbounds-check) count elements: the header holds n, as new f4[n]'s
        // does on these targets.
        if (elemBits == 4 && n != 0)
            {
            // Addressed as an integer, so a checked build does not read the
            // header word as element -32 of the buffer.
            u64* count = (u64*)(pointer)((u64)(pointer)s.data - 32);
            *count = n;
            }
#endif
        _xt_tensor_live = _xt_tensor_live + 1;
        return s;
        }

    void dealloc(void)
        {
        delete data;
        _xt_tensor_live = _xt_tensor_live - 1;
        }

    // How many storages are alive: a count for tests, not synchronised
    // between threads.
    static u64 live(void)
        {
        return _xt_tensor_live;
        }
    }
