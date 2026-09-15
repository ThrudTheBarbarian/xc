// arc_param_rebind.xc — private:docs/bugs/064. Assigning a class-pointer PARAMETER
// from a strong LOCAL was a use-after-free: the parameter was a borrowed slot,
// so the store emitted no retain, the local stayed the owner, and its
// scope-exit release deallocated the object the parameter was then read
// through. It crashed at every -O level; the self-hosted arm64 assembler
// segfaulted on `tst w0, #0xff` because of it.
//
// The fix makes an ASSIGNED class-pointer parameter own what it holds —
// retained on entry, released on exit — so this checks the COUNT, not just
// that it runs. Both paths matter and they fail in opposite directions:
//   * swap taken     — the rebound object must survive the local's release
//                      (too FEW retains → use-after-free);
//   * swap not taken — the slot still holds the caller's borrowed argument,
//                      which the exit release must not free (too MANY
//                      releases → the caller's object dies under it).
#import "Stdio.xc"

i32 deallocs;

class Node
    {
    i32 id;
    Node init(i32 n) { id = n; return self; }
    void dealloc(void) { deallocs = deallocs + 1; }
    i32 get(void) { return id; }
    }

i32 rebind(Node* n, bool swap)
    {
    if (swap) {
        Node* fresh = new Node().init(9);
        n = fresh;
    }
    return n.get();
    }

void main(void)
    {
    deallocs = (i32)0;
    Node* a = new Node().init(1);

    // Not taken: the caller's object must come back intact and still be usable.
    Stdio.printf("noswap=%ld\n", rebind(a, false));
    Stdio.printf("alive=%ld deallocs=%ld\n", a.get(), deallocs);

    // Taken: the rebound object is read AFTER the local that made it has gone
    // out of scope — the read that used to touch freed memory.
    Stdio.printf("swap=%ld\n", rebind(a, true));
    Stdio.printf("alive=%ld deallocs=%ld\n", a.get(), deallocs);
    }
