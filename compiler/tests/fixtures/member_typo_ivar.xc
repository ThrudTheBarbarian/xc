//xtc-flags: expect=sema-error
// Same hazard as member_typo_struct, on a CLASS ivar: a misspelled ivar used to
// resolve silently to u8, lowering emitted a NOTE, and the compile SUCCEEDED
// with the store dropped.
//
// A property (getter `full()` / setter `setFull(v)`) is NOT a typo and must
// still compile — class_property covers that side.

class Widget
{
    u16 w;
    void init(void) { w = (u16)7; }
}

void main(void)
{
    Widget* x = new Widget();
    x.width = (u16)42;         // no such ivar -> must not compile
}
