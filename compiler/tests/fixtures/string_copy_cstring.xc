// `copyCString()` — the safe form of `cString()` (private:docs/bugs/056).
//
// `cString()` is a BORROW into the String's buffer: any growth may realloc
// and free the old bytes, so a held borrow dangles — and usually still
// appears to work, which is why nothing caught it. `copyCString()` returns
// a heap copy the caller owns; nothing the String later does can touch it.
//
// The append below crosses the initial 16-byte capacity, so `_reserve`
// reallocs and frees the buffer the borrow pointed into — the copy taken
// BEFORE the growth must still read back intact afterwards.
#import "Stdio.xc"
#import "String.xc"

i32 main(void)
{
    String* s = String.withCString("keep");
    string copy = s.copyCString();
    s.appendCString(" me around, buffer, while you grow");
    Stdio.printf("copy=%s\n", copy);
    Stdio.printf("grown=%s len=%d\n", s.cString(), (u16)s.byteLength());
    delete copy;

    // Empty String: still a valid, owned, NUL-terminated (empty) copy.
    String* e = String.withCString("");
    string ec = e.copyCString();
    Stdio.printf("empty=[%s]\n", ec);
    delete ec;
    return 0;
}
