//xtc-flags: target=arm64, expect=sema-error
// The element CHECK holds through a returned collection (XG bug 023).
//
// Companion to generic_return_type.xc: now that `Array<String>*` parses as a
// return type, the annotation must mean there what it means on a field — an
// add through the returned value with the wrong element type is refused, not
// erased back to `Object*` at the function boundary.
#import "Foundation.xc"

class Point : Object
{
    i32 x;
    void init(void) { x = (i32)0; }
}

class Holder : Object
{
    Array<String>* rows;
    void init(void) { rows = new Array(); }
    Array<String>* give(void) { return rows; }
}

i32 main(void)
{
    Holder* h = new Holder();
    h.give().add(new Point());      // 'Point' is not a subclass of 'String'
    return 0;
}
