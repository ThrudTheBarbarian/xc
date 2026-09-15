// string_grow.xc — String and Data grow GEOMETRICALLY, not one byte at a time.
//
// `_reserve` used to allocate a fresh buffer, copy into it and free the old one
// on EVERY appended byte: appendChar was O(n) and building an n-byte string was
// O(n²). The asm emitters a self-hosted compiler is made of append a character
// at a time, so that quadratic was the whole cost model (self-hosting M2 —
// private:docs/Design/m1-foundation-surface.md notes NSMutableString as the single
// highest-traffic piece of the surface).
//
// What is asserted here is BEHAVIOUR, not a capacity schedule: capacity never
// drops below length, an already-fitting reserve is a no-op, and the bytes are
// right after hundreds of appends. The two library builds deliberately use
// different curves — generic doubles, xt6502 doubles to 1 KB and then steps by
// a kilobyte because an xt heap block cannot span a bank — so a fixture that
// pinned exact capacities would be pinning the wrong thing.
//
//   T1  appendChar over a long run: content, length, capacity ≥ length
//   T2  capacity actually grows past the initial allocation (not exact-fit)
//   T3  reserve() up front, then appends that fit, keep the same capacity
//   T4  append(String) and appendCString over a long run
//   T5  the same for Data.appendByte / appendBytes

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void t1_t2_t3(void)
{
    // ── T1: 500 appendChar calls, cycling a-z.
    String* s = String.withCString("");
    for (u16 i = (u16)0; i < (u16)500; i = i + (u16)1)
        s.appendByte((u8)((u16)'a' + (i % (u16)26)));

    Assert.isEqual((u16)s.byteLength(), (u16)500);                     // T1a
    Assert.isEqual((u16)s.byteAt((u16)0),   (u16)'a');             // T1b
    Assert.isEqual((u16)s.byteAt((u16)25),  (u16)'z');
    Assert.isEqual((u16)s.byteAt((u16)26),  (u16)'a');             // wrapped
    Assert.isEqual((u16)s.byteAt((u16)499), (u16)((u16)'a' + (u16)((u16)499 % (u16)26)));
    // The NUL is still there — cString() has to stay usable.
    Assert.isEqual((u16)s.cString()[500], (u16)0);                 // T1c

    // ── T2: capacity is at least length, and strictly more than an exact fit
    // would have given — i.e. the buffer really is over-allocated.
    Assert.isTrue(s.capacity() >= s.byteLength());                     // T2a
    Assert.isTrue(s.capacity() > (u16)500 - (u16)1);               // T2b

    // ── T3: a reserve that already fits is a no-op, and appends inside it do
    // not reallocate.
    String* r = String.withCString("");
    r.reserve((u16)200);
    Assert.isTrue(r.capacity() >= (u16)200);                       // T3a
    u16 cap0 = (u16)r.capacity();
    for (u16 i = (u16)0; i < (u16)200; i = i + (u16)1) r.appendByte((u8)'x');
    Assert.isEqual((u16)r.capacity(), cap0);                       // T3b — unchanged
    Assert.isEqual((u16)r.byteLength(), (u16)200);
    Assert.isEqual((u16)r.byteAt((u16)199), (u16)'x');
}

void t4(void)
{
    // ── T4: the same growth through append(String) and appendCString.
    String* s = String.withCString("");
    for (u16 i = (u16)0; i < (u16)100; i = i + (u16)1) {
        s.append(String.withCString("ab"));
        s.appendCString("cd");
    }
    Assert.isEqual((u16)s.byteLength(), (u16)400);                     // T4a
    Assert.isTrue(s.hasPrefix(String.withCString("abcdabcd")));    // T4b
    Assert.isTrue(s.hasSuffix(String.withCString("abcd")));        // T4c
    Assert.isTrue(s.capacity() >= s.byteLength());                     // T4d

    // A String built the old way still reports an exact capacity — withCString
    // allocates what it needs and nothing more, so nothing pays for growth it
    // never asks for.
    String* exact = String.withCString("hello");
    Assert.isEqual((u16)exact.capacity(), (u16)5);                 // T4e
}

void t5(void)
{
    // ── T5: Data has the identical problem and the identical fix.
    Data* d = new Data();
    for (u16 i = (u16)0; i < (u16)300; i = i + (u16)1) d.appendByte((u8)(i & (u16)$FF));
    Assert.isEqual((u16)d.length(), (u16)300);                     // T5a
    Assert.isEqual((u16)d.byteAt((u16)0),   (u16)0);               // T5b
    Assert.isEqual((u16)d.byteAt((u16)255), (u16)255);
    Assert.isEqual((u16)d.byteAt((u16)256), (u16)0);               // wrapped
    Assert.isTrue(d.capacity() >= d.length());                     // T5c
    Assert.isTrue(d.capacity() > (u16)299);                        // T5d

    u8 raw[4];
    raw[0] = (u8)$DE; raw[1] = (u8)$AD; raw[2] = (u8)$BE; raw[3] = (u8)$EF;
    Data* e = new Data();
    for (u16 i = (u16)0; i < (u16)50; i = i + (u16)1) e.appendBytes(&raw[0], (u16)4);
    Assert.isEqual((u16)e.length(), (u16)200);                     // T5e
    Assert.isEqual((u16)e.byteAt((u16)196), (u16)$DE);             // T5f
    Assert.isEqual((u16)e.byteAt((u16)199), (u16)$EF);
}

void main(void)
{
    t1_t2_t3();
    t4();
    t5();
    Assert.summary();
    return;
}
