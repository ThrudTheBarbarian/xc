//xtc-warn: range initialiser supplies 9 values for an array of 10
//xtc-warn: (and the extras are dropped)
// A range that does not fill its array: `..` excludes its end, so `0..9` on a
// ten-element array leaves the last one zero-filled; one that overfills drops
// the extras. Both are legal and both warn (-Wno-range-init-count). Before bug
// 612 only the reference compiler said so.
void main(void)
    {
    u8 a[10] = 0..9;
    u8 b[3] = 0...4;
    u8 c[5] = 0..5;
    a[0] = b[0] + c[0];
    }
