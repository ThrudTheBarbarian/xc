// A user `dealloc` and a weak back-pointer, through the PORTED chain — the two
// things `support/arm9/lib/Runtime.xc` could not do until the weak chain and
// the dealloc dispatch went in. Both are observable from the program:
//
//   - `Node.dealloc` runs when the last strong reference goes, and writes a
//     digit into the line about to be printed. If the header's function
//     pointer is not dispatched, the digit stays '0'.
//   - `w` is a WEAK reference to the same object. After the object dies the
//     slot must read null, not a dangling pointer — and reading it is what
//     proves the chain was walked rather than merely allocated.
//
// Column map of the line (0-based): the digit is at 13, and "LIVE" at 27..30.
//
// The flag is a plain global rather than a pointer to the line: a global
// initialised from a string literal needs the module initialiser to have run,
// and the point here is the runtime, not the start-up path.
#import "Runtime.xc"

i32 write(i32 fd, u8* buf, u32 n);

u32 deallocRan;

class Node
    {
    u32 tag;
    void init(void)
        {
        tag = (u32)5;
        }
    void dealloc(void)
        {
        deallocRan = (u32)1;
        }
    }

    void
    main(void)
    {
weak:
    // last strong reference goes here
    Node* w = (weak : Node*)0;
        {
        Node* n = new Node();
        w = n; // registers the slot on n's chain
        }
    u8* line = (u8*)"dealloc ran: 0   weak now: LIVE\n";
    if (deallocRan != (u32)0)
        line[13] = (u8)'1';
    if (w == (weak : Node*)0)
        {
        line[27] = (u8)'N';
        line[28] = (u8)'U';
        line[29] = (u8)'L';
        line[30] = (u8)'L';
        }
    write((i32)1, line, (u32)32);
    }
