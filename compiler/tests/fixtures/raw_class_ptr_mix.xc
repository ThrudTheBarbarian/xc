// raw_class_ptr_mix.xc — a raw pointer is not a class reference, in
// either direction (task #25). `String* x = buf;` compiled silently,
// dispatched through byte-soup, and the first symptom was a dead worker
// (blewit, 2026-08-22). Now exactly-one-side-class errors at every
// value-conversion site: initialiser, assignment, argument, return, and
// the C-shaped `String* s = "literal";`. The escape hatches stay open —
// an explicit `(T*)p` cast, and the untyped `pointer` type.
//xtc-flags: expect=sema-error
#import "Foundation.xc"

String* leak(u8* p) { return p; }        // return: raw -> class

i32 main(void)
{
    u8 buf[4];
    u8* raw = &buf[0];
    String* a = raw;                     // init: raw -> class
    String* b = "hi";                    // string literal -> class
    u8* back = a;                        // class -> raw
    return 0;
}
