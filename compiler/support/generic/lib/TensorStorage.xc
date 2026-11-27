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
