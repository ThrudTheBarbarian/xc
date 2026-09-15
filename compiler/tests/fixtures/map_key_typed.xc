//xtc-flags: target=arm64, expect=sema-error
// The KEY of a `Map<K, V>` is checked — private:docs/bugs/049.
//
// This is the point of the second type argument, not the notation: before it,
// the key erased to `Hashable*` and accepted anything hashable, so half of
// every map went unchecked. `Map<V>` still behaves that way deliberately; ask
// for the key to be typed and it is.
#import "Foundation.xc"
#import "Stdio.xc"

class Point : Object
{
    i32 x;
    void init(void) { x = (i32)0; }
}

i32 main(void)
{
    Map<String, Point>* m = new Map();
    Point* p = new Point();
    m.set(p, p);            // a Point is not a String — rejected at the call
    return 0;
}
