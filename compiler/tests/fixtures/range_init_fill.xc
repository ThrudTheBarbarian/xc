// range_init_fill.xc — a range initialiser fills the WHOLE array.
//
// `..` excludes its upper bound and `...` includes it, so `u8 a[10] = 0..9;`
// supplies nine values for ten slots. The tenth used to keep whatever was on
// the stack — while `u8 a[10] = {0,1,2};`, the other spelling of the same
// thing, has always zero-filled. Guard for private:docs/bugs/053.
//
// `0..9` on a ten-element array is also the most natural thing to write, since
// the array's last index IS 9 — which is why the silence mattered.
//xtc-flags: -Wno-range-init-count
#import "Stdio.xc"

void show(string tag, u8* p, u16 n)
{
    Stdio.print(tag);
    for (u16 i = (u16)0; i < n; i = i + (u16)1) { Stdio.printf("%d ", (u16)p[i]); }
    Stdio.print("\n");
}

i32 main(void)
{
    u8 shortR[10] = 0..9;      // NINE values — the tenth must be 0, not garbage
    u8 exactI[10] = 0...9;     // ten, inclusive
    u8 exactE[10] = 0..10;     // ten, exclusive
    u8 listed[10] = {7, 8, 9}; // the documented zero-fill, for comparison

    show("short  : ", &shortR[0], (u16)10);
    show("incl   : ", &exactI[0], (u16)10);
    show("excl   : ", &exactE[0], (u16)10);
    show("list   : ", &listed[0], (u16)10);
    return 0;
}
